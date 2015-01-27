%%-----------------------------------------------------------------------------
%% Copyright (c) 2012-2015, Feng Lee <feng@emqtt.io>
%% 
%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:
%% 
%% The above copyright notice and this permission notice shall be included in all
%% copies or substantial portions of the Software.
%% 
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
%% SOFTWARE.
%%------------------------------------------------------------------------------

-module(emqttc_session).

-include("emqttc.hrl").

-include("emqttc_packet.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([create/1, resume/3, publish/2, puback/2, subscribe/2, unsubscribe/2, destroy/1]).

-export([store/2]).

-record(session_state, { 
        client_id   :: binary(),
        client_pid  :: pid(),
		message_id  = 1,
        submap      :: map(),
        msg_queue, %% do not receive rel
        awaiting_ack :: map(),
        awaiting_rel :: map(),
        awaiting_comp :: map(),
        expires,
        expire_timer,
        logger }).

%% ------------------------------------------------------------------
%% Start Session
%% ------------------------------------------------------------------
create({true = _CleanSess, ClientId, _ClientPid}) ->
    %%Destroy old session if CleanSess is true before.
    {ok, initial_state(ClientId)}.

%% ------------------------------------------------------------------
%% Session API
%% ------------------------------------------------------------------
resume(SessState = #session_state{ client_id = ClientId, 
                                   client_pid = ClientPid,
                                   msg_queue = Queue,
                                   awaiting_ack = AwaitingAck,
                                   awaiting_comp = AwaitingComp,
                                   expire_timer = ETimer,
                                   logger = Logger }, ClientId, ClientPid) ->

    Logger:info("Session ~s resumed by ~p", [ClientId, ClientPid]),
    %cancel timeout timer
    erlang:cancel_timer(ETimer),

    %% redelivery PUBREL
    lists:foreach(fun(PacketId) ->
                ClientPid ! {redeliver, {?PUBREL, PacketId}}
        end, maps:keys(AwaitingComp)),

    %% redelivery messages that awaiting PUBACK or PUBREC
    Dup = fun(Msg) -> Msg#mqtt_message{ dup = true } end,
    lists:foreach(fun(Msg) ->
                ClientPid ! {dispatch, {self(), Dup(Msg)}}
        end, maps:values(AwaitingAck)),

    %% send offline messages
    lists:foreach(fun(Msg) ->
                ClientPid ! {dispatch, {self(), Msg}}
        end, emqttc_queue:all(Queue)),

    SessState#session_state{ client_pid = ClientPid, 
                         msg_queue = emqttc_queue:clear(Queue), 
                         expire_timer = undefined }.

%%TODO: session....
publish(Session, {?QOS_0, Message}) ->
    Session;

publish(Session, {?QOS_1, Message}) ->
	Session;

publish(SessState = #session_state{awaiting_rel = AwaitingRel}, 
    {?QOS_2, Message = #mqtt_message{ msgid = MsgId }}) ->
    %% store in awaiting_rel
    SessState#session_state{awaiting_rel = maps:put(MsgId, Message, AwaitingRel)}.

%%--------------------------------------------------------------------
%% @doc PUBACK
%%--------------------------------------------------------------------
%% 
puback(SessState = #session_state{client_id = ClientId, awaiting_ack = Awaiting}, {?PUBACK, PacketId}) ->
    case maps:is_key(PacketId, Awaiting) of
        true -> ok;
        false -> todo %Logger:warning("Session ~s: PUBACK PacketId '~p' not found!", [ClientId, PacketId])
    end,
    SessState#session_state{awaiting_ack = maps:remove(PacketId, Awaiting)};

%%--------------------------------------------------------------------
%% @doc PUBREC
%%--------------------------------------------------------------------
puback(SessState = #session_state{ client_id = ClientId, 
                                   awaiting_ack = AwaitingAck,
                                   awaiting_comp = AwaitingComp }, {?PUBREC, PacketId}) ->
    case maps:is_key(PacketId, AwaitingAck) of
        true -> ok;
        false -> todo %Logger:warning("Session ~s: PUBREC PacketId '~p' not found!", [ClientId, PacketId])
    end,
    SessState#session_state{ awaiting_ack   = maps:remove(PacketId, AwaitingAck), 
                             awaiting_comp  = maps:put(PacketId, true, AwaitingComp) };

%%--------------------------------------------------------------------
%% @doc PUBREL
%%--------------------------------------------------------------------
puback(SessState = #session_state{client_id = ClientId, client_pid = ClientPid, awaiting_rel = Awaiting}, {?PUBREL, PacketId}) ->
    case maps:find(PacketId, Awaiting) of
        {ok, Msg} -> ClientPid ! {dispatch, Msg}; %%TODO: this is not right...
        error -> todo %Logger:warning("Session ~s: PUBREL PacketId '~p' not found!", [ClientId, PacketId])
    end,
    SessState#session_state{awaiting_rel = maps:remove(PacketId, Awaiting)};

%%--------------------------------------------------------------------
%% @doc PUBCOMP
%%--------------------------------------------------------------------
puback(SessState = #session_state{ client_id = ClientId, 
                                   awaiting_comp = AwaitingComp}, {?PUBCOMP, PacketId}) ->
    case maps:is_key(PacketId, AwaitingComp) of
        true -> ok;
        false -> todo %Logger:warning("Session ~s: PUBREC PacketId '~p' not exist", [ClientId, PacketId])
    end,
    SessState#session_state{ awaiting_comp  = maps:remove(PacketId, AwaitingComp) }.

%%--------------------------------------------------------------------
%% @doc SUBSCRIBE
%%--------------------------------------------------------------------
subscribe(SessState = #session_state{client_id = ClientId, submap = SubMap}, Topics) ->
    Resubs = [Topic || {Name, _Qos} = Topic <- Topics, maps:is_key(Name, SubMap)], 
    case Resubs of
        [] -> ok;
        _  -> todo %Logger:warning("~s resubscribe ~p", [ClientId, Resubs])
    end,
    SubMap1 = lists:foldl(fun({Name, Qos}, Acc) -> maps:put(Name, Qos, Acc) end, SubMap, Topics),
    %%TODO: should be gen_event and notification...
    {ok, SessState#session_state{submap = SubMap1}}.%, GrantedQos}.

%%--------------------------------------------------------------------
%% @doc UNSUBSCRIBE
%%--------------------------------------------------------------------
unsubscribe(SessState = #session_state{client_id = ClientId, submap = SubMap}, Topics) ->
    %%TODO: refactor later.
    case Topics -- maps:keys(SubMap) of
        [] -> ok;
        BadUnsubs -> todo %% Logger:warning("~s should not unsubscribe ~p", [ClientId, BadUnsubs])
    end,
    %%unsubscribe from topic tree
    SubMap1 = lists:foldl(fun(Topic, Acc) -> maps:remove(Topic, Acc) end, SubMap, Topics),
    {ok, SessState#session_state{submap = SubMap1}}.

%store message(qos1) that sent to client
store(SessState = #session_state{ message_id = MsgId, awaiting_ack = Awaiting}, 
    Message = #mqtt_message{ qos = Qos }) when (Qos =:= ?QOS_1) orelse (Qos =:= ?QOS_2) ->
    %%assign msgid before send
    Message1 = Message#mqtt_message{ msgid = MsgId },
    Message2 =
    if
        Qos =:= ?QOS_2 -> Message1#mqtt_message{dup = false};
        true -> Message1
    end,
    Awaiting1 = maps:put(MsgId, Message2, Awaiting),
    {Message1, next_msg_id(SessState#session_state{ awaiting_ack = Awaiting1 })}.

initial_state(ClientId) ->
    #session_state { client_id  = ClientId,
                     submap     = #{}, 
                     awaiting_ack = #{},
                     awaiting_rel = #{},
                     awaiting_comp = #{} }.

initial_state(ClientId, ClientPid) ->
    State = initial_state(ClientId),
    State#session_state{client_pid = ClientPid}.

destroy(_SessState = #session_state{}) -> ok.

%%
%%   Logger:warning("Session: client ~s@~p exited, caused by ~p", [ClientId, ClientPid, Reason]),
%%    Timer = erlang:send_after(Expires * 1000, self(), {session, expired}),

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

dispatch(Message, State = #session_state{ client_id = ClientId, 
                                          client_pid = undefined }) ->
    queue(ClientId, Message, State);

dispatch(Message = #mqtt_message{ qos = ?QOS_0 }, State = #session_state{ 
        client_pid = ClientPid }) ->
    ClientPid ! {dispatch, Message},
    State;

dispatch(Message = #mqtt_message{ qos = Qos }, State = #session_state{ client_pid = ClientPid }) 
    when (Qos =:= ?QOS_1) orelse (Qos =:= ?QOS_2) ->
    {Message1, NewState} = store(State, Message),
    ClientPid ! {dispatch, Message1},
    NewState.

queue(ClientId, Message, State = #session_state{msg_queue = Queue}) ->
    State#session_state{msg_queue = emqttc_queue:in(ClientId, Message, Queue)}.

next_msg_id(State = #session_state{ message_id = 16#ffff }) ->
    State#session_state{ message_id = 1 };

next_msg_id(State = #session_state{ message_id = MsgId }) ->
    State#session_state{ message_id = MsgId + 1 }.

    

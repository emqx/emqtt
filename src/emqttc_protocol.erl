%%%-----------------------------------------------------------------------------
%%% Copyright (c) 2012-2016 eMQTT.IO, All Rights Reserved.
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a copy
%%% of this software and associated documentation files (the "Software"), to deal
%%% in the Software without restriction, including without limitation the rights
%%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%%% copies of the Software, and to permit persons to whom the Software is
%%% furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included in all
%%% copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
%%% SOFTWARE.
%%%-----------------------------------------------------------------------------
%%% @doc
%%% emqttc client-side protocol handler.
%%% @end
%%%-----------------------------------------------------------------------------
-module(emqttc_protocol).

-author("Feng Lee <feng@emqtt.io>").

-include("emqttc_packet.hrl").

-compile(nowarn_deprecated_function).

%% State API
-export([init/1, set_socket/2]).

%% Protocol API
-export([connect/1,
         publish/2,
         puback/2,
         pubrec/2,
         pubrel/2,
         pubcomp/2,
         subscribe/2,
         unsubscribe/2,
         ping/1,
         disconnect/1,
         received/2]).

-record(proto_state, {
        socket                  :: inet:socket(),
        socket_name             :: list() | binary(),
        proto_ver  = 4          :: mqtt_vsn(),
        proto_name = <<"MQTT">> :: binary(),
        client_id               :: binary(),
        clean_sess = true       :: boolean(),
        keepalive  = ?KEEPALIVE :: non_neg_integer(),
        will_flag  = false      :: boolean(),
        will_msg                :: mqtt_message(),
        username                :: binary() | undefined,
        password                :: binary() | undefined,
        packet_id = 1           :: mqtt_packet_id(),
        subscriptions = #{}     :: map(),
        awaiting_ack  = #{}     :: map(),
        awaiting_rel  = #{}     :: map(),
        awaiting_comp = #{}     :: map()}).

-type proto_state() :: #proto_state{}.

-export_type([proto_state/0]).

%%%=============================================================================
%%% API
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Init protocol with MQTT options.
%% @end
%%------------------------------------------------------------------------------
-spec init(MqttOpts) -> State when
    MqttOpts :: list(tuple()),
    State    :: proto_state().
init(MqttOpts) ->
	init(MqttOpts, #proto_state{client_id   = random_id(),
                                will_msg    = #mqtt_message{}}).

init([], State) ->
    State;
init([{client_id, ClientId} | Opts], State) when is_binary(ClientId) ->
    init(Opts, State#proto_state{client_id = ClientId});
init([{proto_ver, ?MQTT_PROTO_V31} | Opts], State) ->
    init(Opts, State#proto_state{proto_ver = ?MQTT_PROTO_V31, proto_name = <<"MQIsdp">>});
init([{proto_ver, ?MQTT_PROTO_V311} | Opts], State) ->
    init(Opts, State#proto_state{proto_ver = ?MQTT_PROTO_V311, proto_name = <<"MQTT">>});
init([{clean_sess, CleanSess} | Opts], State) when is_boolean(CleanSess) ->
    init(Opts, State#proto_state{clean_sess = CleanSess});
init([{keepalive, KeepAlive} | Opts], State) when is_integer(KeepAlive) ->
    init(Opts, State#proto_state{keepalive = KeepAlive});
init([{username, Username} | Opts], State) when is_binary(Username)->
    init(Opts, State#proto_state{username = Username});
init([{password, Password} | Opts], State) when is_binary(Password) ->
    init(Opts, State#proto_state{password = Password});
init([{will, WillOpts} | Opts], State = #proto_state{will_msg = WillMsg}) ->
    init(Opts, State#proto_state{will_flag = true,
                                 will_msg  = init_willmsg(WillOpts, WillMsg)});
init([_Opt | Opts], State) ->
    init(Opts, State).

init_willmsg([], WillMsg) ->
    WillMsg;
init_willmsg([{topic, Topic} | Opts], WillMsg) when is_binary(Topic) ->
    init_willmsg(Opts, WillMsg#mqtt_message{topic = Topic});
init_willmsg([{payload, Payload} | Opts], WillMsg) when is_binary(Payload) ->
    init_willmsg(Opts, WillMsg#mqtt_message{payload = Payload});
init_willmsg([{qos, Qos} | Opts], WillMsg) when ?IS_QOS(Qos) ->
    init_willmsg(Opts, WillMsg#mqtt_message{qos = Qos});
init_willmsg([{retain, Retain} | Opts], WillMsg) when is_boolean(Retain) ->
    init_willmsg(Opts, WillMsg#mqtt_message{retain = Retain});
init_willmsg([_Opt | Opts], State) ->
    init_willmsg(Opts, State).

random_id() ->
    random:seed(case erlang:function_exported(erlang, timestamp, 0) of
                    true  -> %% R18
                        erlang:timestamp();
                    false -> %% R17
                        erlang:now()
                end),
    I1 = random:uniform(round(math:pow(2, 48))) - 1,
    I2 = random:uniform(round(math:pow(2, 32))) - 1,
    {ok, Host} = inet:gethostname(),
    list_to_binary(["emqttc_", Host, "_" | io_lib:format("~12.16.0b~8.16.0b", [I1, I2])]).

%%------------------------------------------------------------------------------
%% @doc Set socket
%% @end
%%0-----------------------------------------------------------------------------
set_socket(State, Socket) ->
    {ok, SockName} = emqttc_socket:sockname_s(Socket),
    State#proto_state{
        socket      = Socket,
        socket_name = SockName
    }.

%%------------------------------------------------------------------------------
%% @doc Send CONNECT Packet
%% @end
%%------------------------------------------------------------------------------
connect(State = #proto_state{client_id  = ClientId,
                             proto_ver  = ProtoVer,
                             proto_name = ProtoName,
                             clean_sess = CleanSess,
                             keepalive  = KeepAlive,
                             will_flag  = WillFlag,
                             will_msg   = #mqtt_message{qos = WillQos,
                                                        retain = WillRetain,
                                                        topic = WillTopic,
                                                        payload = WillMsg},
                             username   = Username,
                             password   = Password}) ->


    Connect = #mqtt_packet_connect{client_id   = ClientId,
                                   proto_ver   = ProtoVer,
                                   proto_name  = ProtoName,
                                   will_flag   = WillFlag,
                                   will_retain = WillRetain,
                                   will_qos    = WillQos,
                                   clean_sess  = CleanSess,
                                   keep_alive  = KeepAlive,
                                   will_topic  = WillTopic,
                                   will_msg    = WillMsg,
                                   username    = Username,
                                   password    = Password},

    send(?CONNECT_PACKET(Connect), State).

%%------------------------------------------------------------------------------
%% @doc
%% Publish Message to Broker:
%%
%% Qos0 message sent directly.
%% Qos1, Qos2 messages should be stored first.
%%
%% @end
%%------------------------------------------------------------------------------
publish(Message = #mqtt_message{qos = ?QOS_0}, State) ->
    {ok, NewState} = send(emqttc_message:to_packet(Message), State),
    {ok, undefined, NewState};

publish(Message = #mqtt_message{qos = Qos}, State = #proto_state{
                packet_id = PacketId, awaiting_ack = AwaitingAck})
        when (Qos =:= ?QOS_1) orelse (Qos =:= ?QOS_2) ->
    Message1 = Message#mqtt_message{msgid = PacketId},
    Message2 =
    if
        Qos =:= ?QOS_2 -> Message1#mqtt_message{dup = false};
        true -> Message1
    end,
    Awaiting1 = maps:put(PacketId, Message2, AwaitingAck),
	{ok, NewState} = send(emqttc_message:to_packet(Message2),
                              next_packet_id(State#proto_state{awaiting_ack = Awaiting1})),
    {ok, PacketId, NewState}.

puback(PacketId, State) when is_integer(PacketId) ->
    send(?PUBACK_PACKET(?PUBACK, PacketId), State).

pubrec(PacketId, State) when is_integer(PacketId) ->
    send(?PUBACK_PACKET(?PUBREC, PacketId), State).

pubrel(PacketId, State) when is_integer(PacketId) ->
    send(?PUBREL_PACKET(PacketId), State). %% qos = 1

pubcomp(PacketId, State) when is_integer(PacketId) ->
    send(?PUBACK_PACKET(?PUBCOMP, PacketId), State).

subscribe(Topics, State = #proto_state{packet_id = PacketId,
                                               subscriptions = SubMap}) ->
    Resubs = [Topic || {Name, _Qos} = Topic <- Topics, maps:is_key(Name, SubMap)],
    case Resubs of
        [] -> ok;
        _  -> ?warn("[~s] resubscribe ~p", [logtag(State), Resubs])
    end,
    SubMap1 = lists:foldl(fun({Name, Qos}, Acc) -> maps:put(Name, Qos, Acc) end, SubMap, Topics),
    %% send packet
    {ok, NewState} = send(?SUBSCRIBE_PACKET(PacketId, Topics), next_packet_id(State#proto_state{subscriptions = SubMap1})),
    {ok, PacketId, NewState}.

unsubscribe(Topics, State = #proto_state{subscriptions = SubMap, packet_id = PacketId}) ->
    case Topics -- maps:keys(SubMap) of
        [] -> ok;
        BadUnsubs -> ?warn("[~s] should not unsubscribe ~p", [logtag(State), BadUnsubs])
    end,
    %% unsubscribe from topic tree
    SubMap1 = lists:foldl(fun(Topic, Acc) -> maps:remove(Topic, Acc) end, SubMap, Topics),
    %% send packet
    send(?UNSUBSCRIBE_PACKET(PacketId, Topics), next_packet_id(State#proto_state{subscriptions = SubMap1})).

ping(State) ->
    send(?PACKET(?PINGREQ), State).

disconnect(State) ->
    send(?PACKET(?DISCONNECT), State).

received('CONNACK', State = #proto_state{clean_sess = true}) ->
    %%TODO: Send awaiting...
    {ok, State};

received('CONNACK', State = #proto_state{clean_sess = false}) ->
    %%TODO: Resume Session...
    {ok, State};

received({'PUBLISH', ?PUBLISH_PACKET(?QOS_1, _Topic, PacketId, _Payload)}, State) ->
    puback(PacketId, State);

received({'PUBLISH', Packet = ?PUBLISH_PACKET(?QOS_2, _Topic, PacketId, _Payload)},
         State = #proto_state{awaiting_rel = AwaitingRel}) ->
    pubrec(PacketId, State),
    {ok, State#proto_state{awaiting_rel = maps:put(PacketId, Packet, AwaitingRel)}};

received({'PUBACK', PacketId}, State = #proto_state{awaiting_ack = AwaitingAck}) ->
    case maps:is_key(PacketId, AwaitingAck) of
        true -> ok;
        false -> ?warn("[~s] PUBACK PacketId '~p' not found!", [logtag(State), PacketId])
    end,
    {ok, State#proto_state{awaiting_ack = maps:remove(PacketId, AwaitingAck)}};

received({'PUBREC', PacketId}, State = #proto_state{awaiting_ack = AwaitingAck,
                                                    awaiting_comp = AwaitingComp}) ->
    case maps:is_key(PacketId, AwaitingAck) of
        true -> ok;
        false -> ?warn("[~s] PUBREC PacketId '~p' not found!", [logtag(State), PacketId])
    end,
    pubrel(PacketId, State),
    {ok, State#proto_state{awaiting_ack   = maps:remove(PacketId, AwaitingAck),
                           awaiting_comp  = maps:put(PacketId, true, AwaitingComp)}};

received({'PUBREL', PacketId}, State = #proto_state{awaiting_rel = AwaitingRel}) ->
    case maps:find(PacketId, AwaitingRel) of
        {ok, Publish} ->
            {ok, Publish, State#proto_state{awaiting_rel = maps:remove(PacketId, AwaitingRel)}};
        error ->
            ?warn("[~s] PUBREL PacketId '~p' not found!", [logtag(State), PacketId]),
            {ok, State}
    end;

received({'PUBCOMP', PacketId}, State = #proto_state{awaiting_comp = AwaitingComp}) ->
    case maps:is_key(PacketId, AwaitingComp) of
        true -> ok;
        false -> ?warn("[~s] PUBREC PacketId '~p' not exist", [logtag(State), PacketId])
    end,
    {ok, State#proto_state{ awaiting_comp  = maps:remove(PacketId, AwaitingComp)}};

received({'SUBACK', _PacketId, _QosTable}, State) ->
    %%  TODO...
    {ok, State};

received({'UNSUBACK', _PacketId}, State) ->
    %%  TODO...
    {ok, State}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @private
%% @doc
%% Send Packet to broker.
%%
%% @end
%%------------------------------------------------------------------------------
send(Packet, State = #proto_state{socket = Socket}) ->
    LogTag = logtag(State),
    ?debug("[~s] SENT: ~s", [LogTag, emqttc_packet:dump(Packet)]),
    Data = emqttc_serialiser:serialise(Packet),
    ?debug("[~s] SENT: ~p", [LogTag, Data]),
    emqttc_socket:send(Socket, Data),
    {ok, State}.

next_packet_id(State = #proto_state{packet_id = 16#ffff}) ->
    State#proto_state{packet_id = 1};

next_packet_id(State = #proto_state{packet_id = Id }) ->
    State#proto_state{packet_id = Id + 1}.

logtag(#proto_state{socket_name = SocketName, client_id = ClientId}) ->
    io_lib:format("~s@~s", [ClientId, SocketName]).

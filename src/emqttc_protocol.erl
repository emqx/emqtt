%%%-----------------------------------------------------------------------------
%%% @Copyright (C) 2012-2015, Feng Lee <feng@emqtt.io>
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

-author("feng@emqtt.io").

-include("emqttc_packet.hrl").

%% State API
-export([init/1, set_socket/2]).

%% Protocol API
-export([connect/1,
         publish/2,
         puback/2,
         pubrec/2,
         pubrel/2,
         store/2,
         subscribe/2,
         unsubscribe/2,
         ping/1,
         disconnect/1,
         received/2]).

%% TODO: types...
-record(proto_state, {
        socket                  :: inet:socket(),
        socket_name             :: list() | binary(),
        proto_ver  = 3          :: mqtt_vsn(),
        proto_name = <<"MQTT">> :: binary(),
        client_id               :: binary(),
        clean_sess = true       :: boolean(),
        keepalive  = 60         :: non_neg_integer(),
        will_flag  = false      :: boolean(),
        will_msg                :: mqtt_message(),
        username                :: binary() | undefined,
        password                :: binary() | undefined,
        packet_id = 1           :: mqtt_packet_id(),
        subscriptions = #{}     :: map(),
        awaiting_ack  = #{}     :: map(),
        awaiting_rel  = #{}     :: map(),
        awaiting_comp = #{}     :: map(),
        logger                  :: gen_logger:logmod()}).

-type proto_state() :: #proto_state{}.

-export_type([proto_state/0]).

%%%=============================================================================
%%% API
%%%=============================================================================

%%%-----------------------------------------------------------------------------
%%% @doc
%%% init protocol with MQTT options.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-spec init(MqttOpts) -> State when
    MqttOpts :: list(tuple()),
    State    :: proto_state().
init(MqttOpts) ->
	init(MqttOpts, #proto_state{client_id   = random_id(),
                                proto_ver   = ?MQTT_PROTO_V311,
                                proto_name  = <<"MQTT">>,
                                clean_sess  = false,
                                keepalive   = 60,
                                will_flag   = false,
                                will_msg    = #mqtt_message{} }).

init([], State) ->
    State;
init([{client_id, ClientId} | Opts], State) when is_binary(ClientId) ->
    init(Opts, State#proto_state{client_id = ClientId});
init([{clean_sess, CleanSess} | Opts], State) when is_boolean(CleanSess) ->
    init(Opts, State#proto_state{clean_sess = CleanSess});
init([{keepalive, KeepAlive} | Opts], State) when is_integer(KeepAlive) ->
    init(Opts, State#proto_state{keepalive = KeepAlive});
init([{username, Username} | Opts], State) when is_binary(Username)->
    init(Opts, State#proto_state{ username = Username});
init([{password, Password} | Opts], State) when is_binary(Password) ->
    init(Opts, State#proto_state{ password = Password });
init([{will_msg, WillOpts} | Opts], State = #proto_state{will_msg = WillMsg}) ->
    init(Opts, State#proto_state{will_msg = init_willmsg(WillOpts, WillMsg)});
init([{logger, Logger} | Opts], State) ->
    init(Opts, State#proto_state { logger = Logger });
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
    random:seed(now()),
    I1 = random:uniform(round(math:pow(2, 48))) - 1,
    I2 = random:uniform(round(math:pow(2, 32))) - 1,
    list_to_binary(["emqttc/" | io_lib:format("~12.16.0b~8.16.0b", [I1, I2])]).

%%%-----------------------------------------------------------------------------
%%% @doc
%%% Set socket.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
set_socket(State, Socket) ->
    {ok, SockName} = emqttc_socket:sockname_s(Socket),
    State#proto_state{
        socket      = Socket,
        socket_name = SockName
    }.

%%%-----------------------------------------------------------------------------
%%% @doc
%%% Send CONNECT Packet.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
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


    Connect = #mqtt_packet_connect{client_id  = ClientId,
                                   proto_ver  = ProtoVer,
                                   proto_name = ProtoName,
                                   will_flag  = WillFlag,
                                   will_retain = WillRetain,
                                   will_qos    = WillQos,
                                   clean_sess  = CleanSess,
                                   keep_alive  = KeepAlive,
                                   will_topic  = WillTopic,
                                   will_msg    = WillMsg,
                                   username    = Username,
                                   password    = Password},
    
    send(?CONNECT_PACKET(Connect), State).

%%%-----------------------------------------------------------------------------
%%% @doc
%%% Publish Message to Broker:
%%%
%%% Qos0 message sent directly.
%%% Qos1, Qos2 messages should be stored first.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
publish(Message = #mqtt_message{qos = ?QOS_0}, State) ->
	send(emqttc_message:to_packet(Message), State);

publish(Message = #mqtt_message{qos = Qos}, State = #proto_state{
                packet_id = PacketId, awaiting_ack = Awaiting}) 
        when (Qos =:= ?QOS_1) orelse (Qos =:= ?QOS_2) ->
    Message1 = Message#mqtt_message{msgid = PacketId},
    Message2 =
    if
        Qos =:= ?QOS_2 -> Message1#mqtt_message{dup = false};
        true -> Message1
    end,
    Awaiting1 = maps:put(PacketId, Message2, Awaiting),
	send(emqttc_message:to_packet(Message2), next_packet_id(State#proto_state{awaiting_ack = Awaiting1})).

puback(PacketId, State) when is_integer(PacketId) ->
    send(?PUBACK_PACKET(?PUBACK, PacketId), State).

pubrec(PacketId, State) when is_integer(PacketId) ->
    send(?PUBACK_PACKET(?PUBREC, PacketId), State).

pubrel(PacketId, State) when is_integer(PacketId) ->
    send(?PUBACK_PACKET(?PUBREL, PacketId), State).

%%TODO: should be merge with received(publish...
store(Packet = ?PUBLISH_PACKET(?QOS_2, _Topic, PacketId, _Payload), State = #proto_state{awaiting_rel = AwaitingRel}) ->
    {ok, State#proto_state{awaiting_rel = maps:put(PacketId, Packet, AwaitingRel)}}.

subscribe(Topics, State = #proto_state{subscriptions = SubMap, logger = Logger}) ->
    Resubs = [Topic || {Name, _Qos} = Topic <- Topics, maps:is_key(Name, SubMap)], 
    case Resubs of
        [] -> ok;
        _  -> Logger:warning("[~s] resubscribe ~p", [logtag(State), Resubs])
    end,
    SubMap1 = lists:foldl(fun({Name, Qos}, Acc) -> maps:put(Name, Qos, Acc) end, SubMap, Topics),
    {ok, State#proto_state{subscriptions = SubMap1}}.

unsubscribe(Topics, State = #proto_state{subscriptions = SubMap, logger = Logger}) ->
    case Topics -- maps:keys(SubMap) of
        [] -> ok;
        BadUnsubs -> Logger:warning("[~s] should not unsubscribe ~p", [logtag(State), BadUnsubs]) end,
    %%unsubscribe from topic tree
    SubMap1 = lists:foldl(fun(Topic, Acc) -> maps:remove(Topic, Acc) end, SubMap, Topics),
    {ok, State#proto_state{subscriptions = SubMap1}}.

ping(State) ->
    send(?PACKET(?PINGREQ), State).

disconnect(State) ->
    send(?PACKET(?DISCONNECT), State).

received('CONNACK', State) ->
    %%TODO: Resume Session... 
    {ok, State};

received({'PUBACK', PacketId}, State = #proto_state{awaiting_ack = AwaitingAck, logger = Logger}) ->
    case maps:is_key(PacketId, AwaitingAck) of
        true -> ok;
        false -> Logger:warning("[~s] PUBACK PacketId '~p' not found!", [logtag(State), PacketId])
    end,
    {ok, State#proto_state{awaiting_ack = maps:remove(PacketId, AwaitingAck)}};

received({'PUBREC', PacketId}, State = #proto_state{awaiting_ack = AwaitingAck, 
                                                    awaiting_comp = AwaitingComp, 
                                                    logger = Logger}) ->
    case maps:is_key(PacketId, AwaitingAck) of
        true -> ok;
        false -> Logger:warning("[~s] PUBREC PacketId '~p' not found!", [logtag(State), PacketId])
    end,
    {ok, State#proto_state{awaiting_ack   = maps:remove(PacketId, AwaitingAck), 
                           awaiting_comp  = maps:put(PacketId, true, AwaitingComp)}};

received({'PUBREL', PacketId}, State = #proto_state{awaiting_rel = AwaitingRel, logger = Logger}) ->
    case maps:find(PacketId, AwaitingRel) of
        {ok, Msg} -> 
            {ok, Msg, State#proto_state{awaiting_rel = maps:remove(PacketId, AwaitingRel)}}; 
        error -> 
            Logger:warning("[~s] PUBREL PacketId '~p' not found!", [logtag(State), PacketId]),
            {ok, State}
    end;

received({'PUBCOMP', PacketId}, State = #proto_state{awaiting_comp = AwaitingComp, logger = Logger}) ->
    case maps:is_key(PacketId, AwaitingComp) of
        true -> ok;
        false -> Logger:warning("[~s] PUBREC PacketId '~p' not exist", [logtag(State), PacketId])
    end,
    {ok, State#proto_state{ awaiting_comp  = maps:remove(PacketId, AwaitingComp)}};

received({'SUBACK', PacketId, QosTable}, State) ->
    %%  TODO...
    {ok, State};

received({'UNSUBACK', PacketId}, State) ->
    %%  TODO...
    {ok, State}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

%%%-----------------------------------------------------------------------------
%%% @private
%%% @doc
%%% Send Packet to broker.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
send(Packet, State = #proto_state{socket = Socket, logger = Logger}) ->
    LogTag = logtag(State),
    Logger:info("[~s] SENT: ~s", [LogTag, emqttc_packet:dump(Packet)]),
    Data = emqttc_serialiser:serialise(Packet),
    Logger:debug("[~s] SENT: ~p", [LogTag, Data]),
    emqttc_socket:send(Socket, Data),
    {ok, State}.

next_packet_id(State = #proto_state{packet_id = 16#ffff}) ->
    State#proto_state{packet_id = 1};

next_packet_id(State = #proto_state{packet_id = Id }) ->
    State#proto_state{packet_id = Id + 1}.

logtag(#proto_state{socket_name = SocketName, client_id = ClientId}) ->
    io_lib:format("~s@~s", [ClientId, SocketName]).



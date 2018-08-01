%%%-----------------------------------------------------------------------------
%%% Copyright (c) 2015-2016 eMQTT.IO, All Rights Reserved.
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
%%% emqttc main client api.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(emqttc).

-author("hiroe.orz@gmail.com").

-author("Feng Lee <feng@emqtt.io>").

-include("emqttc_packet.hrl").

-import(proplists, [get_value/2, get_value/3]).

%% Start application
-export([start/0]).

%% Start emqttc client
-export([start_link/0, start_link/1, start_link/2, start_link/3, start_link/4]).

%% Lookup topics
-export([topics/1]).

%% Publish, Subscribe API
-export([publish/3, publish/4,
         sync_publish/4,
         subscribe/2, subscribe/3,
         sync_subscribe/2, sync_subscribe/3,
         unsubscribe/2,
         ping/1,
         disconnect/1]).

-behaviour(gen_fsm).

%% gen_fsm callbacks
-export([init/1, handle_event/3, handle_sync_event/4, handle_info/3,
         terminate/3, code_change/4]).

%% FSM state
-export([connecting/2,
         waiting_for_connack/2, waiting_for_connack/3,
         connected/2, connected/3,
         disconnected/2, disconnected/3]).

-ifdef(TEST).

-export([qos_opt/1]).

-endif.

-type mqttc_opt() :: {host, inet:ip_address() | string()}
                   | {port, inet:port_number()}
                   | {client_id, binary()}
                   | {clean_sess, boolean()}
                   | {keepalive, non_neg_integer()}
                   | {proto_ver, mqtt_vsn()}
                   | {username, binary()}
                   | {password, binary()}
                   | {will, list(tuple())}
                   | {connack_timeout, pos_integer()}
                   | {puback_timeout,  pos_integer()}
                   | {suback_timeout,  pos_integer()}
                   | ssl | {ssl, [ssl:ssloption()]}
                   | force_ping | {force_ping, boolean()}
                   | auto_resub | {auto_resub, boolean()}
                   | {reconnect, non_neg_integer() | {non_neg_integer(), non_neg_integer()} | false}.

-type mqtt_qosopt() :: qos0 | qos1 | qos2 | mqtt_qos().

-type mqtt_pubopt() :: mqtt_qosopt() | {qos, mqtt_qos()} | {retain, boolean()}.

-record(state, {recipient           :: pid(),
                name                :: atom(),
                host = "localhost"  :: inet:ip_address() | string(),
                port = 1883         :: inet:port_number(),
                socket              :: inet:socket(),
                receiver            :: pid(),
                proto_state         :: emqttc_protocol:proto_state(),
                subscribers = []    :: list(),
                pubsub_map  = #{}   :: map(),
                ping_reqs   = []    :: list(),
                pending_pubsub = [] :: list(),
                inflight_reqs = #{} :: map(),
                inflight_msgid      :: pos_integer(),
                auto_resub = false  :: boolean(),
                force_ping = false  :: boolean(),
                keepalive           :: emqttc_keepalive:keepalive() | undefined,
                keepalive_after     :: non_neg_integer(),
                connack_timeout     :: pos_integer(),
                puback_timeout      :: pos_integer(),
                suback_timeout      :: pos_integer(),
                connack_tref        :: reference(),
                transport = tcp     :: tcp | ssl,
                reconnector         :: emqttc_reconnector:reconnector() | undefined,
                tcp_opts            :: [gen_tcp:connect_option()],
                ssl_opts            :: [ssl:ssloption()]}).

%% 60 secs
-define(CONNACK_TIMEOUT, 60).

%% 10 secs
-define(SYNC_SEND_TIMEOUT, 10).

%% 8 secs
-define(SUBACK_TIMEOUT, 8).

%% 4 secs
-define(PUBACK_TIMEOUT, 4).

%%%=============================================================================
%%% API
%%%=============================================================================

start() ->
    application:start(emqttc).

%%------------------------------------------------------------------------------
%% @doc Start emqttc client with default options.
%% @end
%%------------------------------------------------------------------------------
-spec start_link() -> {ok, Client :: pid()} | ignore | {error, term()}.
start_link() ->
    start_link([]).

%%------------------------------------------------------------------------------
%% @doc Start emqttc client with options.
%% @end
%%------------------------------------------------------------------------------
-spec start_link(MqttOpts) -> {ok, Client} | ignore | {error, any()} when
    MqttOpts  :: [mqttc_opt()],
    Client    :: pid().
start_link(MqttOpts) when is_list(MqttOpts) ->
    start_link(MqttOpts, []).

%%------------------------------------------------------------------------------
%% @doc Start emqttc client with name, options.
%% @end
%%------------------------------------------------------------------------------
-spec start_link(Name | MqttOpts, TcpOpts) -> {ok, pid()} | ignore | {error, any()} when
    Name      :: atom(),
    MqttOpts  :: [mqttc_opt()],
    TcpOpts   :: [gen_tcp:connect_option()].
start_link(Name, MqttOpts) when is_atom(Name), is_list(MqttOpts) ->
    start_link(Name, MqttOpts, []);
start_link(MqttOpts, TcpOpts) when is_list(MqttOpts), is_list(TcpOpts) ->
    gen_fsm:start_link(?MODULE, [undefined, self(), MqttOpts, TcpOpts], []).

%%------------------------------------------------------------------------------
%% @doc Start emqttc client with name, options, tcp options.
%% @end
%%------------------------------------------------------------------------------
-spec start_link(Name, MqttOpts, TcpOpts) -> {ok, pid()} | ignore | {error, any()} when
    Name      :: atom(),
    MqttOpts  :: [mqttc_opt()],
    TcpOpts   :: [gen_tcp:connect_option()].
start_link(Name, MqttOpts, TcpOpts) when is_atom(Name), is_list(MqttOpts), is_list(TcpOpts) ->
    start_link(Name, self(), MqttOpts, TcpOpts).

%%------------------------------------------------------------------------------
%% @doc Start emqttc client with Recipient, name, options, tcp options.
%% @end
%%------------------------------------------------------------------------------
-spec start_link(Name, Recipient, MqttOpts, TcpOpts) -> {ok, pid()} | ignore | {error, any()} when
    Name      :: atom(),
    Recipient :: pid() | atom(),
    MqttOpts  :: [mqttc_opt()],
    TcpOpts   :: [gen_tcp:connect_option()].
start_link(Name, Recipient, MqttOpts, TcpOpts) when is_pid(Recipient), is_atom(Name), is_list(MqttOpts), is_list(TcpOpts) ->
    gen_fsm:start_link({local, Name}, ?MODULE, [Name, Recipient, MqttOpts, TcpOpts], []).

%%------------------------------------------------------------------------------
%% @doc Lookup topics subscribed
%% @end
%%------------------------------------------------------------------------------
-spec topics(Client :: pid()) -> [{binary(), mqtt_qos()}].
topics(Client) ->
    gen_fsm:sync_send_all_state_event(Client, topics).

%%------------------------------------------------------------------------------
%% @doc Publish message to broker with QoS0.
%% @end
%%------------------------------------------------------------------------------
-spec publish(Client, Topic, Payload) -> ok when
    Client    :: pid() | atom(),
    Topic     :: binary(),
    Payload   :: binary().
publish(Client, Topic, Payload) when is_binary(Topic), is_binary(Payload) ->
    publish(Client, #mqtt_message{topic = Topic, payload = Payload}).

%%------------------------------------------------------------------------------
%% @doc Publish message to broker with Qos, retain options.
%% @end
%%------------------------------------------------------------------------------
-spec publish(Client, Topic, Payload, PubOpts) -> ok when
    Client    :: pid() | atom(),
    Topic     :: binary(),
    Payload   :: binary(),
    PubOpts   :: mqtt_qosopt() | [mqtt_pubopt()].
publish(Client, Topic, Payload, QosOpt) when ?IS_QOS(QosOpt); is_atom(QosOpt) ->
    publish(Client, message(Topic, Payload, QosOpt));

publish(Client, Topic, Payload, PubOpts) when is_list(PubOpts) ->
    publish(Client, message(Topic, Payload, PubOpts)).

%%------------------------------------------------------------------------------
%% @doc Publish message to broker and return until Puback received.
%% @end
%%------------------------------------------------------------------------------
-spec sync_publish(Client, Topic, Payload, PubOpts) -> {ok, MsgId} | {error, timeout} when
    Client    :: pid() | atom(),
    Topic     :: binary(),
    Payload   :: binary(),
    PubOpts   :: mqtt_qosopt() | [mqtt_pubopt()],
    MsgId     :: mqtt_packet_id().
sync_publish(Client, Topic, Payload, QosOpt) when ?IS_QOS(QosOpt); is_atom(QosOpt) ->
    sync_publish(Client, message(Topic, Payload, QosOpt));

sync_publish(Client, Topic, Payload, PubOpts) when is_list(PubOpts) ->
    sync_publish(Client, message(Topic, Payload, PubOpts)).

%%------------------------------------------------------------------------------
%% @private
%% @doc Publish MQTT Message.
%% @end
%%------------------------------------------------------------------------------
-spec publish(Client, Message) -> ok when
    Client    :: pid() | atom(),
    Message   :: mqtt_message().
publish(Client, Msg) when is_record(Msg, mqtt_message) ->
    gen_fsm:send_event(Client, {publish, Msg}).

%%------------------------------------------------------------------------------
%% @private
%% @doc Publish MQTT Message and waits until Puback received.
%% @end
%%------------------------------------------------------------------------------
sync_publish(Client, Msg) when is_record(Msg, mqtt_message) ->
    gen_fsm:sync_send_event(Client, {publish, Msg}).

%% make mqtt message
message(Topic, Payload, QosOpt) when ?IS_QOS(QosOpt); is_atom(QosOpt) ->
    #mqtt_message{qos     = qos_opt(QosOpt),
                  topic   = Topic,
                  payload = Payload};

message(Topic, Payload, PubOpts) when is_list(PubOpts) ->
    #mqtt_message{qos     = qos_opt(PubOpts),
                  retain  = get_value(retain, PubOpts, false),
                  topic   = Topic,
                  payload = Payload}.

%%------------------------------------------------------------------------------
%% @doc Subscribe topic or topics.
%% @end
%%------------------------------------------------------------------------------
-spec subscribe(Client, Topics) -> ok when
    Client    :: pid() | atom(),
    Topics    :: [{binary(), mqtt_qos()}] | {binary(), mqtt_qos()} | binary().
subscribe(Client, Topic) when is_binary(Topic) ->
    subscribe(Client, {Topic, ?QOS_0});
subscribe(Client, {Topic, Qos}) when is_binary(Topic), (?IS_QOS(Qos) orelse is_atom(Qos)) ->
    subscribe(Client, [{Topic, qos_opt(Qos)}]);
subscribe(Client, [{_Topic, _Qos} | _] = Topics) ->
    send_subscribe(Client, [{Topic, qos_opt(Qos)} || {Topic, Qos} <- Topics]).

%%------------------------------------------------------------------------------
%% @doc Subscribe topic or topics and wait until suback received.
%% @end
%%------------------------------------------------------------------------------
-spec sync_subscribe(Client, Topics) -> {ok, (mqtt_qos() | ?QOS_UNAUTHORIZED) | [mqtt_qos() | ?QOS_UNAUTHORIZED]} when
    Client    :: pid() | atom(),
    Topics    :: [{binary(), mqtt_qos()}] | {binary(), mqtt_qos()} | binary().
sync_subscribe(Client, Topic) when is_binary(Topic) ->
    sync_subscribe(Client, {Topic, ?QOS_0});
sync_subscribe(Client, {Topic, Qos}) when is_binary(Topic), (?IS_QOS(Qos) orelse is_atom(Qos)) ->
    case sync_subscribe(Client, [{Topic, qos_opt(Qos)}]) of
        {ok, [GrantedQos]} ->
            {ok, GrantedQos};
        {error, Error} ->
            {error, Error}
    end;
sync_subscribe(Client, [{_Topic, _Qos} | _] = Topics) ->
    sync_send_subscribe(Client, [{Topic, qos_opt(Qos)} || {Topic, Qos} <- Topics]).

%%------------------------------------------------------------------------------
%% @doc Subscribe Topic with Qos.
%% @end
%%------------------------------------------------------------------------------
-spec subscribe(Client, Topic, Qos) -> ok when
    Client    :: pid() | atom(),
    Topic     :: binary(),
    Qos       :: qos0 | qos1 | qos2 | mqtt_qos().
subscribe(Client, Topic, Qos) when is_binary(Topic), (?IS_QOS(Qos) orelse is_atom(Qos)) ->
    subscribe(Client, [{Topic, qos_opt(Qos)}]).

%%------------------------------------------------------------------------------
%% @doc Subscribe Topic with QoS and wait until suback received.
%% @end
%%------------------------------------------------------------------------------
-spec sync_subscribe(Client, Topic, Qos) -> {ok, mqtt_qos() | ?QOS_UNAUTHORIZED} when
    Client    :: pid() | atom(),
    Topic     :: binary(),
    Qos       :: qos0 | qos1 | qos2 | mqtt_qos().
sync_subscribe(Client, Topic, Qos) when is_binary(Topic), (?IS_QOS(Qos) orelse is_atom(Qos)) ->
    case sync_send_subscribe(Client, [{Topic, qos_opt(Qos)}]) of
        {ok, [GrantedQos]} -> {ok, GrantedQos};
        {error, Error}     -> {error, Error}
    end.

send_subscribe(Client, TopicTable) ->
    gen_fsm:send_event(Client, {subscribe, self(), TopicTable}).

sync_send_subscribe(Client, TopicTable) ->
    gen_fsm:sync_send_event(Client, {subscribe, self(), TopicTable}, ?SYNC_SEND_TIMEOUT*1000).

%%------------------------------------------------------------------------------
%% @doc Unsubscribe Topics
%% @end
%%------------------------------------------------------------------------------
-spec unsubscribe(Client, Topics) -> ok when
    Client    :: pid() | atom(),
    Topics    :: [binary()] | binary().
unsubscribe(Client, Topic) when is_binary(Topic) ->
    unsubscribe(Client, [Topic]);
unsubscribe(Client, [Topic | _] = Topics) when is_binary(Topic) ->
    gen_fsm:send_event(Client, {unsubscribe, self(), Topics}).

%%------------------------------------------------------------------------------
%% @doc Sync Send ping to broker.
%% @end
%%------------------------------------------------------------------------------
-spec ping(Client) -> pong when Client :: pid() | atom().
ping(Client) ->
    gen_fsm:sync_send_event(Client, {self(), ping}, ?SYNC_SEND_TIMEOUT*1000).

%%------------------------------------------------------------------------------
%% @doc Disconnect from broker.
%% @end
%%------------------------------------------------------------------------------
-spec disconnect(Client) -> ok when Client :: pid() | atom().
disconnect(Client) ->
    gen_fsm:send_event(Client, disconnect).

%%%=============================================================================
%%% gen_fsm callbacks
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a gen_fsm is started using gen_fsm:start/[3,4] or
%% gen_fsm:start_link/[3,4], this function is called by the new
%% process to initialize.
%%
%% @end
%%------------------------------------------------------------------------------
-spec(init(Args :: term()) ->
    {ok, StateName :: atom(), StateData :: #state{}} |
    {ok, StateName :: atom(), StateData :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term()} | ignore).
init([undefined, Recipient, MqttOpts, TcpOpts]) ->
    init([pid_to_list(Recipient), Recipient, MqttOpts, TcpOpts]);

init([Name, Recipient, MqttOpts, TcpOpts]) ->

    process_flag(trap_exit, true),

    case get_value(client_id, MqttOpts) of
        undefined -> ?warn("ClientId is NULL!", []);
        _ -> ok
    end,

    ProtoState = emqttc_protocol:init(
                   emqttc_opts:merge([{keepalive, ?KEEPALIVE}], MqttOpts)),

    State = init(MqttOpts, #state{name            = Name,
                                  recipient       = Recipient,
                                  host            = "127.0.0.1",
                                  port            = 1883,
                                  proto_state     = ProtoState,
                                  keepalive_after = ?KEEPALIVE,
                                  connack_timeout = ?CONNACK_TIMEOUT,
                                  puback_timeout  = ?PUBACK_TIMEOUT,
                                  suback_timeout  = ?SUBACK_TIMEOUT,
                                  tcp_opts        = TcpOpts,
                                  ssl_opts        = []}),

    {ok, connecting, State, 0}.

init([], State) ->
    State;
init([{host, Host} | Opts], State) ->
    init(Opts, State#state{host = Host});
init([{port, Port} | Opts], State) ->
    init(Opts, State#state{port = Port});
init([ssl | Opts], State) ->
    ssl:start(), % ok?
    init(Opts, State#state{transport = ssl});
init([{ssl, SslOpts} | Opts], State) ->
    ssl:start(), % ok?
    init(Opts, State#state{transport = ssl, ssl_opts = SslOpts});
init([{auto_resub, Cfg} | Opts], State) when is_boolean(Cfg) ->
    init(Opts, State#state{auto_resub= Cfg});
init([auto_resub | Opts], State) ->
    init(Opts, State#state{auto_resub= true});
init([{force_ping, Cfg} | Opts], State) when is_boolean(Cfg) ->
    init(Opts, State#state{force_ping = Cfg});
init([force_ping | Opts], State) ->
    init(Opts, State#state{force_ping = true});
init([{keepalive, Time} | Opts], State) ->
    init(Opts, State#state{keepalive_after = Time});
init([{connack_timeout, Timeout}| Opts], State) ->
    init(Opts, State#state{connack_timeout = Timeout});
init([{puback_timeout, Timeout}| Opts], State) ->
    init(Opts, State#state{puback_timeout = Timeout});
init([{suback_timeout, Timeout}| Opts], State) ->
    init(Opts, State#state{suback_timeout = Timeout});
init([{reconnect, ReconnOpt} | Opts], State) ->
    init(Opts, State#state{reconnector = init_reconnector(ReconnOpt)});
init([_Opt | Opts], State) ->
    init(Opts, State).

init_reconnector(false) ->
    undefined;
init_reconnector(Params) when is_integer(Params) orelse is_tuple(Params) ->
    emqttc_reconnector:new(Params).

%%------------------------------------------------------------------------------
%% @private
%% @doc Event Handler for state that connecting to MQTT broker.
%% @end
%%------------------------------------------------------------------------------
connecting(timeout, State) ->
    connect(State).

%%------------------------------------------------------------------------------
%% @private
%% @doc Event Handler for state that waiting_for_connack from MQTT broker.
%% @end
%%------------------------------------------------------------------------------
waiting_for_connack(?CONNACK_PACKET(?CONNACK_ACCEPT), State = #state{
                recipient = Recipient,
                name = Name,
                pending_pubsub = Pending,
                auto_resub = AutoResub,
                pubsub_map = PubsubMap,
                proto_state = ProtoState,
                keepalive = KeepAlive,
                connack_tref = TRef}) ->
    ?info("[Client ~s] RECV: CONNACK_ACCEPT", [Name]),

    %% Cancel connack timer
    if
        TRef =:= undefined -> ok;
        true -> gen_fsm:cancel_timer(TRef)
    end,

    {ok, ProtoState1} = emqttc_protocol:received('CONNACK', ProtoState),

    %% Resubscribe automatically
    case AutoResub of
        true ->
            case [{Topic, Qos} || {Topic, {Qos, _Subs}} <- maps:to_list(PubsubMap)] of
                []         -> ok;
                TopicTable -> subscribe(self(), TopicTable)
            end;
        false ->
            ok
    end,

    %% Send the pending pubsub
    [gen_fsm:send_event(self(), Event) || Event <- lists:reverse(Pending)],

    %% Start keepalive
    case emqttc_keepalive:start(KeepAlive) of
        {ok, KeepAlive1} ->
            %% Tell recipient to subscribe
            Recipient ! {mqttc, self(), connected},

            {next_state, connected, State#state{proto_state = ProtoState1,
                                                keepalive = KeepAlive1,
                                                connack_tref = undefined,
                                                pending_pubsub = []}};
        {error, Error} ->
            {stop, {shutdown, Error}, State}
    end;

waiting_for_connack(?CONNACK_PACKET(ReturnCode), State = #state{name = Name}) ->
    ErrConnAck = emqttc_packet:connack_name(ReturnCode),
    ?debug("[Client ~s] RECV: ~s", [Name, ErrConnAck]),
    {stop, {shutdown, {connack_error, ErrConnAck}}, State};

waiting_for_connack(Packet = ?PACKET(_Type), State = #state{name = Name}) ->
    ?error("[Client ~s] RECV: ~s, when waiting for connack!", [Name, emqttc_packet:dump(Packet)]),
    next_state(waiting_for_connack, State);

waiting_for_connack(Event = {publish, _Msg}, State) ->
    next_state(waiting_for_connack, pending(Event, State));

waiting_for_connack(Event = {Tag, _From, _Topics}, State)
        when Tag =:= subscribe orelse Tag =:= unsubscribe ->
    next_state(waiting_for_connack, pending(Event, State));

waiting_for_connack(disconnect, State=#state{receiver = Receiver, proto_state = ProtoState}) ->
    emqttc_protocol:disconnect(ProtoState),
    emqttc_socket:stop(Receiver),
    {stop, normal, State#state{socket = undefined, receiver = undefined}};

waiting_for_connack({timeout, TRef, connack}, State = #state{name = Name, connack_tref = TRef}) ->
    ?error("[Client ~s] CONNACK Timeout!", [Name]),
    {stop, {shutdown, connack_timeout}, State};

waiting_for_connack(Event, State = #state{name = Name}) ->
    ?warn("[Client ~s] Unexpected Event: ~p, when waiting for connack!", [Name, Event]),
    {next_state, waiting_for_connack, State}.

%%------------------------------------------------------------------------------
%% @private
%% @doc Sync Event Handler for state that waiting_for_connack from MQTT broker.
%% @end
%%------------------------------------------------------------------------------
waiting_for_connack(Event, _From, State = #state{name = Name}) ->
    ?error("[Client ~s] Event when waiting_for_connack: ~p", [Name, Event]),
    {reply, {error, waiting_for_connack}, waiting_for_connack, State}.

%%------------------------------------------------------------------------------
%% @private
%% @doc Event Handler for state that connected to MQTT broker.
%% @end
%%------------------------------------------------------------------------------
connected({publish, Msg}, State=#state{proto_state = ProtoState}) ->
    {ok, _, ProtoState1} = emqttc_protocol:publish(Msg, ProtoState),
    next_state(connected, State#state{proto_state = ProtoState1});

connected({subscribe, SubPid, Topics}, State = #state{subscribers = Subscribers,
                                                      pubsub_map  = PubSubMap,
                                                      proto_state = ProtoState}) ->

    {ok, MsgId, ProtoState1} = emqttc_protocol:subscribe(Topics, ProtoState),

    %% monitor subscriber
    Subscribers1 =
    case lists:keyfind(SubPid, 1, Subscribers) of
        {SubPid, _MonRef} ->
            Subscribers;
        false ->
            [{SubPid, erlang:monitor(process, SubPid)} | Subscribers]
    end,

    %% register to pubsub
    PubSubMap1 = lists:foldl(
        fun({Topic, Qos}, Map) ->
            case maps:find(Topic, Map) of
                {ok, {OldQos, Subs}} ->
                    case lists:member(SubPid, Subs) of
                        true ->
                            if
                            Qos =:= OldQos ->
                                Map;
                            true ->
                                ?error("Subscribe topic '~s' with different qos: old=~p, new=~p", [Topic, OldQos, Qos]),
                                maps:put(Topic, {Qos, Subs}, Map)
                            end;
                        false ->
                            maps:put(Topic, {Qos, [SubPid| Subs]}, Map)
                    end;
                error ->
                    maps:put(Topic, {Qos, [SubPid]}, Map)
            end
        end, PubSubMap, Topics),

    next_state(connected, State#state{subscribers    = Subscribers1,
                                      pubsub_map     = PubSubMap1,
                                      inflight_msgid = MsgId,
                                      proto_state    = ProtoState1});

connected({unsubscribe, From, Topics}, State=#state{subscribers = Subscribers,
                                                    pubsub_map  = PubSubMap,
                                                    proto_state = ProtoState}) ->

    {ok, ProtoState1} = emqttc_protocol:unsubscribe(Topics, ProtoState),

    %% unregister from pubsub
    PubSubMap1 =
    lists:foldl(
        fun(Topic, Map) ->
            case maps:find(Topic, Map) of
                {ok, {Qos, Subs}} ->
                    case lists:member(From, Subs) of
                        true ->
                            maps:put(Topic, {Qos, lists:delete(From, Subs)}, Map);
                        false ->
                            Map
                    end;
                error ->
                    Map
            end
        end, PubSubMap, Topics),

    %% demonitor
    Subscribers1 =
    case lists:keyfind(From, 1, Subscribers) of
        {From, MonRef} ->
            case lists:member(From, lists:append([Subs || {_Qos, Subs} <- maps:values(PubSubMap1)])) of
                true ->
                    Subscribers;
                false ->
                    erlang:demonitor(MonRef, [flush]),
                    lists:keydelete(From, 1, Subscribers)
            end;
        false ->
            Subscribers
    end,

    next_state(connected, State#state{subscribers = Subscribers1,
                                      pubsub_map  = PubSubMap1,
                                      proto_state = ProtoState1});

connected(disconnect, State=#state{receiver = Receiver, proto_state = ProtoState}) ->
    emqttc_protocol:disconnect(ProtoState),
    emqttc_socket:stop(Receiver),
    {stop, normal, State#state{socket = undefined, receiver = undefined}};

connected(Packet = ?PACKET(_Type), State = #state{name = Name}) ->
    % ?debug("[Client ~s] RECV: ~s", [Name, emqttc_packet:dump(Packet)]),
    {ok, NewState} = received(Packet, State),
    next_state(connected, NewState);

connected(Event, State = #state{name = Name}) ->
    ?warn("[Client ~s] Unexpected Event: ~p, when broker connected!", [Name, Event]),
    next_state(connected, State).

%%------------------------------------------------------------------------------
%% @private
%% @doc Sync Event Handler for state that connected to MQTT broker.
%% @end
%%------------------------------------------------------------------------------

connected({publish, Msg = #mqtt_message{qos = ?QOS_0}}, _From, State=#state{proto_state = ProtoState}) ->
    {ok, _, ProtoState1} = emqttc_protocol:publish(Msg, ProtoState),
    {reply, ok, connected, State#state{proto_state = ProtoState1}};

connected({publish, Msg = #mqtt_message{qos = _Qos}}, From, State=#state{inflight_reqs  = InflightReqs,
                                                                         puback_timeout = AckTimeout,
                                                                         proto_state    = ProtoState}) ->
    {ok, MsgId, ProtoState1} = emqttc_protocol:publish(Msg, ProtoState),

    MRef = erlang:send_after(AckTimeout*1000, self(), {timeout, puback, MsgId}),

    InflightReqs1 = maps:put(MsgId, {publish, From, MRef}, InflightReqs),

    {next_state, connected, State#state{proto_state = ProtoState1, inflight_reqs = InflightReqs1}};

connected(Event = {subscribe, _SubPid, _Topics}, From, State = #state{inflight_reqs  = InflightReqs,
                                                                      suback_timeout = AckTimeout}) ->

    {next_state, _, State1 = #state{inflight_msgid = MsgId}, _} = connected(Event, State),

    MRef = erlang:send_after(AckTimeout*1000, self(), {timeout, suback, MsgId}),

    InflightReqs1 = maps:put(MsgId, {subscribe, From, MRef}, InflightReqs),

    {next_state, connected, State1#state{inflight_reqs = InflightReqs1}};

connected({Pid, ping}, From, State = #state{ping_reqs = PingReqs, proto_state = ProtoState}) ->
    emqttc_protocol:ping(ProtoState),
    PingReqs1 =
    case lists:keyfind(From, 1, PingReqs) of
        {From, _MonRef} ->
            PingReqs;
        false ->
            [{From, erlang:monitor(process, Pid)} | PingReqs]
    end,
    {next_state, connected, State#state{ping_reqs = PingReqs1}};

connected(Event, _From, State = #state{name = Name}) ->
    ?error("[Client ~s] Unexpected Sync Event when connected: ~p", [Name, Event]),
    {reply, {error, unexpected_event}, connected, State}.

%%------------------------------------------------------------------------------
%% @private
%% @doc Event Handler for state that disconnected from MQTT broker.
%% @end
%%------------------------------------------------------------------------------
disconnected(Event = {publish, _Msg}, State) ->
    next_state(disconnected, pending(Event, State));

disconnected(Event = {Tag, _From, _Topics}, State) when
      Tag =:= subscribe orelse Tag =:= unsubscribe ->
    next_state(disconnected, pending(Event, State));

disconnected(disconnect, State) ->
    {stop, normal, State};

disconnected(Event, State = #state{name = Name}) ->
    ?error("[Client ~s] Unexpected Event: ~p, when disconnected from broker!", [Name, Event]),
    next_state(disconnected, State).

%%------------------------------------------------------------------------------
%% @private
%% @doc Sync Event Handler for state that disconnected from MQTT broker.
%% @end
%%------------------------------------------------------------------------------
disconnected(Event, _From, State = #state{name = Name}) ->
    ?error("Client ~s] Unexpected Sync Event: ~p, when disconnected from broker!", [Name, Event]),
    {reply, {error, disonnected}, disconnected, State}.

%%------------------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a gen_fsm receives an event sent using
%% gen_fsm:send_all_state_event/2, this function is called to handle
%% the event.
%%
%% @end
%%------------------------------------------------------------------------------
-spec(handle_event(Event :: term(), StateName :: atom(),
    StateData :: #state{}) ->
    {next_state, NextStateName :: atom(), NewStateData :: #state{}} |
    {next_state, NextStateName :: atom(), NewStateData :: #state{},
        timeout() | hibernate} |
    {stop, Reason :: term(), NewStateData :: #state{}}).

handle_event({frame_error, Error}, _StateName, State = #state{name = Name}) ->
    ?error("[Client ~s] Frame Error: ~p", [Name, Error]),
    {stop, {shutdown, {frame_error, Error}}, State};

handle_event({connection_lost, Reason}, StateName, State = #state{recipient = Recipient, name = Name, keepalive = KeepAlive, connack_tref = TRef})
        when StateName =:= connected; StateName =:= waiting_for_connack ->

    ?warn("[Client ~s] Connection lost for: ~p", [Name, Reason]),

    %% cancel connack timer first, if connection lost when waiting for connack.
    case {StateName, TRef} of
        {waiting_for_connack, undefined} -> ok;
        {waiting_for_connack, TRef} -> gen_fsm:cancel_timer(TRef);
        _ -> ok
    end,

    %% cancel keepalive
    emqttc_keepalive:cancel(KeepAlive),

    %% tell recipient
    Recipient ! {mqttc, self(), disconnected},

    try_reconnect(Reason, State#state{socket = undefined, connack_tref = TRef});

handle_event(Event, StateName, State = #state{name = Name}) ->
    ?warn("[Client ~s] Unexpected Event when ~s: ~p", [Name, StateName, Event]),
    {next_state, StateName, State}.

%%------------------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a gen_fsm receives an event sent using
%% gen_fsm:sync_send_all_state_event/[2,3], this function is called
%% to handle the event.
%%
%% @end
%%------------------------------------------------------------------------------
-spec(handle_sync_event(Event :: term(), From :: {pid(), Tag :: term()},
    StateName :: atom(), StateData :: term()) ->
    {reply, Reply :: term(), NextStateName :: atom(), NewStateData :: term()} |
    {reply, Reply :: term(), NextStateName :: atom(), NewStateData :: term(),
        timeout() | hibernate} |
    {next_state, NextStateName :: atom(), NewStateData :: term()} |
    {next_state, NextStateName :: atom(), NewStateData :: term(),
        timeout() | hibernate} |
    {stop, Reason :: term(), Reply :: term(), NewStateData :: term()} |
    {stop, Reason :: term(), NewStateData :: term()}).
handle_sync_event(topics, _From, StateName, State = #state{pubsub_map = PubsubMap}) ->
    TopicTable = [{Topic, Qos} || {Topic, {Qos, _Subs}} <- maps:to_list(PubsubMap)],
    {reply, TopicTable, StateName, State};

handle_sync_event(_Event, _From, StateName, State) ->
    Reply = ok,
    {reply, Reply, StateName, State}.

%%------------------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_fsm when it receives any
%% message other than a synchronous or asynchronous event
%% (or a system message).
%%
%% @end
%%------------------------------------------------------------------------------

-spec(handle_info(Info :: term(), StateName :: atom(), StateData :: term()) ->
    {next_state, NextStateName :: atom(), NewStateData :: term()} |
    {next_state, NextStateName :: atom(), NewStateData :: term(), timeout() | hibernate} |
    {stop, Reason :: normal | term(), NewStateData :: term()}).
handle_info({timeout, suback, MsgId}, StateName, State) ->
    {next_state, StateName, reply_timeout({suback, MsgId}, State)};

handle_info({timeout, puback, MsgId}, StateName,  State) ->
    {next_state, StateName, reply_timeout({puback, MsgId}, State)};

handle_info({reconnect, timeout}, disconnected, State) ->
    connect(State);

handle_info({keepalive, timeout}, connected, State =
            #state{proto_state = ProtoState, keepalive = KeepAlive, force_ping = ForcePing}) ->
    case emqttc_keepalive:resume(KeepAlive) of
        timeout ->
            emqttc_protocol:ping(ProtoState),
            case emqttc_keepalive:restart(KeepAlive) of
                {ok, NewKeepAlive} ->
                    next_state(connected, State#state{keepalive = NewKeepAlive});
                {error, Error} ->
                    {stop, {shutdown, Error}, State}
            end;
        {resumed, NewKeepAlive} ->
            case ForcePing of
                true  -> emqttc_protocol:ping(ProtoState);
                false -> ignore
            end,
            next_state(connected, State#state{keepalive = NewKeepAlive});
        {error, Error} ->
            {stop, {shutdown, Error}, State}
    end;

handle_info({'EXIT', Receiver, normal}, StateName, State = #state{receiver = Receiver}) ->
    {next_state, StateName, State#state{receiver = undefined}};

handle_info({'EXIT', Receiver, Reason}, _StateName,
            State = #state{name = Name, receiver = Receiver,
                           keepalive = KeepAlive}) ->
    %% event occured when receiver error
    ?error("[Client ~s] receiver exit: ~p", [Name, Reason]),
    emqttc_keepalive:cancel(KeepAlive),
    try_reconnect({receiver, Reason}, State#state{receiver = undefined, socket = undefined});

handle_info(Down = {'DOWN', MonRef, process, Pid, _Why}, StateName,
            State = #state{name = Name,
                           subscribers = Subscribers,
                           pubsub_map  = PubSubMap,
                           ping_reqs = PingReqs}) ->
    ?warn("[Client ~s] Process DOWN: ~p", [Name, Down]),

    %% ping?
    PingReqs1 = lists:keydelete(MonRef, 2, PingReqs),

    %% clear pubsub
    {Subscribers1, PubSubMap1} =
    case lists:keyfind(MonRef, 2, Subscribers) of
        {Pid, MonRef} ->
            {lists:delete({Pid, MonRef}, Subscribers),
                maps:fold(fun(Topic, {Qos, Subs}, Map) ->
                        case lists:member(Pid, Subs) of
                            true -> maps:put(Topic, {Qos, lists:delete(Pid, Subs)}, Map);
                            false -> Map
                        end
                    end, PubSubMap, PubSubMap)};
        false ->
            {Subscribers, PubSubMap}
    end,

    next_state(StateName, State#state{subscribers = Subscribers1,
                                      pubsub_map = PubSubMap1,
                                      ping_reqs = PingReqs1});

handle_info({inet_reply, Socket, ok}, StateName, State = #state{socket = Socket}) ->
    %socket send reply.
    next_state(StateName, State);

handle_info(Info, StateName, State = #state{name = Name}) ->
    ?error("[Client ~s] Unexpected Info when ~s: ~p", [Name, StateName, Info]),
    {next_state, StateName, State}.

%%------------------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_fsm when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_fsm terminates with
%% Reason. The return value is ignored.
%%
%% @end
%%------------------------------------------------------------------------------
-spec(terminate(Reason :: normal | shutdown | {shutdown, term()}
| term(), StateName :: atom(), StateData :: term()) -> term()).
terminate(_Reason, _StateName, #state{keepalive = KeepAlive, reconnector = Reconnector}) ->
    emqttc_keepalive:cancel(KeepAlive),
    if
        Reconnector =:= undefined -> ok;
        true -> emqttc_reconnector:reset(Reconnector)
    end,
    ok.

%%------------------------------------------------------------------------------
%% @private
%% @doc Convert process state when code is changed
%% @end
%%------------------------------------------------------------------------------
-spec(code_change(OldVsn :: term() | {down, term()}, StateName :: atom(),
    StateData :: #state{}, Extra :: term()) ->
    {ok, NextStateName :: atom(), NewStateData :: #state{}}).
code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

next_state(StateName, State) ->
    {next_state, StateName, State, hibernate}.

connect(State = #state{name = Name,
                       host = Host,
                       port = Port,
                       socket = undefined,
                       receiver = undefined,
                       proto_state = ProtoState,
                       keepalive_after = KeepAliveTime,
                       connack_timeout = ConnAckTimeout,
                       transport = Transport,
                       tcp_opts = TcpOpts,
                       ssl_opts = SslOpts}) ->
    ?info("[Client ~s]: connecting to ~s:~p", [Name, Host, Port]),
    case emqttc_socket:connect(self(), Transport, Host, Port, TcpOpts, SslOpts) of
        {ok, Socket, Receiver} ->
            ProtoState1 = emqttc_protocol:set_socket(ProtoState, Socket),
            emqttc_protocol:connect(ProtoState1),
            KeepAlive = emqttc_keepalive:new({Socket, send_oct}, KeepAliveTime, {keepalive, timeout}),
            TRef = gen_fsm:start_timer(ConnAckTimeout*1000, connack),
            ?info("[Client ~s] connected with ~s:~p", [Name, Host, Port]),
            {next_state, waiting_for_connack, State#state{socket = Socket,
                                                          receiver = Receiver,
                                                          keepalive = KeepAlive,
                                                          connack_tref = TRef,
                                                          proto_state = ProtoState1}};
        {error, Reason} ->
            ?info("[Client ~s] connection failure: ~p", [Name, Reason]),
            try_reconnect(Reason, State)
    end.

try_reconnect(Reason, State = #state{reconnector = undefined}) ->
    {stop, {shutdown, Reason}, State};

try_reconnect(Reason, State = #state{name = Name, reconnector = Reconnector}) ->
    ?info("[Client ~s] try reconnecting...", [Name]),
    case emqttc_reconnector:execute(Reconnector, {reconnect, timeout}) of
    {ok, Reconnector1} ->
        {next_state, disconnected, State#state{reconnector = Reconnector1}};
    {stop, Error} ->
        ?error("[Client ~s] reconect error: ~p", [Name, Error]),
        {stop, {shutdown, Reason}, State}
    end.

pending(Event, State = #state{pending_pubsub = Pending}) ->
    State#state{pending_pubsub = [Event | Pending]}.

%%------------------------------------------------------------------------------
%% @private
%% @doc Handle Received Packet
%% @end
%%------------------------------------------------------------------------------
received(?PUBLISH_PACKET(?QOS_0, Topic, undefined, Payload), State) ->
    dispatch({publish, Topic, Payload}, State),
    {ok, State};

received(Packet = ?PUBLISH_PACKET(?QOS_1, Topic, _PacketId, Payload), State = #state{proto_state = ProtoState}) ->

    emqttc_protocol:received({'PUBLISH', Packet}, ProtoState),

    dispatch({publish, Topic, Payload}, State),

    {ok, State};

received(Packet = ?PUBLISH_PACKET(?QOS_2, _Topic, _PacketId, _Payload), State = #state{proto_state = ProtoState}) ->

    {ok, ProtoState1} = emqttc_protocol:received({'PUBLISH', Packet}, ProtoState),

    {ok, State#state{proto_state = ProtoState1}};

received(?PUBACK_PACKET(?PUBACK, PacketId), State = #state{proto_state = ProtoState}) ->

    {ok, ProtoState1} = emqttc_protocol:received({'PUBACK', PacketId}, ProtoState),

    {ok, reply({publish, PacketId}, {ok, PacketId}, State#state{proto_state = ProtoState1})};

received(?PUBACK_PACKET(?PUBREC, PacketId), State = #state{proto_state = ProtoState}) ->

    {ok, ProtoState1} = emqttc_protocol:received({'PUBREC', PacketId}, ProtoState),

    {ok, State#state{proto_state = ProtoState1}};

received(?PUBACK_PACKET(?PUBREL, PacketId), State = #state{proto_state = ProtoState}) ->
    ProtoState2 =
    case emqttc_protocol:received({'PUBREL', PacketId}, ProtoState) of
        {ok, ?PUBLISH_PACKET(?QOS_2, Topic, PacketId, Payload), ProtoState1} ->
            dispatch({publish, Topic, Payload}, State), ProtoState1;
        {ok, ProtoState1} -> ProtoState1
    end,
    emqttc_protocol:pubcomp(PacketId, ProtoState2),
    {ok, State#state{proto_state = ProtoState2}};

received(?PUBACK_PACKET(?PUBCOMP, PacketId), State = #state{proto_state = ProtoState}) ->

    {ok, ProtoState1} = emqttc_protocol:received({'PUBCOMP', PacketId}, ProtoState),

    {ok, reply({publish, PacketId}, {ok, PacketId}, State#state{proto_state = ProtoState1})};

received(?SUBACK_PACKET(PacketId, QosTable), State = #state{proto_state = ProtoState}) ->

    {ok, ProtoState1} = emqttc_protocol:received({'SUBACK', PacketId, QosTable}, ProtoState),

    {ok, reply({subscribe, PacketId}, {ok, QosTable}, State#state{proto_state = ProtoState1})};

received(?UNSUBACK_PACKET(PacketId), State = #state{proto_state = ProtoState}) ->
    {ok, ProtoState1} = emqttc_protocol:received({'UNSUBACK', PacketId}, ProtoState),
    {ok, State#state{proto_state = ProtoState1}};

received(?PACKET(?PINGRESP), State= #state{ping_reqs = PingReqs}) ->
    [begin erlang:demonitor(Mon), gen_fsm:reply(Caller, pong) end || {Caller, Mon} <- PingReqs],
    {ok, State#state{ping_reqs = []}}.

%%------------------------------------------------------------------------------
%% @private
%% @doc Reply to synchronous request.
%% @end
%%------------------------------------------------------------------------------
reply({PubSub, ReqId}, Reply, State = #state{inflight_reqs = InflightReqs}) ->
    InflightReqs1 =
    case maps:find(ReqId, InflightReqs) of
        {ok, {PubSub, From, MRef}} ->
            erlang:cancel_timer(MRef),
            gen_fsm:reply(From, Reply),
            maps:remove(ReqId, InflightReqs);
        error ->
            InflightReqs
    end,
    State#state{inflight_reqs = InflightReqs1}.

reply_timeout({Ack, ReqId}, State=#state{inflight_reqs = InflightReqs}) ->
    InflightReqs1 =
    case maps:find(ReqId, InflightReqs) of
        {ok, {_Pubsub, From, _MRef}} ->
            gen_fsm:reply(From, {error, ack_timeout}),
            maps:remove(ReqId, InflightReqs);
       error ->
            ?error("~s timeout, cannot find inflight reqid: ~p", [Ack, ReqId]),
            InflightReqs
    end,
    State#state{inflight_reqs = InflightReqs1}.

%%------------------------------------------------------------------------------
%% @private
%% @doc Dispatch Publish Message to subscribers.
%% @end
%%------------------------------------------------------------------------------
dispatch(Publish = {publish, TopicName, _Payload}, #state{recipient = Recipient,
                                                          pubsub_map = PubSubMap}) ->
    Matched =
    lists:foldl(
        fun(TopicFilter, Acc) ->
                case emqttc_topic:match(TopicName, TopicFilter) of
                    true ->
                        {_Qos, Subs} = maps:get(TopicFilter, PubSubMap),
                        lists:append(Subs, Acc);
                    false ->
                        Acc
                end
        end, [], maps:keys(PubSubMap)),
    if
        length(Matched) =:= 0 ->
            %% Dispath to Recipient if no subscription matched.
            Recipient ! Publish;
        true ->
            [Sub ! Publish || Sub <- unique(Matched)], ok
    end.

qos_opt(qos2) ->
    ?QOS_2;
qos_opt(qos1) ->
    ?QOS_1;
qos_opt(qos0) ->
    ?QOS_0;
qos_opt(Qos) when is_integer(Qos), ?QOS_0 =< Qos, Qos =< ?QOS_2 ->
    Qos;
qos_opt([]) ->
    ?QOS_0;
qos_opt([qos2|_PubOpts]) ->
    ?QOS_2;
qos_opt([qos1|_PubOpts]) ->
    ?QOS_1;
qos_opt([qos0|_PubOpts]) ->
    ?QOS_0;
qos_opt([{qos, Qos}|_PubOpts]) ->
    Qos;
qos_opt([_|PubOpts]) ->
    qos_opt(PubOpts).

unique(L) ->
    sets:to_list(sets:from_list(L)).

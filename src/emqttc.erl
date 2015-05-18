%%%-----------------------------------------------------------------------------
%%% Copyright (c) 2012-2015 eMQTT.IO, All Rights Reserved.
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

-author("feng@emqtt.io").

-author("hiroe.orz@gmail.com").

-include("emqttc_packet.hrl").

-import(proplists, [get_value/2, get_value/3]).

%% Start Application.
-export([start/0]).

%% Start emqttc client
-export([start_link/0, start_link/1, start_link/2]).

%% API
-export([publish/3, publish/4, 
         subscribe/2, subscribe/3, 
         unsubscribe/2, 
         ping/1, 
         disconnect/1]).

-behaviour(gen_fsm).

%% gen_fsm callbacks
-export([init/1, 
         handle_event/3,
         handle_sync_event/4, 
         handle_info/3,
         terminate/3,
         code_change/4]).

%% fsm state
-export([connecting/2,
         waiting_for_connack/2, waiting_for_connack/3, 
         connected/2, connected/3, 
         disconnected/2, disconnected/3]).

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
                   | ssl
                   | {logger, atom() | {atom(), atom()}}
                   | {reconnect, non_neg_integer() | {non_neg_integer(), non_neg_integer()} | false}.

-type mqtt_pubopt() :: {qos, mqtt_qos()} | {retain, boolean()}.

-record(state, {
        parent              :: pid(),
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
        keepalive           :: emqttc_keepalive:keepalive() | undefined,
        keepalive_time = 60 :: non_neg_integer(),
        connack_timeout     :: pos_integer(),
        connack_tref        :: reference(),
        transport = tcp     :: tcp | ssl,
        reconnector         :: emqttc_reconnector:reconnector() | undefined,
        logger              :: gen_logger:logmod()}).

%% seconds
-define(CONNACK_TIMEOUT, 30).

-define(KEEPALIVE_EVENT, {keepalive, timeout}).

-define(RECONNECT_EVENT, {reconnect, timeout}).

%%%=============================================================================
%%% API
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Start emqttc application
%% @end
%%------------------------------------------------------------------------------
-spec start() -> ok.
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
    gen_fsm:start_link(?MODULE, [undefined, self(), MqttOpts], []).

%%------------------------------------------------------------------------------
%% @doc Start emqttc client with name, options.
%% @end
%%------------------------------------------------------------------------------
-spec start_link(Name, MqttOpts) -> {ok, pid()} | ignore | {error, any()} when
    Name      :: atom(),
    MqttOpts  :: [mqttc_opt()].
start_link(Name, MqttOpts) when is_atom(Name), is_list(MqttOpts) ->
    gen_fsm:start_link({local, Name}, ?MODULE, [Name, self(), MqttOpts], []).

%%------------------------------------------------------------------------------
%% @doc Publish message to broker with QoS0.
%% @end
%%------------------------------------------------------------------------------
-spec publish(Client, Topic, Payload) -> ok | {ok, MsgId} when
    Client    :: pid() | atom(),
    Topic     :: binary(),
    Payload   :: binary(),
    MsgId     :: mqtt_packet_id().
publish(Client, Topic, Payload) when is_binary(Topic), is_binary(Payload) ->
    publish(Client, #mqtt_message{topic = Topic, payload = Payload}).

%%------------------------------------------------------------------------------
%% @doc Publish message to broker with Qos, retain options.
%% @end
%%------------------------------------------------------------------------------
-spec publish(Client, Topic, Payload, PubOpts) -> ok | {ok, MsgId} when
    Client    :: pid() | atom(),
    Topic     :: binary(),
    Payload   :: binary(),
    PubOpts   :: mqtt_qos() | [mqtt_pubopt()],
    MsgId     :: mqtt_packet_id().
publish(Client, Topic, Payload, PubOpts) when is_binary(Topic), is_binary(Payload) ->
    publish(Client, #mqtt_message{
        qos = get_value(qos, PubOpts, ?QOS_0),
        retain  = get_value(retain, PubOpts, false),
        topic   = Topic,
        payload = Payload}).

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
%% @doc Subscribe Topic or Topics.
%% @end
%%------------------------------------------------------------------------------
-spec subscribe(Client, Topics) -> ok when
    Client    :: pid() | atom(),
    Topics    :: [{binary(), mqtt_qos()}] | {binary(), mqtt_qos()} | binary().
subscribe(Client, Topic) when is_binary(Topic) ->
    subscribe(Client, [{Topic, ?QOS_0}]);
subscribe(Client, {Topic, Qos}) when is_binary(Topic), ?IS_QOS(Qos) ->
    subscribe(Client, [{Topic, Qos}]);
subscribe(Client, [{Topic, Qos} | _] = Topics) when is_binary(Topic), ?IS_QOS(Qos) ->
    gen_fsm:send_event(Client, {subscribe, self(), Topics}).

%%------------------------------------------------------------------------------
%% @doc Subscribe Topic with Qos.
%% @end
%%------------------------------------------------------------------------------
-spec subscribe(Client, Topic, Qos) -> ok when
    Client    :: pid() | atom(),
    Topic     :: binary(),
    Qos       :: mqtt_qos().
subscribe(Client, Topic, Qos) when is_binary(Topic), ?IS_QOS(Qos) ->
    subscribe(Client, [{Topic, Qos}]).

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
    gen_fsm:sync_send_event(Client, ping).

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
init([undefined, Parent, MqttOpts]) ->
    init([pid_to_list(self()), Parent, MqttOpts]);

init([Name, Parent, MqttOpts]) ->

    process_flag(trap_exit, true),

    Logger = gen_logger:new(get_value(logger, MqttOpts, {console, debug})),

    MqttOpts1 = proplists:delete(logger, MqttOpts),

    case get_value(client_id, MqttOpts1) of
        undefined -> Logger:warning("ClientId is NULL!");
        _ -> ok
    end,

    ProtoState = emqttc_protocol:init([{logger, Logger} | MqttOpts1]),

    IsSSL = get_value(ssl, MqttOpts1, false),

    State = init(MqttOpts1, #state{
                    parent       = Parent,
                    name         = Name,
                    host         = "localhost",
                    port         = if IsSSL -> 8883;
                                      true  -> 1883 end,
                    proto_state  = ProtoState,
                    connack_timeout = ?CONNACK_TIMEOUT,
                    logger       = Logger}),

    {ok, connecting, State, 0}.

init([], State) ->
    State;
init([{host, Host} | Opts], State) ->
    init(Opts, State#state{host = Host});
init([{port, Port} | Opts], State) ->
    init(Opts, State#state{port = Port});
init([ssl | Opts], State) ->
    ssl:start(), % ok? hehe...
    init(Opts, State#state{transport = ssl});
init([{logger, Cfg} | Opts], State) ->
    init(Opts, State#state{logger = gen_logger:new(Cfg)});
init([{keepalive, Time} | Opts], State) ->
    init(Opts, State#state{keepalive_time = Time});
init([{connack_timeout, Timeout}| Opts], State) ->
    init(Opts, State#state{connack_timeout = Timeout});
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
                parent = Parent,
                name = Name, 
                pending_pubsub = Pending,
                proto_state = ProtoState,
                keepalive = KeepAlive,
                connack_tref = TRef,
                logger = Logger}) ->
    Logger:info("[Client ~s] RECV: CONNACK_ACCEPT", [Name]),

    %% cancel connack timer
    if
        TRef =:= undefined -> ok;
        true -> gen_fsm:cancel_timer(TRef)
    end,

    {ok, ProtoState1} = emqttc_protocol:received('CONNACK', ProtoState),

    %% send the pending pubsub
    [gen_fsm:send_event(self(), Event) || Event <- lists:reverse(Pending)],

    %% start keepalive
    KeepAlive1 = emqttc_keepalive:start(KeepAlive),

    %% tell parent to subscribe
    Parent ! {mqttc, self(), connected},

    {next_state, connected, State#state{proto_state = ProtoState1,
                                        keepalive = KeepAlive1,
                                        connack_tref = undefined,
                                        pending_pubsub = []}};

waiting_for_connack(?CONNACK_PACKET(ReturnCode), State = #state{name = Name, logger = Logger}) ->
    ErrConnAck = emqttc_packet:connack_name(ReturnCode),
    Logger:debug("[Client ~s] RECV: ~s", [Name, ErrConnAck]),
    {stop, {shutdown, ErrConnAck}, State};

waiting_for_connack(Packet = ?PACKET(_Type), State = #state{name = Name, logger = Logger}) ->
    Logger:error("[Client ~s] RECV: ~s, when waiting for connack!", [Name, emqttc_packet:dump(Packet)]),
    {next_state, waiting_for_connack, State};

waiting_for_connack(Event = {publish, _Msg}, State) ->
    {next_state, waiting_for_connack, pending(Event, State)};

waiting_for_connack(Event = {Tag, _From, _Topics}, State) 
        when Tag =:= subscribe orelse Tag =:= unsubscribe ->
    {next_state, waiting_for_connack, pending(Event, State)};

waiting_for_connack(disconnect, State=#state{receiver = Receiver, proto_state = ProtoState}) ->
    emqttc_protocol:disconnect(ProtoState),
    emqttc_socket:stop(Receiver),
    {stop, normal, State#state{socket = undefined, receiver = undefined}};

waiting_for_connack({timeout, TRef, connack}, State = #state{name = Name, logger = Logger, connack_tref = TRef}) ->
    Logger:error("[Client ~s] CONNACK Timeout!", [Name]),
    {stop, {shutdown, connack_timeout}, State};

waiting_for_connack(Event, State = #state{name = Name, logger = Logger}) ->
    Logger:warning("[Client ~s] Unexpected Event: ~p, when waiting for connack!", [Name, Event]),
    {next_state, waiting_for_connack, State}.

%%------------------------------------------------------------------------------
%% @private
%% @doc Sync Event Handler for state that waiting_for_connack from MQTT broker.
%% @end
%%------------------------------------------------------------------------------
waiting_for_connack(Event, _From, State = #state{name = Name, logger = Logger}) ->
    Logger:warning("[Client ~s] Unexpected Sync Event when waiting_for_connack: ~p", [Name, Event]),
    {reply, {error, waiting_for_connack}, waiting_for_connack, State}.

%%------------------------------------------------------------------------------
%% @private
%% @doc Event Handler for state that connected to MQTT broker.
%% @end
%%------------------------------------------------------------------------------
connected({publish, Msg}, State=#state{proto_state = ProtoState}) ->
    {ok, ProtoState1} = emqttc_protocol:publish(Msg, ProtoState),
    {next_state, connected, State#state{proto_state = ProtoState1}};

connected({subscribe, From, Topics}, State = #state{subscribers = Subscribers, 
                                                    pubsub_map  = PubSubMap, 
                                                    proto_state = ProtoState}) ->

    {ok, ProtoState1} = emqttc_protocol:subscribe(Topics, ProtoState),

    %% monitor subscriber
    Subscribers1 = 
    case lists:keyfind(From, 1, Subscribers) of
        {From, _MonRef} -> 
            Subscribers;
        false -> 
            MonRef = erlang:monitor(process, From),
            [{From, MonRef} | Subscribers]
    end,

    %% register to pubsub
    PubSubMap1 = lists:foldl(
        fun({Topic, _Qos}, Map) ->
            case maps:find(Topic, Map) of 
                {ok, Subs} ->
                    case lists:member(From, Subs) of
                        true -> Map;
                        false -> maps:put(Topic, [From | Subs], Map)
                    end; 
                error ->
                    maps:put(Topic, [From], Map)
            end
        end, PubSubMap, Topics),

    {next_state, connected, State#state{subscribers = Subscribers1,
                                        pubsub_map  = PubSubMap1,
                                        proto_state = ProtoState1}};

connected({unsubscribe, From, Topics}, State=#state{subscribers = Subscribers,
                                                    pubsub_map  = PubSubMap,
                                                    proto_state = ProtoState}) ->
    {ok, ProtoState1} = emqttc_protocol:unsubscribe(Topics, ProtoState),

    %% unregister from pubsub
    PubSubMap1 = 
    lists:foldl(
        fun(Topic, Map) ->
            case maps:find(Topic, Map) of
                {ok, Subs} ->
                    case lists:member(From, Subs) of
                        true ->
                            maps:put(Topic, lists:delete(From, Subs), Map);
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
            case lists:member(From, lists:flatten(maps:values(PubSubMap1))) of
                true -> 
                    Subscribers;
                false ->
                    erlang:demonitor(MonRef, [flush]),
                    lists:keydelete(From, 1, Subscribers)
            end;
        false -> 
            Subscribers
    end,

    {next_state, connected, State#state{subscribers = Subscribers1,
                                        pubsub_map  = PubSubMap1,
                                        proto_state = ProtoState1}};

connected(disconnect, State=#state{receiver = Receiver, proto_state = ProtoState}) ->
    emqttc_protocol:disconnect(ProtoState),
    emqttc_socket:stop(Receiver),
    {stop, normal, State#state{socket = undefined, receiver = undefined}};

connected(Packet = ?PACKET(_Type), State = #state{name = Name, logger = Logger}) ->
    Logger:debug("[Client ~s] RECV: ~s", [Name, emqttc_packet:dump(Packet)]),
    {ok, NewState} = received(Packet, State),
    {next_state, connected, NewState};

connected(Event, State = #state{name = Name, logger = Logger}) ->
    Logger:warning("[Client ~s] Unexpected Event: ~p, when broker connected!", [Name, Event]),
    {next_state, connected, State}.

%%------------------------------------------------------------------------------
%% @private
%% @doc Sync Event Handler for state that connected to MQTT broker.
%% @end
%%------------------------------------------------------------------------------
connected(ping, {Pid, _} = From, State = #state{ping_reqs = PingReqs, proto_state = ProtoState}) ->
    emqttc_protocol:ping(ProtoState),
    PingReqs1 =
    case lists:keyfind(From, 1, PingReqs) of
        {From, _MonRef} ->
            PingReqs;
        false ->
            [{From, erlang:monitor(process, Pid)} | PingReqs]
    end,
    {next_state, connected, State#state{ping_reqs = PingReqs1}};

connected(Event, _From, State = #state{name = Name, logger = Logger}) ->
    Logger:error("[Client ~s] Unexpected Sync Event when connected: ~p", [Name, Event]),
    {reply, {error, unexpected_event}, connected, State}.

%%------------------------------------------------------------------------------
%% @private
%% @doc Event Handler for state that disconnected from MQTT broker.
%% @end
%%------------------------------------------------------------------------------
disconnected(Event = {publish, _Msg}, State) ->
    {next_state, disconnected, pending(Event, State)};

disconnected(Event = {Tag, _From, _Topics}, State) when 
      Tag =:= subscribe orelse Tag =:= unsubscribe ->
    io:format("Pending event for client disconnected: ~p~n", [Event]),
    {next_state, disconnected, pending(Event, State)};

disconnected(disconnect, State) ->
    {stop, normal, State};

disconnected(Event, State = #state{name = Name, logger = Logger}) ->
    Logger:error("[Client ~s] Unexpected Event: ~p, when disconnected from broker!", [Name, Event]),
    {next_state, disconnected, State}.

%%------------------------------------------------------------------------------
%% @private
%% @doc Sync Event Handler for state that disconnected from MQTT broker.
%% @end
%%------------------------------------------------------------------------------
disconnected(Event, _From, State = #state{name = Name, logger = Logger}) ->
    Logger:error("Client ~s] Unexpected Sync Event: ~p, when disconnected from broker!", [Name, Event]),
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

handle_event({connection_lost, Reason}, StateName, State = #state{parent = Parent, name = Name, keepalive = KeepAlive, connack_tref = TRef, logger = Logger}) 
        when StateName =:= connected; StateName =:= waiting_for_connack ->

    Logger:warning("[Client ~s] Connection lost for: ~p", [Name, Reason]),

    %% cancel connack timer first, if connection lost when waiting for connack.
    case {StateName, TRef} of
        {waiting_for_connack, undefined} -> ok;
        {waiting_for_connack, TRef} -> gen_fsm:cancel_timer(TRef);
        _ -> ok
    end,

    %% cancel keepalive
    emqttc_keepalive:cancel(KeepAlive),

    %% tell parent
    Parent ! {mqttc, self(), disconnected},

    try_reconnect(Reason, State#state{socket = undefined, connack_tref = TRef});

handle_event(Event, StateName, State = #state{name = Name, logger = Logger}) ->
    Logger:warning("[Client ~s] Unexpected Event when ~s: ~p", [Name, StateName, Event]),
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
-spec(handle_info(Info :: term(), StateName :: atom(),
    StateData :: term()) ->
    {next_state, NextStateName :: atom(), NewStateData :: term()} |
    {next_state, NextStateName :: atom(), NewStateData :: term(),
        timeout() | hibernate} |
    {stop, Reason :: normal | term(), NewStateData :: term()}).

handle_info(?RECONNECT_EVENT, disconnected, State) ->
    connect(State);

handle_info(?KEEPALIVE_EVENT, connected, State = #state{proto_state = ProtoState, keepalive = KeepAlive}) ->
    NewKeepAlive =
    case emqttc_keepalive:resume(KeepAlive) of
        timeout -> 
            emqttc_protocol:ping(ProtoState),
            emqttc_keepalive:restart(KeepAlive);
        {resumed, KeepAlive1} -> 
            KeepAlive1
    end,
    {next_state, connected, State#state{keepalive = NewKeepAlive}};

handle_info({'EXIT', Receiver, normal}, StateName, State = #state{receiver = Receiver}) ->
    {next_state, StateName, State#state{receiver = undefined}};

handle_info({'EXIT', Receiver, Reason}, _StateName, 
            State = #state{name = Name, receiver = Receiver, 
                           keepalive = KeepAlive, logger = Logger}) ->
    %% event occured when receiver error
    Logger:error("[Client ~s] receiver exit: ~p", [Name, Reason]),
    emqttc_keepalive:cancel(KeepAlive),
    try_reconnect({receiver, Reason}, State#state{receiver = undefined});

handle_info(Down = {'DOWN', MonRef, process, Pid, _Why}, StateName,
            State = #state{name = Name,
                           subscribers = Subscribers,
                           pubsub_map  = PubSubMap,
                           ping_reqs = PingReqs,
                           logger = Logger}) ->
    Logger:warning("[Client ~s] Process DOWN: ~p", [Name, Down]),

    %% ping?
    PingReqs1 = lists:keydelete(MonRef, 2, PingReqs),

    %% clear pubsub
    {Subscribers1, PubSubMap1} =
    case lists:keyfind(MonRef, 2, Subscribers) of
        {Pid, MonRef} ->
            {lists:delete({Pid, MonRef}, Subscribers),
                maps:fold(fun(Topic, Subs, Map) ->
                        case lists:member(Pid, Subs) of
                                true -> maps:put(Topic, lists:delete(Pid, Subs), Map);
                                false -> Map
                        end
                    end, PubSubMap, PubSubMap)};
        false ->
            {Subscribers, PubSubMap}
    end,

    {next_state, StateName, State#state{subscribers = Subscribers1,
                                        pubsub_map = PubSubMap1,
                                        ping_reqs = PingReqs1 }};

handle_info({inet_reply, Socket, ok}, StateName, State = #state{socket = Socket}) ->
    %socket send reply.
    {next_state, StateName, State};
    
handle_info(Info, StateName, State = #state{name = Name, logger = Logger}) ->
    Logger:error("[Client ~s] Unexpected Info when ~s: ~p", [Name, StateName, Info]),
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
connect(State = #state{name = Name, 
                       host = Host, 
                       port = Port, 
                       socket = undefined, 
                       receiver = undefined,
                       proto_state = ProtoState, 
                       keepalive_time = KeepAliveTime,
                       connack_timeout = ConnAckTimeout,
                       transport = Transport,
                       logger = Logger}) ->
    Logger:info("[Client ~s]: connecting to ~s:~p", [Name, Host, Port]),
    case emqttc_socket:connect(self(), Transport, Host, Port) of
        {ok, Socket, Receiver} ->
            ProtoState1 = emqttc_protocol:set_socket(ProtoState, Socket),
            emqttc_protocol:connect(ProtoState1),
            KeepAlive = emqttc_keepalive:new({Socket, send_oct}, KeepAliveTime, ?KEEPALIVE_EVENT),
            TRef = gen_fsm:start_timer(ConnAckTimeout * 1000, connack),
            Logger:info("[Client ~s] connected with ~s:~p", [Name, Host, Port]),
            {next_state, waiting_for_connack, State#state{socket = Socket,
                                                          receiver = Receiver,
                                                          keepalive = KeepAlive,
                                                          connack_tref = TRef,
                                                          proto_state = ProtoState1}};
        {error, Reason} ->
            Logger:info("[Client ~s] connection failure: ~p", [Name, Reason]),
            try_reconnect(Reason, State)
    end.

try_reconnect(Reason, State = #state{reconnector = undefined}) ->
    {stop, {shutdown, Reason}, State};

try_reconnect(Reason, State = #state{name = Name, reconnector = Reconnector, logger = Logger}) ->
    Logger:info("[Client ~s] try reconnecting...", [Name]),
    case emqttc_reconnector:execute(Reconnector, ?RECONNECT_EVENT) of
    {ok, Reconnector1} ->
        {next_state, disconnected, State#state{reconnector = Reconnector1}};
    {stop, Error} ->
        Logger:error("[Client ~s] reconect error: ~p", [Name, Error]),
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
    {ok, State#state{proto_state = ProtoState1}};

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
    {ok, State#state{proto_state = ProtoState1}};

received(?SUBACK_PACKET(PacketId, QosTable), State = #state{proto_state = ProtoState}) ->
    {ok, ProtoState1} = emqttc_protocol:received({'SUBACK', PacketId, QosTable}, ProtoState),
    {ok, State#state{proto_state = ProtoState1}};

received(?UNSUBACK_PACKET(PacketId), State = #state{proto_state = ProtoState}) ->
    {ok, ProtoState1} = emqttc_protocol:received({'UNSUBACK', PacketId}, ProtoState),
    {ok, State#state{proto_state = ProtoState1}};

received(?PACKET(?PINGRESP), State= #state{ping_reqs = PingReqs}) ->
    [begin erlang:demonitor(Mon), gen_fsm:reply(Caller, pong) end || {Caller, Mon} <- PingReqs],
    {ok, State#state{ping_reqs = []}}.

%%------------------------------------------------------------------------------
%% @private
%% @doc Dispatch Publish Message to subscribers.
%% @end
%%------------------------------------------------------------------------------
dispatch(Publish = {publish, Topic, _Payload}, #state{name = Name,
                                                      pubsub_map = PubSubMap, 
                                                      logger = Logger}) ->
    Matched =
    lists:foldl(
        fun(Filter, Acc) -> 
                case emqttc_topic:match(Topic, Filter) of 
                    true ->
                        [Sub ! Publish || Sub <- maps:get(Filter, PubSubMap)],
                        [Filter | Acc];
                    false ->
                        Acc 
                end
        end, [], maps:keys(PubSubMap)),
    if
        length(Matched) =:= 0 ->
            Logger:warning("[Client ~s] Dropped: ~p", [Name, Publish]);
        true ->
            ok
    end.


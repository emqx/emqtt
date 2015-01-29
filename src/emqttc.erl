%%------------------------------------------------------------------------------
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
-module(emqttc).

-author('feng@emqtt.io').
-author('hiroe.orz@gmail.com').

-behavior(gen_fsm).

-include("emqttc_packet.hrl").

-import(proplists, [get_value/2, get_value/3]).

%% start application.
-export([start/0]).

%start one mqtt client
-export([start_link/0, start_link/1, start_link/2]).

%api
-export([connect/2,
         subscribe/2, subscribe/3,
         unsubscribe/2,
         publish/3, publish/4, 
         ping/1,
         disconnect/1]).

%% gen_fsm callbacks
-export([init/1,
         handle_info/3, 
         handle_event/3, 
         handle_sync_event/4, 
         code_change/4, 
         terminate/3]).

% fsm state
-export([ready/2, ready/3,
         connecting/2, connecting/3,
         waiting_for_connack/2, waiting_for_connack/3,
         connected/2, connected/3,
         disconnected/2, disconnected/3]).

-type mqttc_opt()   :: {host, inet:ip_address() | binary() | string} 
                     | {port, inet:port_number()}
                     | {client_id, binary()}
                     | {clean_sess, boolean()}
                     | {keep_alive, non_neg_integer()}
                     | {proto_vsn, mqtt_vsn()}
                     | {username, binary()}
                     | {password, binary()}
                     | {will_topic, binary()}
                     | {will_msg, binary()}
                     | {will_qos, mqtt_qos()}
                     | {will_retain, boolean()}
                     | {logger, atom() | {atom(), atom()}}
                     | {auto_connect, boolean()} 
                     | {reconnector, emqttc_reconnector:reconnector() | false}.

-type mqtt_pubopt() :: {qos, mqtt_qos()} | {retain, boolean()}.


-record(state, {name                :: atom(),
                host = "localhost"  :: inet:ip_address() | string(), 
                port = 1883         :: inet:port_number(), 
                socket              :: inet:socket(), 
                parse_state         :: none | fun(),
                proto_state         :: emqttc_protocol:proto_state(),
                subscribers         :: map(),
                pending             :: list(),
                logger              :: gen_logger:logmod(),
                auto_connect = true :: boolean(),
                reconnector         :: false | emqttc_reconnector:reconnector()}).

%%--------------------------------------------------------------------
%% @doc Start emqttc application
%%--------------------------------------------------------------------
-spec start() -> ok.
start() ->
    application:start(emqttc).

%%--------------------------------------------------------------------
%% @doc Start emqttc client with default options.
%%--------------------------------------------------------------------
-spec start_link() -> {ok, Client :: pid()} | ignore | {error, any()}. 
start_link() ->
    start_link([]).

%%--------------------------------------------------------------------
%% @doc Start emqttc client with options.
%%--------------------------------------------------------------------
-spec start_link(MqttOpts) -> {ok, Client} | ignore | {error, any()} when 
      MqttOpts  :: [mqttc_opt()],
      Client    :: pid().
start_link(MqttOpts) when is_list(MqttOpts) ->
    gen_fsm:start_link(?MODULE, [undefined, MqttOpts], []).

%%--------------------------------------------------------------------
%% @doc Start emqttc client with name, options.
%%--------------------------------------------------------------------
-spec start_link(Name, MqttOpts) -> {ok, pid()} | ignore | {error, any()} when
      Name      :: atom(),
      MqttOpts  :: [mqttc_opt()].
start_link(Name, MqttOpts) when is_atom(Name), is_list(MqttOpts) ->
    gen_fsm:start_link({local, Name}, ?MODULE, [Name, MqttOpts], []).

%%--------------------------------------------------------------------
%% @doc Connect to broker.
%%--------------------------------------------------------------------
-spec connect(Client, MqttOpts) -> ok when
      Client    :: pid() | atom(),
      MqttOpts  :: [mqttc_opt()].
connect(Client, MqttOpts) ->
    gen_fsm:send_event(Client, {connect, MqttOpts}).

%%--------------------------------------------------------------------
%% @doc Publish message to broker with default qos.
%%--------------------------------------------------------------------
-spec publish(Client, Topic, Payload) -> ok | {ok, MsgId} when
      Client    :: pid() | atom(),
      Topic     :: binary(),
      Payload   :: binary(),
      MsgId     :: mqtt_packet_id().
publish(Client, Topic, Payload) when is_binary(Topic), is_binary(Payload) ->
    publish(Client, #mqtt_message{topic = Topic, payload = Payload}).

%%--------------------------------------------------------------------
%% @doc Publish message to broker with qos or opts.
%%--------------------------------------------------------------------
-spec publish(Client, Topic, Payload, PubOpts) -> ok | {ok, MsgId} when
      Client    :: pid() | atom(),
      Topic     :: binary(),
      Payload   :: binary(),
      PubOpts   :: mqtt_qos() | [mqtt_pubopt()],
      MsgId     :: mqtt_packet_id().
publish(Client, Topic, Payload, PubOpts) when is_binary(Topic), is_binary(Payload) ->
    publish(Client, #mqtt_message{qos = proplists:get_value(qos, PubOpts, ?QOS_0), 
                                  retain = proplists:get_value(retain, PubOpts, false), 
                                  topic = Topic, payload = Payload }).

-spec publish(Client, Message) -> ok | {ok, MsgId} when
      Client    :: pid() | atom(),
      Message   :: mqtt_message(),
      MsgId     :: mqtt_packet_id().
publish(Client, Msg = #mqtt_message{qos = ?QOS_0}) ->
    gen_fsm:send_event(Client, {publish, Msg});

publish(Client, Msg = #mqtt_message{qos = ?QOS_1}) ->
    gen_fsm:sync_send_event(Client, {publish, Msg});

publish(Client, Msg = #mqtt_message{qos = ?QOS_2}) ->
    gen_fsm:sync_send_event(Client, {publish, Msg}).

%%--------------------------------------------------------------------
%% @doc Subscribe topics or topic.
%%--------------------------------------------------------------------
-spec subscribe(Client, Topics) -> ok when
      Client    :: pid() | atom(),
      Topics    :: [{binary(), mqtt_qos()}] | {binary(), mqtt_qos()} | binary().
subscribe(Client, Topic) when is_binary(Topic) ->
    subscribe(Client, [{Topic, ?QOS_0}]);
subscribe(Client, {Topic, QoS}) when is_binary(Topic) ->
    subscribe(Client, [{Topic, QoS}]);
subscribe(Client, [{Topic, Qos} | _] = Topics) when is_binary(Topic), ?IS_QOS(Qos) ->
    gen_fsm:send_event(Client, {subscribe, self(), Topics}).

%%--------------------------------------------------------------------
%% @doc Subscribe topic with qos.
%%--------------------------------------------------------------------
-spec subscribe(Client, Topic, Qos) -> ok when
      Client    :: pid() | atom(),
      Topic     :: binary(),
      Qos       :: mqtt_qos().
subscribe(Client, Topic, Qos) when is_binary(Topic), ?IS_QOS(Qos) ->
    subscribe(Client, [{Topic, Qos}]).

%%--------------------------------------------------------------------
%% @doc Unsubscribe topics
%%--------------------------------------------------------------------
-spec unsubscribe(Client, Topics) -> ok when
      Client    :: pid() | atom(),
      Topics    :: [binary()] | binary().
unsubscribe(Client, Topic) when is_binary(Topic) ->
    unsubscribe(Client, [Topic]);
unsubscribe(Client, [Topic | _] = Topics) when is_binary(Topic) ->
    gen_fsm:send_event(Client, {unsubscribe, Topics}).

%%--------------------------------------------------------------------
%% @doc Send ping to broker.
%%--------------------------------------------------------------------
-spec ping(Client) -> pong when Client :: pid() | atom().
ping(Client) ->
    gen_fsm:sync_send_event(Client, ping).

%%--------------------------------------------------------------------
%% @doc Disconnect from broker.
%%--------------------------------------------------------------------
-spec disconnect(Client) -> ok when Client :: pid() | atom().
disconnect(Client) ->
    gen_fsm:send_event(Client, disconnect).

%%%===================================================================
%%% gen_fms callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a gen_fsm is started using gen_fsm:start/[3,4] or
%% gen_fsm:start_link/[3,4], this function is called by the new
%% process to initialize.
%%
%% @spec init(Args) -> {ok, StateName, State} |
%%                     {ok, StateName, State, Timeout} |
%%                     ignore |
%%                     {stop, StopReason}.
%%--------------------------------------------------------------------
init([undefined, MqttOpts]) ->
    init([pid_to_list(self()), MqttOpts]);

init([Name, MqttOpts]) ->

    Logger = gen_logger:new(get_value(logger, MqttOpts, {stdout, debug})),

    case get_value(client_id, MqttOpts) of
        undefined -> Logger:warning("ClientId is NULL!");
        _ -> ok
    end,

    ProtoState = emqttc_protocol:init([{logger, Logger} | MqttOpts]),
    
    State = parse_opts(#state{ name         = Name,
                               host         = "localhost",
                               port         = 1883,
                               proto_state  = ProtoState,
                               logger       = Logger,
                               auto_connect = true,
                               reconnector  = false }, MqttOpts),
    case State#state.auto_connect of
        true -> {ok, connecting, State, 0};
        false -> {ok, ready, State}
    end.

parse_opts(State, []) ->
    State;
parse_opts(State, [{host, Host} | Opts]) ->
    parse_opts(State#state{host = Host}, Opts);
parse_opts(State, [{port, Port} | Opts]) ->
    parse_opts(State#state{port = Port}, Opts);
parse_opts(State, [{logger, Cfg} | Opts]) ->
    parse_opts(State#state{logger = gen_logger:new(Cfg)}, Opts);
parse_opts(State, [{auto_connect, Auto} | Opts]) when is_boolean(Auto) ->
    parse_opts(State#state{auto_connect = Auto}, Opts);
parse_opts(State, [{reconnect, false} | Opts]) ->
    parse_opts(State#state{reconnector = false}, Opts);
parse_opts(State, [{reconnect, Interval} | Opts]) when is_integer(Interval) ->
    parse_opts(State#state{reconnector = emqttc_reconnector:new(Interval)}, Opts);
parse_opts(State, [{reconnect, {Interval, MaxRetries}} | Opts]) when is_integer(Interval) ->
    parse_opts(State#state{reconnector = emqttc_reconnector:new(Interval, MaxRetries)}, Opts);
parse_opts(State, [_Opt | Opts]) ->
    parse_opts(State, Opts).

%%--------------------------------------------------------------------
%% @private
%% @doc Message Handler for state that wait for connect request
%%--------------------------------------------------------------------
ready({connect, MqttOpts}, State) ->
    NewState = parse_opts(State, MqttOpts),
    connect(NewState);
ready(_Event, State) ->
    {next_state, ready, State}.
ready(_Event, _From, State) ->
    {reply, {error, not_connect}, ready, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc Message Handler for state that connecting to MQTT broker.
%%--------------------------------------------------------------------
connecting(timeout, State) ->
    connect(State);

connecting(Event, State = #state{name = Name, logger = Logger}) ->
    Logger:warning("[Client ~s] Unexpected event: ~p", [Name, Event]),
    {next_state, connecting, pending(Event, connecting, State)}.

%%--------------------------------------------------------------------
%% @private
%% @doc Sync message Handler for state that connecting to MQTT broker.
%%--------------------------------------------------------------------
connecting(_Event, _From, State) ->
    {reply, {error, connecting}, connecting, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc Message Handler for state that waiting_for_connack from MQTT broker.
%%--------------------------------------------------------------------
waiting_for_connack(Event, State) ->
    {next_state, waiting_for_connack, pending(Event, waiting_for_connack, State)}.

waiting_for_connack(Event, _From, State = #state{name = Name, logger = Logger }) ->
    Logger:warning("[Client ~s] Unexpected event: ~p", [Name, Event]),
    {next_state, waiting_for_connack, pending(Event, waiting_for_connack, State)}.

%%--------------------------------------------------------------------
%% @private
%% @doc Message Handler for state that connected to MQTT broker.
%%--------------------------------------------------------------------
connected({publish, Msg}, State=#state{proto_state = ProtoState}) ->
    emqttc_protocol:publish(Msg, ProtoState),
    {next_state, connected, State};

connected({subscribe, From, Topics}, State = #state{ subscribers = Subscribers,
                                                     proto_state = ProtoState }) ->
    emqttc_protocol:subscribe(Topics, ProtoState),
    %%TODO: Monitor subs.
    Subscribers1 =
    lists:foldl(
        fun(Topic, Acc) ->
            case maps:find(Topic, Acc) of
                {ok, Subs} ->
                    case lists:member(From, Subs) of
                        true -> Acc;
                        false -> maps:put(Topic, [From | Subs], Acc)
                    end;

                error ->
                    maps:put(Topic, [From], Acc)
            end
        end, Subscribers, Topics),
    {next_state, connected, State#state{ subscribers = Subscribers1 }};

connected({unsubscribe, From, Topics}, State=#state{ subscribers = Subscribers, 
                                                     proto_state = ProtoState, 
                                                     logger = Logger}) ->
    emqttc_protocol:unsubscribe(Topics, ProtoState),
    %%TODO: UNMONITOR
    Subscribers1 = 
    lists:foldl(fun(Topic, Acc) ->
                    case maps:find(Topic, Acc) of
                        {ok, Subs} ->
                            maps:put(Topic, lists:delete(From, Subs), Acc);
                        error ->
                            Logger:warning("Topic '~s' not exited", [Topic]),
                            Acc
                    end
                end, Subscribers, Topics),
    {next_state, connected, State#state{ subscribers= Subscribers1 }};

connected(disconnect, State=#state{socket = Socket, proto_state = ProtoState}) ->
    emqttc_protocol:disconnect(ProtoState),
    emqttc_socket:close(Socket),
    %%TODO: close socket?
    %%
    %%TODO: STOP normal
    {stop, normal, State#state{socket = undefined}};

connected(Event, State = #state{name = Name, logger = Logger}) -> 
    Logger:error("[Client ~p | CONNECTED] unexpected event: ~p", [Name, Event]),
    {next_state, connected, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc Sync Message Handler for state that connected to MQTT broker.
%%--------------------------------------------------------------------
connected({publish, Msg}, _From, State = #state{proto_state = ProtoState}) ->
    {ok, MsgId, ProtoState1} = emqttc_protocol:publish(Msg, ProtoState),
    {reply, {ok, MsgId}, connected, State#state{proto_state = ProtoState1}};

connected(ping, _From, State = #state{proto_state = ProtoState}) ->
    emqttc_protocol:ping(ProtoState),
    %%TODO: response to From
    {reply, pong, connected, State};

connected(Event, _From, State = #state { name = Name, logger = Logger }) ->
    Logger:error("[Clieng ~p] unexpected event: ~p", [Name, Event]),
    {reply, {error, unsupport}, connected, State}.

disconnected(Event, State = #state{logger = Logger}) ->
    Logger:error("bad event: ~p", [Event]),
    {next_state, disconnected, State}.

disconnected(Event, _From, State = #state{logger = Logger}) ->
    {reply, {error, disonnected}, disconnected, State}.
    
%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_fsm when it receives any
%% message other than a synchronous or asynchronous event
%% (or a system message).
%%
%% @spec handle_info(Info,StateName,State)->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState}
%%--------------------------------------------------------------------

%% connack message from broker(without remaining length).
handle_info({tcp, Socket, Data}, EventState, State = #state{name = Name, 
                                                            socket = Socket, 
                                                            logger = Logger}) ->

    Logger:debug("[~p ~s] RECV: ~p", [Name, EventState, Data]),
    process_received_bytes(Data, EventState, State);

handle_info({tcp, error, Reason}, _, State = #state{logger = Logger}) ->
    Logger:error("Tcp error: ~p", [Reason]),
    %TODO: Reconnect??
    {next_state, disconnected, State};

handle_info({tcp_closed, Socket}, _, State = #state{logger = Logger, socket = Socket}) ->
    %%TODO: Reconnect
    Logger:warning("tcp_closed state goto disconnected"),
    {next_state, disconnected, State#state{socket = undefined}};

handle_info({timeout, reconnect}, connecting, S) ->
    io:format("connect(handle_info)~n"),
    connect(S);

handle_info({dispatch, Msg}, connected, State = #state{logger = Logger}) ->
    Logger:info("Dispatch: ~p", [Msg]),
    {next_state, connected, State};

%%TODO: 
handle_info({redeliver, Pkg}, connected, State = #state{logger = Logger}) ->
    Logger:info("Redeliver: ~p", [Pkg]),
    {next_state, connected, State};
    
handle_info({session, expired}, StateName, State) ->
    stop({shutdown, {session, expired}}, State);

handle_info(_Info, StateName, State) ->
    {next_state, StateName, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a gen_fsm receives an event sent using
%% gen_fsm:send_all_state_event/2, this function is called to handle
%% the event.
%%
%% @spec handle_event(Event, StateName, State) ->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState}
%% @end
%%--------------------------------------------------------------------
handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a gen_fsm receives an event sent using
%% gen_fsm:sync_send_all_state_event/[2,3], this function is called
%% to handle the event.
%%
%% @spec handle_sync_event(Event, From, StateName, State) ->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {reply, Reply, NextStateName, NextState} |
%%                   {reply, Reply, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState} |
%%                   {stop, Reason, Reply, NewState}
%%--------------------------------------------------------------------
handle_sync_event(status, _From, StateName, State) ->
    Statistics = [{N, get(N)} || N <- [inserted]],
    {reply, {StateName, Statistics}, StateName, State};

handle_sync_event(stop, _From, _StateName, State) ->
    {stop, normal, ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_fsm when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_fsm terminates with
%% Reason. The return value is ignored.
%%
%% @spec terminate(Reason, StateName, State) -> void()
%%--------------------------------------------------------------------
terminate(Reason, _StateName, _State = #state{proto_state = ProtoState}) ->
    emqttc_protocol:shutdown(Reason, ProtoState),
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, StateName, State, Extra) ->
%%                   {ok, StateName, NewState}
%%--------------------------------------------------------------------
code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
connect(State = #state{name = Name, 
                       host = Host, port = Port, 
                       proto_state = ProtoState,
                       socket = undefined, 
                       logger = Logger,
                       reconnector = Reconnector}) ->
    Logger:info("[Client ~s]: connecting to ~p:~p", [Name, Host, Port]),
    case emqttc_socket:connect(Host, Port) of
        {ok, Socket} ->
            ProtoState1 = emqttc_protocol:set_socket(ProtoState, Socket),
            emqttc_protocol:connect(ProtoState1),
            Logger:info("[Client ~p] connected with ~p:~p", [Name, Host, Port]),
            {next_state, waiting_for_connack, State#state{socket = Socket,
                                                          parse_state = emqttc_parser:init(), 
                                                          proto_state = ProtoState1} };
        {error, Reason} ->
            Logger:info("[Client ~p] connection failure: ~p", [Name, Reason]),
            case Reconnector of
                false -> 
                    {stop, {error, Reason}, State};
                _ -> 
                    case emqttc_reconnector:execute(Reconnector, {timeout, reconnect}) of
                        {ok, Reconnector1} -> {next_state, disconnected, State#state{reconnector = Reconnector1}};
                        {stop, Error} -> {stop, {error, Error}, State}
                    end
            end
    end.

pending(Event = {subscribe, _From, _Topics}, _StateName, State = #state{pending = Pending}) ->
    State#state{pending = [Event | Pending]};

pending(Event = {publish, _Msg}, _StateName, State = #state{pending = Pending}) ->
    State#state{pending = [Event | Pending]};

pending(Event, StateName, State = #state{name = Name, logger = Logger}) ->
    Logger:warning("[Client ~s ~s] Unexpected event: ~p", [Name, StateName, Event]),
    State.

process_received_bytes(<<>>, EventState, State) ->
    {next_state, EventState, State};

process_received_bytes(Bytes, EventState,
                       State = #state{ name        = Name,
                                       parse_state = ParseState,
                                       proto_state = ProtoState,
                                       logger      = Logger }) ->
    case emqttc_parser:parse(Bytes, ParseState) of
    {more, ParseState1} ->
        %%TODO: socket controll...
        {next_state, EventState, State#state{parse_state = ParseState1}};
    {ok, Packet, Rest} ->
        case process_packet(Packet, EventState, State) of
            {next_state, EventState1, State1} -> %NewProtoState
                process_received_bytes(Rest, EventState1, 
                                       State1#state{parse_state = emqttc_parser:init()});
            {error, Error, NewState} ->
                stop({shutdown, Error}, NewState)
        end;
    {error, Error} ->
        Logger:error("[~p] MQTT detected framing error ~p", [Name, Error]),
        stop({shutdown, Error}, State)
    end.

%%TODO: PACKET_HEADER...
process_packet(Packet = #mqtt_packet { header = #mqtt_packet_header { type = Type }}, EventState, State) ->
    process_packet(Type, Packet, EventState, State).

%%A Client can only receive one CONNACK
process_packet(?CONNACK, #mqtt_packet {
        variable = #mqtt_packet_connack {
            return_code  = ReturnCode } }, waiting_for_connack,
    State = #state{name = Name, logger = Logger}) ->
    Logger:info("[~p] RECV CONNACK: ~p", [Name, ReturnCode]),
    if 
        ReturnCode =:= ?CONNACK_ACCEPT ->
            {next_state, connected, State};
        true ->
            {error, connack_error(ReturnCode), State}
    end;

process_packet(?CONNACK, _Packet, connected, State) ->
    {error, {protocol, unexpeced_connack}, State};

process_packet(?PINGRESP, _Packet, connected, State = #state{name = Name, logger = Logger}) ->
    Logger:info("[~p] RECV PINGRESP", [Name]),
    {next_state, connected, State};

process_packet(Type, Packet, connected, State = #state{name = Name, logger = Logger, proto_state = ProtoState}) ->
    Logger:info("[~p] RECV: ~p", [Name, Packet]),
    case emqttc_protocol:handle_packet(Type, Packet, ProtoState) of
        {ok, NewProtoState} ->
            {ok, NewProtoState};
        {error, Error} ->
            Logger:error("[~p] MQTT protocol error ~p", [Name, Error]),
            stop({shutdown, Error}, State);
        {error, Error, ProtoState1} ->
            stop({shutdown, Error}, State#state{proto_state = ProtoState1});
        {stop, Reason, ProtoState1} ->
            stop(Reason, State#state{proto_state = ProtoState1})
    end.

stop(Reason, State ) ->
    {stop, Reason, State}.

connack_error(?CONNACK_PROTO_VER) ->
    connack_proto_ver;
connack_error(?CONNACK_INVALID_ID ) ->
    connack_invalid_id;
connack_error(?CONNACK_SERVER) ->
    connack_server;
connack_error(?CONNACK_CREDENTIALS) ->
    connack_credentials;
connack_error(?CONNACK_AUTH) ->
    connack_auth.


%%------------------------------------------------------------------------------
%% Copyright (c) 2012-2015, eMQTT.IO
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

-include("emqtt_packet.hrl").

%% start application.
-export([start/0]).

%start one mqtt client
-export([ start_link/0, start_link/1, start_link/2]).

%api
-export([connect/1,
         publish/2, publish/3, publish/4, 
         subscribe/2, 
         unsubscribe/2, 
         ping/1, 
         disconnect/1, 
         add_event_handler/2, 
         add_event_handler/3, 
         set_socket/2]).

%% gen_fsm callbacks
-export([init/1, 
         handle_info/3, 
         handle_event/3, 
         handle_sync_event/4, 
         code_change/4, 
         terminate/3]).

% fsm state
-export([connecting/2, connecting/3, 
         waiting_for_connack/2, 
         connected/2, connected/3, disconnected/2, disconnected/3]).


%%----------------------------------------------------------------------------

-ifdef(use_specs).

-type mqttc_opts()  :: [ mqttc_opt() ].

-type mqttc_opt()   :: {host, inet:ip_address() | binary() | string} 
                     | {port, inet:port_number}
                     | {client_id, binary()}
                     | {clean_sess, boolean()}
                     | {keep_alive, non_neg_integer()}
                     | {proto_vsn, mqtt_vsn()},
                     | {username, binary()},
                     | {password, binary()},
                     | {will_topic, binary()}
                     | {will_msg, binary()},
                     | {will_qos, mqtt_qos()},
                     | {will_retain, boolean()}.

-type mqtt_pubopts() :: [ mqtt_pubopt() ].

-type mqtt_pubopt() :: {qos, mqtt_qos()} | {retain, boolean()}.

-spec start() -> ok.

-spec start_link() -> {ok, Client} | ignore | {error, any()} when
      Client    :: pid().

-spec start_link(MqttOpts) -> {ok, Client} | ignore | {error, any()} when 
      MqttOpts  :: mqttc_opts(),
      Client    :: pid().

-spec start_link(Name, MqttOpts) -> {ok, pid()} | ignore | {error, any()} when
      Name      :: atom(),
      MqttOpts  :: mqttc_opts().

-spec publish(Client, Topic, Payload) -> ok | {ok, MsgId} when
      Client    :: pid() | atom(),
      Topic     :: binary(),
      Payload   :: binary(),
      MsgId     :: mqtt_packet_id().

-spec publish(Client, Topic, Payload, PubOpts) -> ok | {ok, MsgId} when
      Client    :: pid() | atom(),
      Topic     :: binary(),
      Payload   :: binary(),
      PubOpts   :: mqtt_qos() | mqtt_pubopts(),
      MsgId     :: mqtt_packet_id().

-spec publish(Client, Message) -> ok | {ok, MsgId} when
      Client    :: pid() | atom(),
      Message   :: mqtt_message(),
      MsgId     :: mqtt_packet_id().

-spec subscribe(Client, Topics) -> ok when
      Client    :: pid() | atom(),
      Topics    :: [ {binary(), mqtt_qos()} ] | {binary(), mqtt_qos()}.

-spec subscribe(Client, Topic, Qos) -> ok when
      Client    :: pid() | atom(),
      Topic     :: binary(),
      Qos       :: mqtt_qos().

-spec unsubscribe(Client, Topics) -> ok when
      Client    :: pid() | atom(),
      Topics    :: [ binary() ] | binary().

-spec ping(Client) -> pong when Client :: pid() | atom().

-spec disconnect(Client) -> ok when Client :: pid() | atom().

-endif.

%%----------------------------------------------------------------------------

-record(state, { name       :: atom(),
                 host       :: inet:ip_address() | binary() | string(), 
                 port       :: inet:port_number(), 
                 socket     :: gen_tcp:socket(), 
                 %ref        :: dict:dict(),
                 %event_mgr_pid :: pid() 
                 logger     :: mod(),
                 auto_conn  :: boolean(),
                 reconn     :: non_neg_integer() }).

-define(RECONNECT_INTERVAL, 3000).

%%--------------------------------------------------------------------
%% @doc Start emqttc application
%%--------------------------------------------------------------------
start() ->
    application:start(emqttc).

%%--------------------------------------------------------------------
%% @doc Start emqttc client with default options.
%%--------------------------------------------------------------------
start_link() ->
    start_link([]).

%%--------------------------------------------------------------------
%% @doc Start emqttc client with options.
%%--------------------------------------------------------------------
start_link(MqttOpts) when is_list(MqttOpts) ->
    gen_fsm:start_link(?MODULE, [undefined, MqttOpts], []).

%%--------------------------------------------------------------------
%% @doc Start emqttc client with name, options.
%%--------------------------------------------------------------------
start_link(Name, MqttOpts) when is_atom(Name), is_list(MqttOpts) ->
    gen_fsm:start_link({local, Name}, ?MODULE, [Name, MqttOpts], []).

%%--------------------------------------------------------------------
%% @doc Publish message to broker with default qos.
%%--------------------------------------------------------------------
publish(Client, Topic, Payload) when is_binary(Topic), is_binary(Payload) ->
    publish(Client, #mqtt_message{from = self(), topic = Topic, payload = Payload}).

%%--------------------------------------------------------------------
%% @doc Publish message to broker with qos or opts.
%%--------------------------------------------------------------------
publish(Client, Topic, Payload, QoS) when is_binary(Topic), is_binary(Payload), is_integer(QoS) ->
    publish(Client, Topic, Payload, [{qos, Qos}]);

publish(Client, Topic, Payload, PubOpts) when is_binary(Topic), is_binary(Payload) ->
    publish(Client, #mqtt_message{from = self(),
                                  qos = proplists:get_value(qos, PubOpts, ?QOS_0), 
                                  retain = proplists:get_value(retain, PubOpts, false), 
                                  topic = Topic, payload = Payload }).

publish(Client, Msg = #mqtt_message{qos = ?QOS_0}) ->
    gen_fsm:send_event(Client, {publish, Msg});

publish(Client, Msg = #mqtt_message{qos = ?QOS_1}) ->
    gen_fsm:sync_send_event(Client, {publish, Msg});

publish(Client, Msg = #mqtt_message{qos = ?QOS_2}) ->
    gen_fsm:sync_send_event(Client, {publish, Msg}).


%%--------------------------------------------------------------------
%% @doc Subscribe topics or topic with qos0.
%%--------------------------------------------------------------------
subscribe(Client, Topic) when is_binary(Topic) ->
    subscribe(Client, [{Topic, ?QOS_0}]);

subscribe(Client, [{Topic, Qos} | _] = Topics) when is_binary(Topic), ?IS_QOS(Qos) ->
    gen_fsm:send_event(Client, {subscribe, self(), Topics}).

%%--------------------------------------------------------------------
%% @doc Subscribe topic with qos.
%%--------------------------------------------------------------------
subscribe(Client, Topic, Qos) when is_binary(Topic), ?IS_QOS(Qos) ->
    subscribe(Client, [{Topic, Qos}]).

%%--------------------------------------------------------------------
%% @doc Unsubscribe topics
%%--------------------------------------------------------------------
unsubscribe(Client, [Topic | _] = Topics) when is_binary(Topic) ->
    gen_fsm:send_event(Client, {unsubscribe, Topics}).

%%--------------------------------------------------------------------
%% @doc Send ping to broker.
%%--------------------------------------------------------------------
ping(Client) ->
    gen_fsm:sync_send_event(Client, ping).

%%--------------------------------------------------------------------
%% @doc Disconnect from broker.
%%--------------------------------------------------------------------
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
%%                     {stop, StopReason}
%%--------------------------------------------------------------------
init([undefined, MqttOpts]) ->
    init([self(), MqttOpts, []]);

init([Name, MqttOpts, ClientOpts]) ->

    Logger = gen_logger:new(proplists:get_value(logger, ClientOpts, {otp, info})),

    case proplists:get_value(client_id, MqttOpts) of
        undefined -> Logger:warning("ClientId is NULL!, are you sure to use empty clientID defined in MQTT V3.1.1?");
        _ -> ok
    end,

    ProtoState = emqttc_protocol:parse_opts(
                   emqttc_protocol:initial_state(), MqttOpts),
    
    State = parse_opts(#state{ name         = Name,
                               host         = "localhost",
                               port         = 1883,
                               keep_alive   = 60,
                               proto_state  = ProtoState,
                               logger       = Logger,
                               auto_conn    = true,
                               reconn       = 5 }, MqttOpts),
    
    %TODO:  {ok, Pid} = emqttc_event:start_link(),
    
    {ok, connecting, parse_opts(State, ClientOpts), 0}.

parse_opts(State, []) ->
    State;
parse_opts(State, [{host, Host} | Opts]) ->
    State#state{host = Host};
parse_opts(State, [{port, Port} | Opts]) ->
    State#state{port = Port};
parse_opts(State, [{logger, Cfg} | Opts]) ->
    State#state{logger = gen_logger:new(Cfg)};
parse_opts(State, [{auto_conn, Auto} | Opts]) when is_boolean(Auto) ->
    State#state{ auto_conn = Auto };
parse_opts(State, [{reconn, Interval} | Opts]) when is_integer(Time) ->
    State#state{ reconn = Interval };
parse_opts(State, [_Opt | Opts]) ->
    parse_opts(State, Opts).

%%--------------------------------------------------------------------
%% @private
%% @doc Message Handler for state that connecting to MQTT broker.
%%--------------------------------------------------------------------
connecting(timeout, State) ->
    connect(State);

connecting(Event, State = #state{logger = Logger}) ->
    Logger:warning("[CONNECTING] Unexpected event: ~p", [Event]),
    {next_state, connecting, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc Sync message Handler for state that connecting to MQTT broker.
%%--------------------------------------------------------------------
connecting(_Event, _From, State) ->
    {reply, {error, connecting}, connecting, State}.

connect(State = #state{name = Name, 
                       host = Host, port = Port, 
                       proto_state = ProtoState,
                       socket = undefined, 
                       logger = Logger }) ->

    Logger:info("[Client ~p]: connecting to ~p:~p", [Name, Host, Port]),
    case emqttc_socket:connect(Host, Port) of
        {ok, Socket} ->
            ProtoState1 = emqtt_protocol:set_socket(Socket),
            emqtt_protocol:connect(ProtoState1),
            Logger:info("[Client ~p]: connected with ~p:~p", [Name, Host, Port]),
            {next_state, waiting_for_connack, State#{socket = Socket, 
                                                     proto_state = ProtoState1}};
        {error, Reason} ->
            Logger:info("[Client ~p] connection failure: ~p", [Name, Reason]),
            schedule(reconnect, State),
            {next_state, disconnected, State} 
    end.
%%--------------------------------------------------------------------
%% @private
%% @doc Message Handler for state that waiting_for_connack from MQTT broker.
%%--------------------------------------------------------------------
waiting_for_connack({subscribe, From, NewTopics}, State=#state{topics = Topics} ) ->
    NewState = State#state{topics = Topics ++ NewTopics},
    {next_state, waiting_for_connack, NewState};    

waiting_for_connack(Event, State = #state{ name = Name, logger = Logger }) ->
    Logger:warning("[Client ~p waiting_for_connack] unexpected event: ~p", [Event]),
    {next_state, waiting_for_connack, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc Message Handler for state that connected to MQTT broker.
%%--------------------------------------------------------------------
connected({publish, Msg}, State=#state{proto_state = ProtoState}) ->
    emqttc_protocol:publish(ProtoState, Msg),
    {next_state, connected, State};

connected({subscribe, From, Topics}, State = #state{ subscribers = Subscribers,
                                                     proto_state = ProtoState }) ->
    emqttc_protocol:subscribe(ProtoState, Topics),
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
    {next_state, connected, State#state{ subscribe = Subscribers1 }};

connected({unsubscribe, From, Topics}, State=#state{ subscribers = Subscribers, 
                                                     proto_state = ProtoState, 
                                                     logger = Logger}) ->
    emqttc_protocol:unsubscribe(ProtoState, Topics),
    %%TODO: UNMONITOR
    Subscribers1 = 
    lists:foldl(fun(Topic, Acc) ->
                    case maps:find(Topic, Acc) of
                        {ok, Subs} ->
                            maps:put(Topic, lists:delete(From, Subs));
                        error ->
                            Logger:warning("Topic '~s' not exited", [Topic]),
                            Acc
                    end
                end, Subscribers, Topics),
    {next_state, connected, State#state{ subscribe = Subscribers1 }};

connected(disconnect, State=#state{proto_state = ProtoState}) ->
    emqttc_protocol:disconnect(ProtoState),
    %%TODO: close socket?
    %%
    {next_state, connected, State#state{socket = undefined}};

connected(Event, State = #state{name = Name, logger = Logger}) -> 
    Logger:warning("[Client ~p | CONNECTED] unexpected event: ~p", [Name, Event]),
    {next_state, connected, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc Sync Message Handler for state that connected to MQTT broker.
%%--------------------------------------------------------------------
connected({publish, Msg}, From, State = #state{proto_state = ProtoState}) ->
    {ok, MsgId, ProtoState} = emqttc_protocol:publish(ProtoState, Msg),
    %%TODO: right?
    {reply, {ok, MsgId}, connected, State};

connected(ping, From, State = #state{proto_state = ProtoState}) ->
    emqttc_protocol:ping(ProtoState),
    %%TODO: response to From
    {next_state, connected, State};

connected(Event, _From, State = #state { name = Name, logger = Logger }) ->
    Logger:warning("[Clieng ~p] unexpected event: ~p", [Name, Event]),
    {reply, {error, unsupport}, connected, State}.

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
handle_info({tcp, _Sock, <<?CONNACK:4/integer, _:4/integer,
			 _:8/integer, ReturnCode:8/unsigned-integer>>},
	    waiting_for_connack, State) ->
    case ReturnCode of
	?CONNACK_ACCEPT ->
	    io:format("-------connack: Connection Accepted~n"),
	    ok = gen_fsm:send_event(self(), {subscribe, []}),
	    {next_state, connected, State};
	?CONNACK_PROTO_VER ->
	    io:format("-------connack: NG(unacceptable protocol version)~n"),
	    {next_state, waiting_for_connack, State};
	?CONNACK_INVALID_ID ->
	    io:format("-------connack: NG(identifier rejected)~n"),
	    {next_state, waiting_for_connack, State};
	?CONNACK_SERVER ->
	    io:format("-------connack: NG(server unavailable)~n"),
	    {next_state, waiting_for_connack, State};
	?CONNACK_CREDENTIALS ->
	    io:format("-------connack: NG(bad user name or password)~n"),
	    {next_state, waiting_for_connack, State};
	?CONNACK_AUTH ->
	    io:format("-------connack: NG(not authorized)~n"),
	    {next_state, waiting_for_connack, State}
    end;

%% suback message from broker.
handle_info({tcp, _Sock, <<?SUBACK:4/integer, _:4/integer, _/binary>>},
	    connected, State) ->
    {next_state, connected, State};

%% pub message from broker(QoS = 0)(without remaining length).
handle_info({tcp, _Sock, <<?PUBLISH:4/integer,
			   _:1/integer, ?QOS_0:2/integer, _:1/integer,
			   TopicSize:16/big-unsigned-integer,
			   Topic:TopicSize/binary,
			   Payload/binary>>},
	    connected, State = #state{event_mgr_pid = EventPid}) ->
    gen_event:notify(EventPid, {publish, Topic, Payload}),
    {next_state, connected, State};

%% pub message from broker(QoS = 1 or 2)(without remaining length).
handle_info({tcp, _Sock, <<?PUBLISH:4/integer,
			   _:1/integer, Qos:2/integer, _:1/integer,
			   TopicSize:16/big-unsigned-integer,
			   Topic:TopicSize/binary,
			   MsgId:16/big-unsigned-integer,
			   Payload/binary>>},
	    connected, State = #state{event_mgr_pid = EventPid}) 
  when Qos =:= ?QOS_1; Qos =:= ?QOS_2 ->

    gen_event:notify(EventPid, {publish, Topic, Payload, Qos, MsgId}),
    {next_state, connected, State};

%% pubrec message from broker(without remaining length).
handle_info({tcp, _Sock, <<?PUBACK:4/integer,
			   _:1/integer, _:2/integer, _:1/integer,
			   MsgId:16/big-unsigned-integer>>},
	    connected, State=#state{ref=Ref}) ->
    Ref2 = reply({ok, MsgId}, publish, Ref),
    {next_state, connected, State#state{ref=Ref2}};

%% pubrec message from broker(without remaining length).
handle_info({tcp, _Sock, <<?PUBREC:4/integer,
			   _:1/integer, _:2/integer, _:1/integer,
			   MsgId:16/big-unsigned-integer>>},
	    connected, State=#state{ref=Ref}) ->
    Ref2 = reply({ok, MsgId}, publish, Ref),
    {next_state, connected, State#state{ref=Ref2}};

%% pubcomp message from broker(without remaining length).
handle_info({tcp, _Sock, <<?PUBCOMP:4/integer,
			   _:1/integer, _:2/integer, _:1/integer,
			   MsgId:16/big-unsigned-integer>>},
	    connected, State=#state{ref=Ref}) ->
    Ref2 = reply({ok, MsgId}, pubrel, Ref),
    {next_state, connected, State#state{ref=Ref2}};

%% pingresp message from broker(without remaining length).
handle_info({tcp, _Sock, <<?PINGRESP:4/integer,
			   _:1/integer, _:2/integer, _:1/integer>>},
	    connected, State=#state{ref = Ref}) ->
    Ref2 = reply(ok, ping, Ref),
    {next_state, connected, State#state{ref = Ref2}};

handle_info({tcp, error, Reason}, _, State) ->
    io:format("tcp error: ~p.~n", [Reason]),
    {next_state, disconnected, State};

handle_info({tcp, _Sock, Data}, connected, State) when is_binary(Data) ->
    <<_Code:4/integer, _:4/integer, _/binary>> = Data,
    {next_state, connected, State};

handle_info({tcp_closed, _Sock}, _, State) ->
    io:format("tcp_closed state goto disconnected.~n"),
    {next_state, disconnected, State};

handle_info({timeout, reconnect}, connecting, S) ->
    io:format("connect(handle_info)~n"),
    connect(S);

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
%% @end
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
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _StateName, #state{sock_pid = undefined}) ->
    ok;

terminate(_Reason, _StateName, _State = #state{sock_pid = Pid}) ->
    emqttc_sock_sup:stop_sock(Pid),    
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, StateName, State, Extra) ->
%%                   {ok, StateName, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

send_puback(Sock, Type, MsgId) ->
    Frame = #mqtt_frame{
	       fixed = #mqtt_frame_fixed{type = Type},
	       variable = #mqtt_frame_publish{message_id = MsgId}},
    send_frame(Sock, Frame).

send_disconnect(Sock) ->
    Frame = #mqtt_frame{
	       fixed = #mqtt_frame_fixed{type = ?DISCONNECT,
					 qos = 0,
					 retain = false,
					 dup = 0}},
    send_frame(Sock, Frame).

send_ping(Sock) ->
    Frame = #mqtt_frame{
	       fixed = #mqtt_frame_fixed{type = ?PINGREQ,
					 qos = 1,
					 retain = false,
					 dup = 0}},
    send_frame(Sock, Frame).

-spec send_frame(gen_tcp:socket(), #mqtt_frame{}) -> ok | {error, term()}.
send_frame(Sock, Frame) ->
    case gen_tcp:send(Sock, emqtt_frame:serialise(Frame)) of
	ok -> ok;
	{error, Reason} ->
	    io:format("socket error when send frame: ~p~n", [Reason]),
	    {error, Reason}
    end.

reply(Reply, Name, Ref) ->
    case dict:find(Name, Ref) of
	{ok, []} ->
	    Ref;
	{ok, [From | FromTail]} ->
	    gen_fsm:reply(From, Reply),
	    dict:store(Name, FromTail, Ref)
    end.


send_connect(#state{sock=Sock, username=Username, password=Password,
		    client_id=ClientId, clean_session = CleanSession,
		    keep_alive=KeepAlive}) ->
    Frame = 
	#mqtt_frame{
	   fixed = #mqtt_frame_fixed{
		      type = ?CONNECT,
		      dup = 0,
		      qos = 1,
		      retain = false},
	   variable = #mqtt_frame_connect{
			 username   = Username,
			 password   = Password,
			 proto_ver  = ?MQTT_PROTO_MAJOR,
			 clean_sess = CleanSession,
			 keep_alive = KeepAlive,
			 client_id  = ClientId}},
    send_frame(Sock, Frame).

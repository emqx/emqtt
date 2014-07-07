-module(emqttc).
-behavior(gen_fsm).

-include("emqtt_frame.hrl").

%% start application.
-export([start/0]).

%startup
-export([start_link/0,
	 start_link/1,
	 start_link/2]).

%api
-export([publish/2, publish/3, publish/4,
	 pubrel/2,
	 puback/2,
	 pubrec/2,
	 pubcomp/2,
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
-export([connecting/2,
	 connecting/3,
	 waiting_for_connack/2,
	 connected/2,
	 connected/3,
	 disconnected/2, disconnected/3]).

-define(TCPOPTIONS, [binary,
		     {packet,    raw},
		     {reuseaddr, true},
		     {nodelay,   true},
		     {active, 	false},
		     {reuseaddr, true},
		     {send_timeout,  3000}]).

-define(TIMEOUT, 3000).

-record(state, {name          :: atom(),
		host          :: inet:ip_address() | binary() | string(),
		port          :: inet:port_number(),
		sock          :: gen_tcp:socket(),
		sock_pid      :: supervisor:child(),
		sock_ref      :: reference(),
		msgid = 0     :: non_neg_integer(),
		username      :: binary(),
		password      :: binary(),
		ref           :: dict:dict(),
		client_id     :: binary(),
		clean_session :: boolean(),
		keep_alive    :: non_neg_integer(),
		topics        :: [ {binary(), non_neg_integer()} ],
		event_mgr_pid :: pid() }).

%%--------------------------------------------------------------------
%% @doc start application
%% @end
%%--------------------------------------------------------------------
-spec start() -> ok.
start() ->
    application:start(emqttc).

%%--------------------------------------------------------------------
%% @doc
%% Creates a gen_fsm process which calls Module:init/1 to
%% initialize. To ensure a synchronized start-up procedure, this
%% function does not return until Module:init/1 has returned.
%% @end
%%--------------------------------------------------------------------
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    start_link([]).

%%--------------------------------------------------------------------
%% @doc Starts the server with options.
%% @end
%%--------------------------------------------------------------------
-spec start_link([tuple()]) -> {ok, pid()} | ignore | {error, term()}.
start_link(Opts) when is_list(Opts) ->
    gen_fsm:start_link(?MODULE, [undefined, Opts], []).

%%--------------------------------------------------------------------
%% @doc Starts the server with name and options.
%% @end
%%--------------------------------------------------------------------
-spec start_link(atom(), [tuple()]) -> {ok, pid()} | ignore | {error, term()}.
start_link(Name, Opts) when is_atom(Name), is_list(Opts) ->
    gen_fsm:start_link({local, Name}, ?MODULE, [Name, Opts], []).

%%--------------------------------------------------------------------
%% @doc Publish message to broker.
%% @end
%%--------------------------------------------------------------------
-spec publish(C, Topic, Payload) -> ok | {ok, MsgId} when
      C :: pid() | atom(),
      Topic :: binary(),
      Payload :: binary(),
      MsgId :: non_neg_integer().
publish(C, Topic, Payload) when is_binary(Topic), is_binary(Payload) ->
    publish(C, #mqtt_msg{topic = Topic, payload = Payload}).

-spec publish(C, Topic, Payload, Opts) -> ok | {ok, MsgId} when
      C :: pid() | atom(),
      Topic :: binary(),
      Payload :: binary(),
      Opts :: [tuple()],
      MsgId :: non_neg_integer().
publish(C, Topic, Payload, Opts) when is_binary(Topic), is_binary(Payload),
				      is_list(Opts) ->
    Qos = proplists:get_value(qos, Opts, 0),
    Retain = proplists:get_value(retain, Opts, false),
    publish(C, #mqtt_msg{topic = Topic, payload = Payload,
			 qos = Qos, retain = Retain}).

-spec publish(C, #mqtt_msg{}) -> ok | pubrec when
      C :: pid() | atom().			       
publish(C, Msg = #mqtt_msg{qos = ?QOS_0}) ->
    gen_fsm:send_event(C, {publish, Msg});

publish(C, Msg = #mqtt_msg{qos = ?QOS_1}) ->
    gen_fsm:sync_send_event(C, {publish, Msg});

publish(C, Msg = #mqtt_msg{qos = ?QOS_2}) ->
    gen_fsm:sync_send_event(C, {publish, Msg}).

-spec set_socket(C, Sock) -> ok when
      C :: pid() | atom(),
      Sock :: gen_tcp:socket().
set_socket(C, Sock) ->
    gen_fsm:send_event(C, {set_socket, Sock}).

%%--------------------------------------------------------------------
%% @doc pubrec.
%% @end
%%--------------------------------------------------------------------
-spec pubrel(C, MsgId) -> ok when
      C :: pid() | atom(),
      MsgId :: non_neg_integer().
pubrel(C, MsgId) when is_integer(MsgId) ->
    gen_fsm:sync_send_event(C, {pubrel, MsgId}).

%%--------------------------------------------------------------------
%% @doc puback.
%% @end
%%--------------------------------------------------------------------
-spec puback(C, MsgId) -> ok when
      C :: pid() | atom(),
      MsgId :: non_neg_integer().      
puback(C, MsgId) when is_integer(MsgId) ->
    gen_fsm:send_event(C, {puback, MsgId}).

%%--------------------------------------------------------------------
%% @doc pubrec.
%% @end
%%--------------------------------------------------------------------
-spec pubrec(C, MsgId) -> ok when
      C :: pid() | atom(),
      MsgId :: non_neg_integer().
pubrec(C, MsgId) when is_integer(MsgId) ->
    gen_fsm:send_event(C, {pubrec, MsgId}).

%%--------------------------------------------------------------------
%% @doc pubcomp.
%% @end
%%--------------------------------------------------------------------
-spec pubcomp(C, MsgId) -> ok when
      C :: pid() | atom(),
      MsgId :: non_neg_integer().
pubcomp(C, MsgId) when is_integer(MsgId) ->
    gen_fsm:send_event(C, {pubcomp, MsgId}).

%%--------------------------------------------------------------------
%% @doc subscribe request to broker.
%% @end
%%--------------------------------------------------------------------
-spec subscribe(C, Topics) -> ok when
      C :: pid() | atom(),
      Topics :: [ {binary(), non_neg_integer()} ].
subscribe(C, [{Topic, Qos} | _] = Topics) when 
      is_binary(Topic),
      is_integer(Qos) ->
    gen_fsm:send_event(C, {subscribe, Topics}).

%%--------------------------------------------------------------------
%% @doc unsubscribe request to broker.
%% @end
%%--------------------------------------------------------------------
-spec unsubscribe(C, Topics) -> ok when
      C :: pid() | atom(),
      Topics :: [ {binary(), non_neg_integer()} ].
unsubscribe(C, [{Topic, Qos} | _] = Topics) when 
      is_binary(Topic),
      is_integer(Qos) ->
    gen_fsm:send_event(C, {unsubscribe, Topics}).

%%--------------------------------------------------------------------
%% @doc Send ping to broker.
%% @end
%%--------------------------------------------------------------------
-spec ping(C) -> pong when
      C :: pid() | atom().
ping(C) ->
    gen_fsm:sync_send_event(C, ping).

%%--------------------------------------------------------------------
%% @doc Disconnect from broker.
%% @end
%%--------------------------------------------------------------------
-spec disconnect(C) -> ok when
      C :: pid() | atom().
disconnect(C) ->
    gen_fsm:send_event(C, disconnect).

%%--------------------------------------------------------------------
%% @doc Add subscribe event handler.
%% @end
%%--------------------------------------------------------------------
-spec add_event_handler(C, Handler) -> ok when
      C :: pid | atom(),
      Handler :: atom().
add_event_handler(C, Handler) ->
    add_event_handler(C, Handler, []).

-spec add_event_handler(C, Handler, Args) -> ok when
      C :: pid | atom(),
      Handler :: atom(),
      Args :: [term()].
add_event_handler(C, Handler, Args) ->
    gen_fsm:send_event(C, {add_event_handler, Handler, Args}).

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
%% @end
%%--------------------------------------------------------------------
init([undefined, Args]) ->
    init([self(), Args]);

init([Name, Args]) ->
    true = proplists:is_defined(client_id, Args),
    ClientId = proplists:get_value(client_id, Args),

    Host = proplists:get_value(host, Args, "localhost"),
    Port = proplists:get_value(port, Args, 1883),
    Username = proplists:get_value(username, Args, undefined),
    Password = proplists:get_value(password, Args, undefined),
    CleanSession = proplists:get_value(clean_session, Args, true),
    KeepAlive = proplists:get_value(keep_alive, Args, 0),
    Topics = proplists:get_value(topics, Args, []),

    {ok, Pid} = emqttc_event:start_link(),
    State = #state{host = Host, port = Port, ref = dict:new(),
		   client_id = ClientId,
		   name = Name,
		   username = Username, password = Password,
		   clean_session = CleanSession,
		   keep_alive = KeepAlive,
		   topics = Topics,
		   event_mgr_pid = Pid},

    {ok, connecting, State, 0}.

%%--------------------------------------------------------------------
%% @private
%% @doc Message Handler for state that disconnecting from MQTT broker.
%% @end
%%--------------------------------------------------------------------
disconnected(timeout, State) ->
    timer:sleep(5000),
    {next_state, connecting, State, 0};

disconnected({set_socket, Sock}, State) ->
    NewState = State#state{sock = Sock},
    case send_connect(NewState) of
	ok ->
	    {next_state, waiting_for_connack, NewState};
	{error, _Reason} ->
	    {next_state, disconnected, State}
    end;

disconnected({subscribe, NewTopics}, State=#state{topics = Topics} ) ->
    {next_state, disconnected, State#state{topics = Topics ++ NewTopics}};    

disconnected({add_event_handler, Handler, Args}, 
	     State = #state{event_mgr_pid = EventPid}) ->
    ok = emqttc_event:add_handler(EventPid, Handler, Args),
    {next_state, connecting, State};    

disconnected(_, State) ->
    {next_state, disconnected, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc Sync message handler for state that disconnecting from MQTT broker.
%% @end
%%--------------------------------------------------------------------
disconnected(_, _From, State) ->
    {next_state, disconnected, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc Message Handler for state that connecting to MQTT broker.
%% @end
%%--------------------------------------------------------------------
connecting(timeout, State) ->
    connect(State);

connecting({set_socket, Sock}, State) ->
    NewState = State#state{sock = Sock},
    case send_connect(NewState) of
	ok ->
	    {next_state, waiting_for_connack, NewState};
	{error, _Reason} ->
	    {next_state, disconnected, State}
    end;

connecting({subscribe, NewTopics}, State=#state{topics = Topics}) ->
    {next_state, connecting, State#state{topics = Topics ++ NewTopics}};    

connecting({add_event_handler, Handler, Args}, 
	   State = #state{event_mgr_pid = EventPid}) ->
    ok = emqttc_event:add_handler(EventPid, Handler, Args),
    {next_state, connecting, State};    

connecting(_Event, State) ->
    {next_state, connecting, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc Sync message Handler for state that connecting to MQTT broker.
%% @end
%%--------------------------------------------------------------------
connecting(_Event, _From, State) ->
    {reply, {error, connecting}, connecting, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc Message Handler for state that waiting_for_connack from MQTT broker.
%% @end
%%--------------------------------------------------------------------
waiting_for_connack({set_socket, Sock}, State) ->
    {next_state, waiting_for_connack, State#state{sock = Sock}};

waiting_for_connack({subscribe, NewTopics}, State=#state{topics = Topics} ) ->
    NewState = State#state{topics = Topics ++ NewTopics},
    {next_state, waiting_for_connack, NewState};    

waiting_for_connack({add_event_handler, Handler, Args},
		    State = #state{event_mgr_pid = EventPid}) ->
    ok = emqttc_event:add_handler(EventPid, Handler, Args),
    {next_state, connecting, State};    

waiting_for_connack(_Event, State) ->
    %FIXME:
    {next_state, waiting_for_connack, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc Message Handler for state that connected to MQTT broker.
%% @end
%%--------------------------------------------------------------------
connected({set_socket, Sock}, State) ->
    {next_state, connected, State#state{sock = Sock}};

connected({publish, Msg}, State=#state{sock = Sock, msgid = MsgId}) ->
    #mqtt_msg{retain     = Retain,
	      qos        = Qos,
	      topic      = Topic,
	      dup        = Dup,
	      payload    = Payload} = Msg,
    Frame = #mqtt_frame{
	       fixed = #mqtt_frame_fixed{type 	 = ?PUBLISH,
					 qos    = Qos,
					 retain = Retain,
					 dup    = Dup},
	       variable = #mqtt_frame_publish{topic_name = Topic,
					      message_id = if Qos == ?QOS_0 ->
								   undefined;
							      true ->
								   MsgId
							   end},
	       payload = Payload},

    case send_frame(Sock, Frame) of
	ok -> 
	    {next_state, connected, State#state{msgid=MsgId+1}};
	{error, _Reason} ->
	    {next_state, disconnected, State#state{sock = undefined}}
    end;

    %ok = send_frame(Sock, Frame),
    %{next_state, connected, State#state{msgid=MsgId+1}};

connected({puback, MsgId}, State=#state{sock=Sock}) ->
    send_puback(Sock, ?PUBACK, MsgId),
    {next_state, connected, State};

connected({pubrec, MsgId}, State=#state{sock=Sock}) ->
    send_puback(Sock, ?PUBREC, MsgId),
    {next_state, connected, State};

connected({pubcomp, MsgId}, State=#state{sock=Sock}) ->
    send_puback(Sock, ?PUBCOMP, MsgId),
    {next_state, connected, State};

connected({subscribe, Topics}, State=#state{topics = QueuedTopics, 
					    msgid = MsgId,sock = Sock}) ->
    TotalTopics = lists:usort(QueuedTopics ++ Topics),
    Topics1 = [#mqtt_topic{name=Topic, qos=Qos} || {Topic, Qos} <- TotalTopics],
    Frame = #mqtt_frame{
	       fixed = #mqtt_frame_fixed{type = ?SUBSCRIBE,
					 dup = 0,
					 qos = 0,
					 retain = false},
	       variable = #mqtt_frame_subscribe{message_id  = MsgId,
						topic_table = Topics1}},
    case send_frame(Sock, Frame) of
	ok -> 
	    {next_state, connected, State#state{msgid=MsgId+1}};
	{error, _Reason} ->
	    {next_state, disconnected, State#state{sock = undefined}}
    end;

connected({unsubscribe, Topics}, State=#state{sock = Sock, msgid = MsgId}) ->
    Topics1 = [#mqtt_topic{name=Topic, qos=Qos} || {Topic, Qos} <- Topics],
    Frame = #mqtt_frame{
	       fixed = #mqtt_frame_fixed{type = ?UNSUBSCRIBE,
					 dup = 0,
					 qos = 0,
					 retain = false},
	       variable = #mqtt_frame_subscribe{message_id  = MsgId,
						topic_table = Topics1}},
    case send_frame(Sock, Frame) of
	ok -> 
	    {next_state, connected, State#state{msgid=MsgId+1}};
	{error, _Reason} ->
	    {next_state, disconnected, State#state{sock = undefined}}
    end;

connected(disconnect, State=#state{sock=Sock}) ->
    case send_disconnect(Sock) of
	ok ->
	    {next_state, connected, State};
	{error, _Reason} ->
	    {next_state, disconnected, State#state{sock = undefined}}
    end;	    

connected({add_event_handler, Handler, Args},
	  State = #state{event_mgr_pid = EventPid}) ->
    ok = emqttc_event:add_handler(EventPid, Handler, Args),
    {next_state, connecting, State};    

connected(_Event, State) -> 
    {next_state, connected, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc Sync Message Handler for state that connected to MQTT broker.
%% @end
%%--------------------------------------------------------------------
connected({publish, Msg}, From, 
	  State=#state{sock=Sock, msgid=MsgId, ref=Ref}) ->
    #mqtt_msg{retain     = Retain,
	      qos        = Qos,
	      topic      = Topic,
	      dup        = Dup,
	      payload    = Payload} = Msg,
    Frame = #mqtt_frame{
	       fixed = #mqtt_frame_fixed{type 	 = ?PUBLISH,
					 qos    = Qos,
					 retain = Retain,
					 dup    = Dup},
	       variable = #mqtt_frame_publish{topic_name = Topic,
					      message_id = if Qos == ?QOS_0 ->
								   undefined;
							      true ->
								   MsgId
							   end},
	       payload = Payload},

    Ref2 = dict:append(publish, From, Ref),
    case send_frame(Sock, Frame) of
	ok -> 
	    {next_state, connected, State#state{msgid=MsgId+1, ref=Ref2}};
	{error, _Reason} ->
	    {next_state, disconnected, State#state{sock = undefined}}
    end;

connected({pubrel, MsgId}, From, State=#state{sock=Sock, ref=Ref}) ->
    case send_puback(Sock, ?PUBREL, MsgId) of
	ok ->
	    Ref2 = dict:append(pubrel, From, Ref),
	    {next_state, connected, State#state{ref=Ref2}};
	{error, _Reason} ->
	    {next_state, disconnected, State#state{sock = undefined}}
    end;	    

connected(ping, From, State=#state{sock=Sock, ref = Ref}) ->
    case send_ping(Sock) of
	ok ->
	    Ref2 = dict:append(ping, From, Ref),
	    {next_state, connected, State#state{ref = Ref2}};
	{error, _Reason} ->
	    {next_state, disconnected, State#state{sock = undefined}}
    end;	    

connected(Event, _From, State) ->
    io:format("unsupported event: ~p~n", [Event]),
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
%% @end
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

%% connect to mqtt broker.
connect(#state{host = Host} = State) 
  when is_binary(Host) ->
    connect(State#state{host = binary_to_list(Host)});

connect(#state{host = Host, port = Port, name = Name,
	       sock = undefined, sock_pid = undefined} = State) 
  when is_list(Host); is_tuple(Host),
       is_integer(Port),
       is_atom(Name) orelse is_pid(Name) ->
    io:format("connecting to ~p:~p~n", [Host, Port]),
    Ref = make_ref(),
    SockPid = case emqttc_sock_sup:start_sock(Ref, Host, Port, Name) of
		  {ok, SockPid1}                      -> SockPid1;
		  {error,{already_started, SockPid2}} -> SockPid2
	      end,
    {next_state, connecting, State#state{sock_pid = SockPid, sock_ref = Ref}};

%% now already socket pid is spawned.
connect(#state{sock_ref = Ref} = State) ->
    emqttc_sock_sup:stop_sock(Ref),    
    connect(State#state{sock = undefined, 
			sock_pid = undefined, 
			sock_ref = undefined}).

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

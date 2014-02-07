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

-record(state, {host      :: inet:ip_address(),
		port      :: inet:port_number(),
		sock      :: gen_tcp:socket(),
		sock_pid  :: supervisor:child(),
		msgid = 0 :: non_neg_integer(),
		username  :: binary(),
		password  :: binary(),
		ref       :: dict(),
		client_id :: binary() }).

%%--------------------------------------------------------------------
%% @doc start application
%% @end
%%--------------------------------------------------------------------
-spec start() -> ok.
start() ->
    application:start(emqttc).

%%--------------------------------------------------------------------
%% @doc Starts the server
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
    start_link(emqttc, Opts).

%%--------------------------------------------------------------------
%% @doc Starts the server with name and options.
%% @end
%%--------------------------------------------------------------------
-spec start_link(atom(), [tuple()]) -> {ok, pid()} | ignore | {error, term()}.
start_link(Name, Opts) when is_atom(Name), is_list(Opts) ->
    gen_fsm:start_link({local, Name}, ?MODULE, [Name, Opts], []).

%%--------------------------------------------------------------------
%% @doc publish to broker.
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
subscribe(C, Topics) ->
    gen_fsm:send_event(C, {subscribe, Topics}).

%%--------------------------------------------------------------------
%% @doc unsubscribe request to broker.
%% @end
%%--------------------------------------------------------------------
-spec unsubscribe(C, Topics) -> ok when
      C :: pid() | atom(),
      Topics :: [ {binary(), non_neg_integer()} ].
unsubscribe(C, Topics) ->
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

%%gen_fsm callbacks
init([_Name, Args]) ->
    emqttc_sock_sup:stop_sock(0),
    Host = proplists:get_value(host, Args, "localhost"),
    Port = proplists:get_value(port, Args, 1883),
    Username = proplists:get_value(username, Args, undefined),
    Password = proplists:get_value(password, Args, undefined),

    <<DefaultIdentifier:23/binary, _/binary>> = ossp_uuid:make(v4, text),
    ClientId = proplists:get_value(client_id, Args, DefaultIdentifier),

    State = #state{host = Host, port = Port, ref = dict:new(),
		   client_id = ClientId,
		   username = Username, password = Password},
    {ok, connecting, State, 0}.

%% reconnect
disconnected(timeout, State) ->
    timer:sleep(5000),
    {next_state, connecting, State, 0};

disconnected({set_socket, Sock}, State) ->
    NewState = State#state{sock = Sock},
    send_connect(NewState),
    {next_state, waiting_for_connack, NewState};

disconnected(_, State) ->
    {next_state, disconnected, State}.

disconnected(_, _From, State) ->
    {next_state, disconnected, State}.

connecting(timeout, State) ->
    connect(State);

connecting({set_socket, Sock}, State) ->
    NewState = State#state{sock = Sock},
    send_connect(NewState),
    {next_state, waiting_for_connack, NewState};

connecting(_Event, State) ->
    {next_state, connecting, State}.

connecting(_Event, _From, State) ->
    {reply, {error, connecting}, connecting, State}.


%% connect to mqtt broker.
connect(#state{host = Host, port = Port,
	       sock = undefined, sock_pid = undefined} = State) ->
    io:format("connecting to ~p:~p~n", [Host, Port]),

    SockPid = case emqttc_sock_sup:start_sock(0, Host, Port, self()) of
		  {ok, SockPid1}                      -> SockPid1;
		  {error,{already_started, SockPid2}} -> SockPid2
	      end,
    {next_state, connecting, State#state{sock_pid = SockPid}};

%% now already socket pid is spawned.
connect(#state{sock = _Sock, sock_pid = _SockPid} = State) ->
    emqttc_sock_sup:stop_sock(0),    
    connect(State#state{sock = undefined, sock_pid = undefined}).

send_connect(#state{sock=Sock, username=Username, password=Password,
		    client_id=ClientId}) ->
    Frame = 
	#mqtt_frame{
	   fixed = #mqtt_frame_fixed{
		      type = ?CONNECT,
		      dup = 0,
		      qos = 1,
		      retain = 0},
	   variable = #mqtt_frame_connect{
			 username   = Username,
			 password   = Password,
			 proto_ver  = ?MQTT_PROTO_MAJOR,
			 clean_sess = true,
			 keep_alive = 60,
			 client_id  = ClientId}},
    send_frame(Sock, Frame).

waiting_for_connack(_Event, State) ->
    %FIXME:
    {next_state, waiting_for_connack, State}.

connected({set_socket, Sock}, State) ->
    {next_state, connected, State#state{sock = Sock}};

connected({publish, Msg}, State=#state{sock=Sock, msgid=MsgId}) ->
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
    send_frame(Sock, Frame),
    {next_state, connected, State#state{msgid=MsgId+1}};

connected({puback, MsgId}, State=#state{sock=Sock}) ->
    send_puback(Sock, ?PUBACK, MsgId),
    {next_state, connected, State};

connected({pubrec, MsgId}, State=#state{sock=Sock}) ->
    send_puback(Sock, ?PUBREC, MsgId),
    {next_state, connected, State};

connected({pubcomp, MsgId}, State=#state{sock=Sock}) ->
    send_puback(Sock, ?PUBCOMP, MsgId),
    {next_state, connected, State};

connected({subscribe, Topics}, State=#state{msgid=MsgId,sock=Sock}) ->
    Topics1 = [#mqtt_topic{name=Topic, qos=Qos} || {Topic, Qos} <- Topics],
    Frame = #mqtt_frame{
	       fixed = #mqtt_frame_fixed{type = ?SUBSCRIBE,
					 dup = 0,
					 qos = 1,
					 retain = 0},
	       variable = #mqtt_frame_subscribe{message_id  = MsgId,
						topic_table = Topics1}},
    send_frame(Sock, Frame),
    {next_state, connected, State#state{msgid=MsgId+1}};

connected({unsubscribe, Topics}, State=#state{sock=Sock, msgid=MsgId}) ->
    Frame = #mqtt_frame{
	       fixed = #mqtt_frame_fixed{type = ?UNSUBSCRIBE,
					 dup = 0,
					 qos = 1,
					 retain = 0},
	       variable = MsgId,
	       payload = Topics},
    send_frame(Sock, Frame),
    {next_state, connected, State};

connected(disconnect, State=#state{sock=Sock}) ->
    send_disconnect(Sock),
    {next_state, connected, State};

connected(_Event, State) -> 
    {next_state, connected, State}.

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
    send_frame(Sock, Frame),
    Ref2 = dict:append(publish, From, Ref),
    {next_state, connected, State#state{msgid=MsgId+1, ref=Ref2}};

connected({pubrel, MsgId}, From, State=#state{sock=Sock, ref=Ref}) ->
    send_puback(Sock, ?PUBREL, MsgId),
    Ref2 = dict:append(pubrel, From, Ref),
    {next_state, connected, State#state{ref=Ref2}};

connected(ping, From, State=#state{sock=Sock, ref = Ref}) ->
    send_ping(Sock),
    Ref2 = dict:append(ping, From, Ref),
    {next_state, connected, State#state{ref = Ref2}};

connected(Event, _From, State) ->
    io:format("unsupported event: ~p~n", [Event]),
    {reply, {error, unsupport}, connected, State}.

%reconnect() ->
    %%FIXME
%    erlang:send_after(30000, self(), {timeout, reconnect}).

%% connack message from broker(without remaining length).
handle_info({tcp, _Sock, <<?CONNACK:4/integer, _:4/integer,
			 _:8/integer, ReturnCode:8/unsigned-integer>>},
	    waiting_for_connack, State) ->
    case ReturnCode of
	?CONNACK_ACCEPT ->
	    io:format("connack: Connection Accepted~n"),
	    gen_event:notify(emqttc_event, {connack_accept}),
	    {next_state, connected, State};
	?CONNACK_PROTO_VER ->
	    io:format("connack: NG(unacceptable protocol version)~n"),
	    {next_state, waiting_for_connack, State};
	?CONNACK_INVALID_ID ->
	    io:format("connack: NG(identifier rejected)~n"),
	    {next_state, waiting_for_connack, State};
	?CONNACK_SERVER ->
	    io:format("connack: NG(server unavailable)~n"),
	    {next_state, waiting_for_connack, State};
	?CONNACK_CREDENTIALS ->
	    io:format("connack: NG(bad user name or password)~n"),
	    {next_state, waiting_for_connack, State};
	?CONNACK_AUTH ->
	    io:format("connack: NG(not authorized)~n"),
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
	    connected, State) ->
    gen_event:notify(emqttc_event, {publish, Topic, Payload}),
    {next_state, connected, State};

%% pub message from broker(QoS = 1 or 2)(without remaining length).
handle_info({tcp, _Sock, <<?PUBLISH:4/integer,
			   _:1/integer, Qos:2/integer, _:1/integer,
			   TopicSize:16/big-unsigned-integer,
			   Topic:TopicSize/binary,
			   MsgId:16/big-unsigned-integer,
			   Payload/binary>>},
	    connected, State) when Qos =:= ?QOS_1; Qos =:= ?QOS_2 ->
    gen_event:notify(emqttc_event, {publish, Topic, Payload, Qos, MsgId}),
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
    <<Code:4/integer, _:4/integer, _/binary>> = Data,
    io:format("data received from remote(code:~w): ~p~n", [Code, Data]),
    {next_state, connected, State};

handle_info({tcp_closed, _Sock}, _, State) ->
    io:format("tcp_closed state goto disconnected.~n"),
    {next_state, disconnected, State};

handle_info({timeout, reconnect}, connecting, S) ->
    connect(S);

handle_info(_Info, StateName, State) ->
    {next_state, StateName, State}.

handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

handle_sync_event(status, _From, StateName, State) ->
    Statistics = [{N, get(N)} || N <- [inserted]],
    {reply, {StateName, Statistics}, StateName, State};

handle_sync_event(stop, _From, _StateName, State) ->
    {stop, normal, ok, State}.

terminate(_Reason, _StateName, #state{sock_pid = undefined}) ->
    ok;

terminate(_Reason, _StateName, _State) ->
    emqttc_sock_sup:stop_sock(0),    
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

send_puback(Sock, Type, MsgId) ->
    Frame = #mqtt_frame{
	       fixed = #mqtt_frame_fixed{type = Type},
	       variable = #mqtt_frame_publish{message_id = MsgId}},
    send_frame(Sock, Frame).

send_disconnect(Sock) ->
    Frame = #mqtt_frame{
	       fixed = #mqtt_frame_fixed{type = ?DISCONNECT,
					 qos = 0,
					 retain = 0,
					 dup = 0}},
    send_frame(Sock, Frame).

send_ping(Sock) ->
    Frame = #mqtt_frame{
	       fixed = #mqtt_frame_fixed{type = ?PINGREQ,
					 qos = 1,
					 retain = 0,
					 dup = 0}},
    send_frame(Sock, Frame).

send_frame(Sock, Frame) ->
    try
	erlang:port_command(Sock, emqtt_frame:serialise(Frame))
    catch
	error:Reason ->
	    io:format("error when publish data: ~p~n", [Reason])
    end.

reply(Reply, Name, Ref) ->
    case dict:find(Name, Ref) of
	{ok, []} ->
	    Ref;
	{ok, [From | FromTail]} ->
	    gen_fsm:reply(From, Reply),
	    dict:store(Name, FromTail, Ref)
    end.

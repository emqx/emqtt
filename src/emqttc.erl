-module(emqttc).

-include("emqtt_frame.hrl").

-import(proplists, [get_value/2, get_value/3]).

%startup
-export([start_link/0,
		start_link/1,
		start_link/2]).

%api
-export([publish/2,
		puback/2,
		pubrec/2,
		pubcomp/2,
		subscribe/2,
		unsubscribe/2,
		ping/1,
		disconnect/1]).


-behavior(gen_fsm).

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
		connected/3]).

-define(TCPOPTIONS, [
	binary,
	{packet,    raw},
	{reuseaddr, true},
	{backlog,   128},
	{nodelay,   true},
	{active, 	true},
	{reuseaddr, true},
	{send_timeout,  3000}]).

-define(TIMEOUT, 3000).

-record(state, {host, port, sock, msgid}).

%startup
start_link() ->
	start_link([]).

start_link(Opts) ->
	start_link(emqttc, Opts).

start_link(Name, Opts) ->
	gen_fsm:start_link({local, Name}, ?MODULE, [Name, Opts], []).

%api functions
publish(C, Msg) when is_record(Msg, mqtt_msg) ->
	gen_fsm:send_event(C, {publish, Msg}).

puback(C, MsgId) when is_integer(MsgId) ->
	gen_fsm:send_event(C, {puback, MsgId}).

pubrec(C, MsgId) when is_integer(MsgId) ->
	gen_fsm:send_event(C, {pubrec, MsgId}).

pubcomp(C, MsgId) when is_integer(MsgId) ->
	gen_fsm:send_event(C, {pubcomp, MsgId}).

subscribe(C, Topics) ->
	gen_fsm:sync_send_event(C, {subscribe, Topics}).

unsubscribe(C, Topics) ->
	gen_fsm:sync_send_event(C, {unsubscribe, Topics}).

ping(C) ->
	gen_fsm:send_event(C, ping).

disconnect(C) ->
	gen_fsm:send_event(C, disconnect).

%gen_fsm callbacks
init([_Name, Args]) ->
    Host = get_value(host, Args, "localhost"),
    Port = get_value(port, Args, 1883),
    State = #state{host = Host, port = Port},
    {ok, connecting, State, 0}.

connecting(timeout, State) ->
    connect(State);

connecting(_Event, State) ->
    {next_state, connecting, State}.

connecting(_Event, _From, State) ->
	{reply, {error, connecting}, connecting, State}.

connect(#state{host = Host, port = Port} = State) ->
    case gen_tcp:connect(Host, Port, ?TCPOPTIONS, ?TIMEOUT) of
    {ok, Sock} ->
		NewState = State#state{sock = Sock},
		send_connect(NewState),
        {next_state, waiting_for_connack, NewState};
    {error, _Reason} ->
        reconnect(),
        {next_state, connecting, State#state{sock = undefined}}
    end.

send_connect(#state{sock=Sock}) ->
	Frame = 
	#mqtt_frame{
		fixed = #mqtt_frame_fixed{
			type = ?CONNECT,
			dup = 0,
			qos = 1,
			retain = 0},
		variable = #mqtt_frame_connect{
			%username   = Username,
			%password   = Password,
			proto_ver  = ?MQTT_PROTO_MAJOR,
			clean_sess = true,
			keep_alive = 60,
			client_id  = "emqttc"}},
	%CONNECT Frame
	send_frame(Sock, Frame).

waiting_for_connack(_Event, State) ->
	%FIXME:
	{next_state, waiting_for_connack, State}.

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
									   message_id = if
													Qos == ?QOS_0 -> undefined;
													true -> MsgId
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

connected({pubrel, MsgId}, State=#state{sock=Sock}) ->
	send_puback(Sock, ?PUBREL, MsgId),
	{next_state, connected, State};

connected({pubcomp, MsgId}, State=#state{sock=Sock}) ->
	send_puback(Sock, ?PUBCOMP, MsgId),
	{next_state, connected, State};

connected(ping, State=#state{sock=Sock}) ->
	send_ping(Sock),
	{next_state, connected, State};

connected(disconnect, State=#state{sock=Sock}) ->
	send_disconnect(Sock),
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

connected(_Event, State) -> 
	{next_state, connected, State}.

%FIXME: later
connected(_Event, _From, State) ->
	{reply, {error, unsupport}, connected, State}.

reconnect() ->
	%FIXME:
    erlang:send_after(30000, self(), {timeout, reconnect}).
	
handle_info({tcp, _Sock, Data}, connected, State) ->
	{next_state, connected, State};

handle_info({tcp_closed, Sock}, connected, State=#state{sock=Sock}) ->
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

terminate(_Reason, _StateName, _State) ->
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

send_puback(Sock, Type, MsgId) ->
	Frame = #mqtt_frame{
		fixed = #mqtt_frame_fixed{type = ?PUBACK},
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
    erlang:port_command(Sock, emqtt_frame:serialise(Frame)).


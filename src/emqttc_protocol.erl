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

-module(emqttc_protocol).

-include("emqttc_packet.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([init/1,
         set_socket/2,
         client_id/1]).

%% Protocol API
-export([connect/1,
         publish/2,
         subscribe/2,
         unsubscribe/2,
         ping/1,
         disconnect/1,
         send/2, 
         handle_packet/3, 
         redeliver/2, 
         shutdown/2]).

%% ------------------------------------------------------------------
%% Protocol State
%% ------------------------------------------------------------------
-record(proto_state, {socket,
                      socket_name,
                      proto_ver,
                      proto_name,
                      client_id,
                      clean_sess,
                      keep_alive,
                      will_flag,
                      will_msg,
                      username,
                      password,
                      session,
                      logger}).

-type proto_state() :: #proto_state{}.

-export_type([proto_state/0]).

-define(KEEPALIVE, 60).

%% ------------------------------------------------------------------
%% @doc Init Protocol State
%% ------------------------------------------------------------------
-spec init(MqttOpts) -> State when
    MqttOpts :: list(tuple()),
    State    :: proto_state().
init(MqttOpts) ->
	init(MqttOpts, #proto_state{ client_id   = random_id(),
                                 proto_ver   = ?MQTT_PROTO_V311,
                                 proto_name  = <<"MQTT">>,
                                 clean_sess  = false,
                                 keep_alive  = ?KEEPALIVE,
                                 will_flag   = false,
                                 will_msg    = #mqtt_message{} }).

init([], State) ->
    State;
init([{client_id, ClientId} | Opts], State) when is_binary(ClientId) ->
    init(Opts, State#proto_state{client_id = ClientId});
init([{clean_sess, CleanSess} | Opts], State) when is_boolean(CleanSess) ->
    init(Opts, State#proto_state{clean_sess = CleanSess});
init([{keep_alive, KeepAlive} | Opts], State) when is_integer(KeepAlive) ->
    init(Opts, State#proto_state{keep_alive = KeepAlive});
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

set_socket(State, Socket) ->
    {ok, SockName} = emqttc_socket:sockname_s(Socket),
    State#proto_state{
        socket = Socket,
        socket_name = SockName
    }.

client_id(#proto_state{client_id = ClientId}) -> 
    ClientId.

connect(State = #proto_state{client_id  = ClientId,
                             proto_ver  = ProtoVer, 
                             proto_name = ProtoName,
                             clean_sess = CleanSess,
                             keep_alive = KeepAlive,
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

    send(emqttc_packet:make(?CONNECT, Connect), State).


disconnect(State) ->
    send(emqttc_packet:make(?DISCONNECT), State).

% qos0 sent directly
publish(Message = #mqtt_message{qos = ?QOS_0}, State) ->
	send(emqttc_message:to_packet(Message), State);

%% qos1, qos2 messages should be stored first
publish(Message = #mqtt_message{qos = Qos}, State = #proto_state{session = Session}) 
    when (Qos =:= ?QOS_1) orelse (Qos =:= ?QOS_2) ->
    {Message1, NewSession} = emqttc_session:store(Session, Message),
	send(emqttc_message:to_packet(Message1), State#proto_state{session = NewSession}).

subscribe(Topics, State) ->
    %FIXME...
    PacketId = 1,
    Subscribe = #mqtt_packet_subscribe{packet_id = PacketId, 
                                       topic_table = Topics},
    send(emqttc_packet:make(?SUBSCRIBE, Subscribe), State).

unsubscribe(Topics, State) ->
    %FIXME...
    PacketId = 1,
    Unsubscribe = #mqtt_packet_unsubscribe{packet_id = PacketId,
                                           topics    = Topics },
    send(emqttc_packet:make(?UNSUBSCRIBE, Unsubscribe), State).

ping(State) ->
    send(State, emqttc_packet:make(?PINGREQ)).

%%CONNECT – Client requests a connection to a Server

handle_packet(?CONNACK, Packet = #mqtt_packet {}, State = #proto_state{session = Session}) ->
    %%TODO: create or resume session
	{ok, State};

handle_packet(?PUBLISH, Packet = #mqtt_packet {
                                     header = #mqtt_packet_header {qos = ?QOS_0}},
                                 State = #proto_state{session = Session}) ->
    emqttc_session:publish(Session, {?QOS_0, emqttc_message:from_packet(Packet)}),
	{ok, State};

handle_packet(?PUBLISH, Packet = #mqtt_packet { 
                                     header = #mqtt_packet_header { qos = ?QOS_1 }, 
                                     variable = #mqtt_packet_publish{packet_id = PacketId }}, 
                                 State = #proto_state { session = Session }) ->
    emqttc_session:publish(Session, {?QOS_1, emqttc_message:from_packet(Packet)}),
    send( emqttc_packet:make(?PUBACK,  PacketId),  State);

handle_packet(?PUBLISH, Packet = #mqtt_packet { 
                                     header = #mqtt_packet_header { qos = ?QOS_2 }, 
                                     variable = #mqtt_packet_publish { packet_id = PacketId } }, 
                                 State = #proto_state { session = Session }) ->
    NewSession = emqttc_session:publish(Session, {?QOS_2, emqttc_message:from_packet(Packet)}),
	send( emqttc_packet:make(?PUBREC, PacketId), State#proto_state {session = NewSession} );

handle_packet(Puback, #mqtt_packet{variable = Packet }, State = #proto_state{session = Session}) 
    when Puback >= ?PUBACK andalso Puback =< ?PUBCOMP ->

    #mqtt_packet_puback{packet_id = PacketId} = Packet,

    NewSession = emqttc_session:puback(Session, {Puback, PacketId}),
    NewState = State#proto_state {session = NewSession},
    if 
        Puback =:= ?PUBREC ->
            send(emqttc_packet:make(?PUBREL, PacketId), NewState);
        Puback =:= ?PUBREL ->
            send(emqttc_packet:make(?PUBCOMP, PacketId), NewState);
        true ->
            ok
    end,
	{ok, NewState};

handle_packet(?SUBACK, #mqtt_packet{variable = #mqtt_packet_suback{packet_id = PacketId}},
              State = #proto_state{session = Session})  ->
    %%TODO:...
	{ok, State};

handle_packet(?UNSUBACK, #mqtt_packet{variable = #mqtt_packet_unsuback{packet_id = PacketId}},
              State = #proto_state{session = Session}) ->
    %%TODO:...
	{ok, State}.

%%
%% @doc redeliver PUBREL PacketId
%%
redeliver({?PUBREL, PacketId}, State) ->
    send(emqttc_packet:make(?PUBREL, PacketId), State).

send(Packet, State = #proto_state{socket = Socket, logger = Logger}) ->
    Logger:info("[~s] SENT : ~s", [logtag(State), emqttc_packet:dump(Packet)]),
    Data = emqttc_serialiser:serialise(Packet),
    Logger:debug("[~s] SENT: ~p", [logtag(State), Data]),
    emqttc_socket:send(Socket, Data),
    {ok, State}.

shutdown(Error, #proto_state{socket_name = SocketName, client_id = ClientId, logger = Logger}) ->
	Logger:info("Protocol ~s@~s Shutdown: ~p", [ClientId, SocketName, Error]),
    ok.

%%----------------------------------------------------------------------------

start_keepalive(0) -> ignore;
start_keepalive(Sec) when Sec > 0 ->
    self() ! {keepalive, start, round(Sec * 1.5)}.

%%----------------------------------------------------------------------------
%% Validate Packets
%%----------------------------------------------------------------------------
validate_protocol(#mqtt_packet_connect { proto_ver = Ver, proto_name = Name }) ->
    lists:member({Ver, Name}, ?PROTOCOL_NAMES).

validate_qos(undefined) -> true;
validate_qos(Qos) when Qos =< ?QOS_2 -> true;
validate_qos(_) -> false.

logtag(#proto_state{socket_name = SocketName, client_id = ClientId}) ->
    io_lib:format("~s@~s", [ClientId, SocketName]).


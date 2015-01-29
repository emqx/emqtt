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

-export([init/0,
         set_socket/2,
         client_id/1]).

%% Protocol API
-export([connect/1,
         publish/2,
         subscribe/2,
         unsubscribe/2,
         ping/2,
         disconnect/1,
         send/2, 
         handle_packet/3, 
         redeliver/2, 
         shutdown/2]).

%% ------------------------------------------------------------------
%% Protocol State
%% ------------------------------------------------------------------
-record(proto_state, {
          socket,
          socket_name,
          proto_ver,
          proto_name,
          client_id,
          clean_sess,
          keep_alive,
          will,
          username,
          password,
          session,
          logger
}).

-type proto_state() :: #proto_state{}.

-export_type([proto_state/0]).

-define(KEEPALIVE, 60).

init(MqttOpts) ->
	parse_opts(MqttOpts, #proto_state{ client_id   = random_id(),
                                       proto_ver   = ?MQTT_PROTO_V311,
                                       proto_name  = <<"MQTT">>,
                                       clean_sess  = false,
                                       keep_alive  = ?KEEPALIVE,
                                       will        = #mqtt_message{} }).

parse_opts([], State) ->
    State;
parse_opts([{client_id, ClientId} | Opts], State) when is_binary(ClientId) ->
    parse_opts(Opts, State#proto_state {client_id = ClientId}, Opts);
parse_opts(State, [{clean_sess, CleanSess} | Opts]) when is_boolean(CleanSess) ->
    parse_opts(Opts, State#proto_state {clean_sess = CleanSess}, Opts);
parse_opts(State, [{keep_alive, KeepAlive} | Opts]) when is_integer(KeepAlive) ->
    parse_opts(Opts, State#proto_state {keep_alive = KeepAlive}, Opts);
parse_opts(State, [{username, Username} | Opts]) when is_binary(Username)->
    parse_opts(Opts, State#proto_state { username = Username}, Opts);
parse_opts(State, [{password, Password} | Opts]) when is_binary(Password) ->
    parse_opts(Opts, State#proto_state { password = Password }, Opts);
parse_opts(State = #proto_state{will = Will}, [{will_topic, Topic} | Opts]) when is_binary(Topic) ->
    parse_opts(Opts, State#proto_state{will = Will#mqtt_message{topic = Topic}}, Opts);
parse_opts(State = #proto_state{will = Will}, [{will_msg, Msg} | Opts]) when is_binary(Msg) ->
    parse_opts(Opts, State#proto_state{will = Will#mqtt_message{ payload = Msg}}, Opts); %TODO: right?
parse_opts(State = #proto_state{will = Will}, [{will_qos, Qos} | Opts]) when ?IS_QOS(Qos) ->
    parse_opts(Opts, State#proto_state{will = Will#mqtt_message{qos = Qos}}, Opts);
parse_opts(State = #proto_state{will = Will}, [{will_retain, Retain} | Opts]) when is_boolean(Retain) ->
    parse_opts(Opts, State#proto_state{will = Will#mqtt_message{retain = Retain}}, Opts);
parse_opts(State, [{logger, Logger} | Opts]) ->
    parse_opts(Opts, State#proto_state { logger = Logger }, Opts);
parse_opts([_Opt | Opts], State) ->
    parse_opts(Opts, State).

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

client_id(#proto_state {client_id = ClientId}) -> ClientId.

connect(State = #proto_state{client_id = ClientId,
                                  proto_ver = ProtoVer, 
                                  proto_name = ProtoName,
                                  clean_sess = CleanSess,
                                  keep_alive = KeepAlive,
                                  will = Will,
                                  username = Username,
                                  password = Password}) ->

    #mqtt_message{qos = WillQos, retain = WillRetain, topic = WillTopic, payload = WillMsg} = Will,

    WillFlag = not (WillTopic =:= undefined orelse WillMsg =:= undefined),

    ConnectPkt = #mqtt_packet_connect{client_id  = ClientId1,
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

    send_packet(#mqtt_packet{header = #mqtt_packet_header{type = ?CONNECT}, 
                             variable = ConnectPkt}, State).


disconnect(State) ->
    send(State, emqttc_packet:make(?DISCONNECT)).

% qos0 sent directly
publish(State, Message = #mqtt_message{qos = ?QOS_0}) ->
	send(State, emqttc_message:to_packet(Message));

%% qos1, qos2 messages should be stored first
publish(State = #proto_state{session = Session}, Message = #mqtt_message{qos = Qos}}) 
    when (Qos =:= ?QOS_1) orelse (Qos =:= ?QOS_2) ->
    {Message1, NewSession} = emqttc_session:store(Session, Message),
	send(emqttc_message:to_packet(Message1), State#proto_state{session = NewSession}).

subscribe(State, Topics) ->
    %%FIXME:
    send(State, emqttc_packet:make(?SUBSCRIBE, {1, Topics})).

unsubscribe(State, Topics) ->
    send(State, emqttc_packet:make(?UNSUBSCRIBE, Topics)).

ping(State) ->
    send(State, emqttc_packet:make(?PINGREQ)).

%%CONNECT – Client requests a connection to a Server

-spec handle_packet(mqtt_packet(), atom(), proto_state()) -> {ok, proto_state()} | {error, any()}.
handle_packet(?CONNACK, Packet = #mqtt_packet {}, State = #proto_state{session = Session}) ->
    %%create or resume session
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
    send_packet( make_packet(?PUBACK,  PacketId),  State);

handle_packet(?PUBLISH, Packet = #mqtt_packet { 
                                     header = #mqtt_packet_header { qos = ?QOS_2 }, 
                                     variable = #mqtt_packet_publish { packet_id = PacketId } }, 
                                 State = #proto_state { session = Session }) ->
    NewSession = emqttc_session:publish(Session, {?QOS_2, emqttc_message:from_packet(Packet)}),
	send_packet( make_packet(?PUBREC, PacketId), State#proto_state {session = NewSession} );

handle_packet(Puback, #mqtt_packet{variable = ?PUBACK_PACKET(PacketId) }, 
    State = #proto_state { session = Session }) 
    when Puback >= ?PUBACK andalso Puback =< ?PUBCOMP ->

    NewSession = emqttc_session:puback(Session, {Puback, PacketId}),
    NewState = State#proto_state {session = NewSession},
    if 
        Puback =:= ?PUBREC ->
            send_packet( make_packet(?PUBREL, PacketId), NewState);
        Puback =:= ?PUBREL ->
            send_packet( make_packet(?PUBCOMP, PacketId), NewState);
        true ->
            ok
    end,
	{ok, NewState};


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


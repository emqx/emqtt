%%--------------------------------------------------------------------
%% Copyright (c) 2020 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(emqtt).

-behaviour(gen_statem).

-include("emqtt.hrl").

-export([ start_link/0
        , start_link/1
        ]).

-export([ connect/1
        , ws_connect/1
        , disconnect/1
        , disconnect/2
        , disconnect/3
        ]).

-export([ping/1]).

%% PubSub
-export([ subscribe/2
        , subscribe/3
        , subscribe/4
        , publish/2
        , publish/3
        , publish/4
        , publish/5
        , unsubscribe/2
        , unsubscribe/3
        ]).

%% Puback...
-export([ puback/2
        , puback/3
        , puback/4
        , pubrec/2
        , pubrec/3
        , pubrec/4
        , pubrel/2
        , pubrel/3
        , pubrel/4
        , pubcomp/2
        , pubcomp/3
        , pubcomp/4
        ]).

-export([subscriptions/1]).

-export([info/1, stop/1]).
-export([stats/1]).

%% For test cases
-export([ pause/1
        , resume/1
        ]).

-export([ initialized/3
        , waiting_for_connack/3
        , connected/3
        , inflight_full/3
        , random_client_id/0
        , reason_code_name/1
        ]).

-export([ init/1
        , callback_mode/0
        , handle_event/4
        , terminate/3
        , code_change/4
        ]).


-export_type([ host/0
             , option/0
             , properties/0
             , payload/0
             , pubopt/0
             , subopt/0
             , mqtt_msg/0
             , client/0
             ]).

-type(host() :: inet:ip_address() | inet:hostname()).

%% Message handler is a set of callbacks defined to handle MQTT messages
%% as well as the disconnect event.
-define(NO_MSG_HDLR, undefined).

-type(mfas() :: {module(), atom(), list()} | {function(), list()}).

-type(msg_handler() :: #{puback := fun((_) -> any()) | mfas(),
                         publish := fun((emqx_types:message()) -> any()) | mfas(),
                         disconnected := fun(({reason_code(), _Properties :: term()}) -> any()) | mfas()
                        }).

-type(option() :: {name, atom()}
                | {owner, pid()}
                | {msg_handler, msg_handler()}
                | {host, host()}
                | {hosts, [{host(), inet:port_number()}]}
                | {port, inet:port_number()}
                | {tcp_opts, [gen_tcp:option()]}
                | {ssl, boolean()}
                | {ssl_opts, [ssl:ssl_option()]}
                | {ws_path, string()}
                | {connect_timeout, pos_integer()}
                | {bridge_mode, boolean()}
                | {clientid, iodata()}
                | {clean_start, boolean()}
                | {username, iodata()}
                | {password, iodata()}
                | {proto_ver, v3 | v4 | v5}
                | {keepalive, non_neg_integer()}
                | {max_inflight, pos_integer()}
                | {retry_interval, timeout()}
                | {max_retry_count, non_neg_integer()}
                | {message_delivery_timeout, non_neg_integer()}
                | {will_topic, iodata()}
                | {will_payload, iodata()}
                | {will_retain, boolean()}
                | {will_qos, qos()}
                | {will_props, properties()}
                | {auto_ack, boolean()}
                | {ack_timeout, pos_integer()}
                | {force_ping, boolean()}
                | {properties, properties()}).

-type(maybe(T) :: undefined | T).
-type(topic() :: binary()).
-type(payload() :: iodata()).
-type(packet_id() :: 0..16#FFFF).
-type(reason_code() :: 0..16#FF).
-type(properties() :: #{atom() => term()}).
-type(version() :: ?MQTT_PROTO_V3
                 | ?MQTT_PROTO_V4
                 | ?MQTT_PROTO_V5).
-type(qos() :: ?QOS_0 | ?QOS_1 | ?QOS_2).
-type(qos_name() :: qos0 | at_most_once |
                    qos1 | at_least_once |
                    qos2 | exactly_once).
-type(pubopt() :: {retain, boolean()}
                | {qos, qos() | qos_name()}).
-type(subopt() :: {rh, 0 | 1 | 2}
                | {rap, boolean()}
                | {nl,  boolean()}
                | {qos, qos() | qos_name()}).

-type(subscribe_ret() ::
      {ok, properties(), [reason_code()]} | {error, term()}).

-type(conn_mod() :: emqtt_sock | emqtt_ws).

-type(client() :: pid() | atom()).

-type(msg_inflight_meta() ::  #{ first_sent_at := pos_integer(),
                                 last_sent_at := pos_integer(),
                                 retry_count := non_neg_integer()
                               }).

-opaque(mqtt_msg() :: #mqtt_msg{}).

-record(state, {
          name            :: atom(),
          owner           :: pid(),
          msg_handler     :: ?NO_MSG_HDLR | msg_handler(),
          host            :: host(),
          port            :: inet:port_number(),
          hosts           :: [{host(), inet:port_number()}],
          conn_mod        :: conn_mod(),
          socket          :: inet:socket() | pid(),
          sock_opts       :: [emqtt_sock:option()|emqtt_ws:option()],
          connect_timeout :: pos_integer(),
          bridge_mode     :: boolean(),
          clientid        :: binary(),
          clean_start     :: boolean(),
          username        :: maybe(binary()),
          password        :: maybe(binary()),
          proto_ver       :: version(),
          proto_name      :: iodata(),
          keepalive       :: non_neg_integer(),
          keepalive_timer :: maybe(reference()),
          force_ping      :: boolean(),
          paused          :: boolean(),
          will_flag       :: boolean(),
          will_msg        :: mqtt_msg(),
          properties      :: properties(),
          pending_calls   :: list(),
          subscriptions   :: map(),
          max_inflight    :: infinity | pos_integer(),
          inflight        :: #{packet_id() => {publish | pubrel, term(), msg_inflight_meta()}},
          awaiting_rel    :: map(),
          auto_ack        :: boolean(),
          ack_timeout     :: pos_integer(),
          ack_timer       :: reference(),
          retry_interval  :: pos_integer(),
          retry_timer     :: reference(),
          session_present :: boolean(),
          last_packet_id  :: packet_id(),
          parse_state     :: emqtt_frame:parse_state()
         }).

-record(call, {id, from, req, ts}).

%% Default timeout
-define(DEFAULT_KEEPALIVE, 60).
-define(DEFAULT_RETRY_INTERVAL, 30000).
-define(DEFAULT_ACK_TIMEOUT, 30000).
-define(DEFAULT_CONNECT_TIMEOUT, 60000).

-define(PROPERTY(Name, Val), #state{properties = #{Name := Val}}).

-define(WILL_MSG(QoS, Retain, Topic, Props, Payload),
        #mqtt_msg{qos = QoS,
                  retain = Retain,
                  topic = Topic,
                  props = Props,
                  payload = Payload
                 }).

-define(NO_CLIENT_ID, <<>>).

-define(LOG(Level, Format, Args, State),
        begin
          (logger:log(Level, #{}, #{report_cb => fun(_) -> {"emqtt(~s): "++(Format), ([State#state.clientid|Args])} end}))
        end).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

-spec(start_link() -> gen_statem:start_ret()).
start_link() -> start_link([]).

-spec(start_link(map() | [option()]) -> gen_statem:start_ret()).
start_link(Options) when is_map(Options) ->
    start_link(maps:to_list(Options));
start_link(Options) when is_list(Options) ->
    ok = emqtt_props:validate(
            proplists:get_value(properties, Options, #{})),
    case proplists:get_value(name, Options) of
        undefined ->
            gen_statem:start_link(?MODULE, [with_owner(Options)], []);
        Name when is_atom(Name) ->
            gen_statem:start_link({local, Name}, ?MODULE, [with_owner(Options)], [])
    end.

with_owner(Options) ->
    case proplists:get_value(owner, Options) of
        Owner when is_pid(Owner) -> Options;
        undefined -> [{owner, self()} | Options]
    end.

-spec(connect(client()) -> {ok, properties()} | {error, term()}).
connect(Client) ->
    call(Client, {connect, emqtt_sock}).

ws_connect(Client) ->
    call(Client, {connect, emqtt_ws}).

%% @private
call(Client, Req) ->
    gen_statem:call(Client, Req, infinity).

-spec(subscribe(client(), topic() | {topic(), qos() | qos_name() | [subopt()]} | [{topic(), qos()}])
      -> subscribe_ret()).
subscribe(Client, Topic) when is_binary(Topic) ->
    subscribe(Client, {Topic, ?QOS_0});
subscribe(Client, {Topic, QoS}) when is_binary(Topic), is_atom(QoS) ->
    subscribe(Client, {Topic, ?QOS_I(QoS)});
subscribe(Client, {Topic, QoS}) when is_binary(Topic), ?IS_QOS(QoS) ->
    subscribe(Client, [{Topic, ?QOS_I(QoS)}]);
subscribe(Client, Topics) when is_list(Topics) ->
    subscribe(Client, #{}, lists:map(
                             fun({Topic, QoS}) when is_binary(Topic), is_atom(QoS) ->
                                 {Topic, [{qos, ?QOS_I(QoS)}]};
                                ({Topic, QoS}) when is_binary(Topic), ?IS_QOS(QoS) ->
                                 {Topic, [{qos, ?QOS_I(QoS)}]};
                                ({Topic, Opts}) when is_binary(Topic), is_list(Opts) ->
                                 {Topic, Opts}
                             end, Topics)).

-spec(subscribe(client(), topic(), qos() | qos_name() | [subopt()]) ->
                subscribe_ret();
               (client(), properties(), [{topic(), qos() | [subopt()]}]) ->
                subscribe_ret()).
subscribe(Client, Topic, QoS) when is_binary(Topic), is_atom(QoS) ->
    subscribe(Client, Topic, ?QOS_I(QoS));
subscribe(Client, Topic, QoS) when is_binary(Topic), ?IS_QOS(QoS) ->
    subscribe(Client, Topic, [{qos, QoS}]);
subscribe(Client, Topic, Opts) when is_binary(Topic), is_list(Opts) ->
    subscribe(Client, #{}, [{Topic, Opts}]);
subscribe(Client, Properties, Topics) when is_map(Properties), is_list(Topics) ->
    Topics1 = [{Topic, parse_subopt(Opts)} || {Topic, Opts} <- Topics],
    gen_statem:call(Client, {subscribe, Properties, Topics1}).

-spec(subscribe(client(), properties(), topic(), qos() | qos_name() | [subopt()])
      -> subscribe_ret()).
subscribe(Client, Properties, Topic, QoS)
    when is_map(Properties), is_binary(Topic), is_atom(QoS) ->
    subscribe(Client, Properties, Topic, ?QOS_I(QoS));
subscribe(Client, Properties, Topic, QoS)
    when is_map(Properties), is_binary(Topic), ?IS_QOS(QoS) ->
    subscribe(Client, Properties, Topic, [{qos, QoS}]);
subscribe(Client, Properties, Topic, Opts)
    when is_map(Properties), is_binary(Topic), is_list(Opts) ->
    subscribe(Client, Properties, [{Topic, Opts}]).

parse_subopt(Opts) ->
    parse_subopt(Opts, #{rh => 0, rap => 0, nl => 0, qos => ?QOS_0}).

parse_subopt([], Result) ->
    Result;
parse_subopt([{rh, I} | Opts], Result) when I >= 0, I =< 2 ->
    parse_subopt(Opts, Result#{rh := I});
parse_subopt([{rap, true} | Opts], Result) ->
    parse_subopt(Opts, Result#{rap := 1});
parse_subopt([{rap, false} | Opts], Result) ->
    parse_subopt(Opts, Result#{rap := 0});
parse_subopt([{nl, true} | Opts], Result) ->
    parse_subopt(Opts, Result#{nl := 1});
parse_subopt([{nl, false} | Opts], Result) ->
    parse_subopt(Opts, Result#{nl := 0});
parse_subopt([{qos, QoS} | Opts], Result) ->
    parse_subopt(Opts, Result#{qos := ?QOS_I(QoS)});
parse_subopt([_ | Opts], Result) ->
    parse_subopt(Opts, Result).

-spec(publish(client(), topic(), payload()) -> ok | {error, term()}).
publish(Client, Topic, Payload) when is_binary(Topic) ->
    publish(Client, #mqtt_msg{topic = Topic, qos = ?QOS_0, payload = iolist_to_binary(Payload)}).

-spec(publish(client(), topic(), payload(), qos() | qos_name() | [pubopt()])
        -> ok | {ok, packet_id()} | {error, term()}).
publish(Client, Topic, Payload, QoS) when is_binary(Topic), is_atom(QoS) ->
    publish(Client, Topic, Payload, [{qos, ?QOS_I(QoS)}]);
publish(Client, Topic, Payload, QoS) when is_binary(Topic), ?IS_QOS(QoS) ->
    publish(Client, Topic, Payload, [{qos, QoS}]);
publish(Client, Topic, Payload, Opts) when is_binary(Topic), is_list(Opts) ->
    publish(Client, Topic, #{}, Payload, Opts).

-spec(publish(client(), topic(), properties(), payload(), [pubopt()])
      -> ok | {ok, packet_id()} | {error, term()}).
publish(Client, Topic, Properties, Payload, Opts)
    when is_binary(Topic), is_map(Properties), is_list(Opts) ->
    ok = emqtt_props:validate(Properties),
    Retain = proplists:get_bool(retain, Opts),
    QoS = ?QOS_I(proplists:get_value(qos, Opts, ?QOS_0)),
    publish(Client, #mqtt_msg{qos     = QoS,
                              retain  = Retain,
                              topic   = Topic,
                              props   = Properties,
                              payload = iolist_to_binary(Payload)}).

-spec(publish(client(), #mqtt_msg{}) -> ok | {ok, packet_id()} | {error, term()}).
publish(Client, Msg) ->
    gen_statem:call(Client, {publish, Msg}).

-spec(unsubscribe(client(), topic() | [topic()]) -> subscribe_ret()).
unsubscribe(Client, Topic) when is_binary(Topic) ->
    unsubscribe(Client, [Topic]);
unsubscribe(Client, Topics) when is_list(Topics) ->
    unsubscribe(Client, #{}, Topics).

-spec(unsubscribe(client(), properties(), topic() | [topic()]) -> subscribe_ret()).
unsubscribe(Client, Properties, Topic) when is_map(Properties), is_binary(Topic) ->
    unsubscribe(Client, Properties, [Topic]);
unsubscribe(Client, Properties, Topics) when is_map(Properties), is_list(Topics) ->
    gen_statem:call(Client, {unsubscribe, Properties, Topics}).

-spec(ping(client()) -> pong).
ping(Client) ->
    gen_statem:call(Client, ping).

-spec(disconnect(client()) -> ok).
disconnect(Client) ->
    disconnect(Client, ?RC_SUCCESS).

-spec(disconnect(client(), reason_code()) -> ok).
disconnect(Client, ReasonCode) ->
    disconnect(Client, ReasonCode, #{}).

-spec(disconnect(client(), reason_code(), properties()) -> ok).
disconnect(Client, ReasonCode, Properties) ->
    gen_statem:call(Client, {disconnect, ReasonCode, Properties}).

%%--------------------------------------------------------------------
%% For test cases
%%--------------------------------------------------------------------

puback(Client, PacketId) when is_integer(PacketId) ->
    puback(Client, PacketId, ?RC_SUCCESS).
puback(Client, PacketId, ReasonCode)
    when is_integer(PacketId), is_integer(ReasonCode) ->
    puback(Client, PacketId, ReasonCode, #{}).
puback(Client, PacketId, ReasonCode, Properties)
    when is_integer(PacketId), is_integer(ReasonCode), is_map(Properties) ->
    gen_statem:cast(Client, {puback, PacketId, ReasonCode, Properties}).

pubrec(Client, PacketId) when is_integer(PacketId) ->
    pubrec(Client, PacketId, ?RC_SUCCESS).
pubrec(Client, PacketId, ReasonCode)
    when is_integer(PacketId), is_integer(ReasonCode) ->
    pubrec(Client, PacketId, ReasonCode, #{}).
pubrec(Client, PacketId, ReasonCode, Properties)
    when is_integer(PacketId), is_integer(ReasonCode), is_map(Properties) ->
    gen_statem:cast(Client, {pubrec, PacketId, ReasonCode, Properties}).

pubrel(Client, PacketId) when is_integer(PacketId) ->
    pubrel(Client, PacketId, ?RC_SUCCESS).
pubrel(Client, PacketId, ReasonCode)
    when is_integer(PacketId), is_integer(ReasonCode) ->
    pubrel(Client, PacketId, ReasonCode, #{}).
pubrel(Client, PacketId, ReasonCode, Properties)
    when is_integer(PacketId), is_integer(ReasonCode), is_map(Properties) ->
    gen_statem:cast(Client, {pubrel, PacketId, ReasonCode, Properties}).

pubcomp(Client, PacketId) when is_integer(PacketId) ->
    pubcomp(Client, PacketId, ?RC_SUCCESS).
pubcomp(Client, PacketId, ReasonCode)
    when is_integer(PacketId), is_integer(ReasonCode) ->
    pubcomp(Client, PacketId, ReasonCode, #{}).
pubcomp(Client, PacketId, ReasonCode, Properties)
    when is_integer(PacketId), is_integer(ReasonCode), is_map(Properties) ->
    gen_statem:cast(Client, {pubcomp, PacketId, ReasonCode, Properties}).

subscriptions(Client) ->
    gen_statem:call(Client, subscriptions).

info(Client) ->
    gen_statem:call(Client, info).

stats(Client) ->
    gen_statem:call(Client, stats).

stop(Client) ->
    gen_statem:call(Client, stop).

pause(Client) ->
    gen_statem:call(Client, pause).

resume(Client) ->
    gen_statem:call(Client, resume).

%%--------------------------------------------------------------------
%% gen_statem callbacks
%%--------------------------------------------------------------------

init([Options]) ->
    process_flag(trap_exit, true),
    ClientId = case {proplists:get_value(proto_ver, Options, v4),
                     proplists:get_value(clientid, Options)} of
                   {v5, undefined}   -> ?NO_CLIENT_ID;
                   {_ver, undefined} -> random_client_id();
                   {_ver, Id}        -> iolist_to_binary(Id)
               end,
    State = init(Options, #state{host            = {127,0,0,1},
                                 port            = 1883,
                                 hosts           = [],
                                 conn_mod        = emqtt_sock,
                                 sock_opts       = [],
                                 bridge_mode     = false,
                                 clientid        = ClientId,
                                 clean_start     = true,
                                 proto_ver       = ?MQTT_PROTO_V4,
                                 proto_name      = <<"MQTT">>,
                                 keepalive       = ?DEFAULT_KEEPALIVE,
                                 force_ping      = false,
                                 paused          = false,
                                 will_flag       = false,
                                 will_msg        = #mqtt_msg{},
                                 pending_calls   = [],
                                 subscriptions   = #{},
                                 max_inflight    = infinity,
                                 inflight        = #{},
                                 awaiting_rel    = #{},
                                 properties      = #{},
                                 auto_ack        = true,
                                 ack_timeout     = ?DEFAULT_ACK_TIMEOUT,
                                 retry_interval  = ?DEFAULT_RETRY_INTERVAL,
                                 connect_timeout = ?DEFAULT_CONNECT_TIMEOUT,
                                 last_packet_id  = 1
                                }),
    {ok, initialized, init_parse_state(State)}.

random_client_id() ->
    rand:seed(exsplus, erlang:timestamp()),
    I1 = rand:uniform(round(math:pow(2, 48))) - 1,
    I2 = rand:uniform(round(math:pow(2, 32))) - 1,
    {ok, Host} = inet:gethostname(),
    RandId = io_lib:format("~12.16.0b~8.16.0b", [I1, I2]),
    iolist_to_binary(["emqtt-", Host, "-", RandId]).

init([], State) ->
    State;
init([{name, Name} | Opts], State) ->
    init(Opts, State#state{name = Name});
init([{owner, Owner} | Opts], State) when is_pid(Owner) ->
    link(Owner),
    init(Opts, State#state{owner = Owner});
init([{msg_handler, Hdlr} | Opts], State) ->
    init(Opts, State#state{msg_handler = Hdlr});
init([{host, Host} | Opts], State) ->
    init(Opts, State#state{host = Host});
init([{port, Port} | Opts], State) ->
    init(Opts, State#state{port = Port});
init([{hosts, Hosts} | Opts], State) ->
    Hosts1 =
    lists:foldl(fun({Host, Port}, Acc) ->
                    [{Host, Port}|Acc];
                   (Host, Acc) ->
                    [{Host, 1883}|Acc]
                end, [], Hosts),
    init(Opts, State#state{hosts = Hosts1});
init([{tcp_opts, TcpOpts} | Opts], State = #state{sock_opts = SockOpts}) ->
    init(Opts, State#state{sock_opts = merge_opts(SockOpts, TcpOpts)});
init([{ssl, EnableSsl} | Opts], State) ->
    case lists:keytake(ssl_opts, 1, Opts) of
        {value, SslOpts, WithOutSslOpts} ->
            init([SslOpts, {ssl, EnableSsl}| WithOutSslOpts], State);
        false ->
            init([{ssl_opts, []}, {ssl, EnableSsl}| Opts], State)
    end;
init([{ssl_opts, SslOpts} | Opts], State = #state{sock_opts = SockOpts}) ->
    case lists:keytake(ssl, 1, Opts) of
        {value, {ssl, true}, WithOutEnableSsl} ->
            ok = ssl:start(),
            SockOpts1 = merge_opts(SockOpts, [{ssl_opts, SslOpts}]),
            init(WithOutEnableSsl, State#state{sock_opts = SockOpts1});
        {value, {ssl, false}, WithOutEnableSsl} ->
            init(WithOutEnableSsl, State);
        false ->
            init(Opts, State)
    end;
init([{ws_path, Path} | Opts], State = #state{sock_opts = SockOpts}) ->
    init(Opts, State#state{sock_opts = [{ws_path, Path}|SockOpts]});
init([{clientid, ClientId} | Opts], State) ->
    init(Opts, State#state{clientid = iolist_to_binary(ClientId)});
init([{clean_start, CleanStart} | Opts], State) when is_boolean(CleanStart) ->
    init(Opts, State#state{clean_start = CleanStart});
init([{username, Username} | Opts], State) ->
    init(Opts, State#state{username = iolist_to_binary(Username)});
init([{password, Password} | Opts], State) ->
    init(Opts, State#state{password = iolist_to_binary(Password)});
init([{keepalive, Secs} | Opts], State) ->
    init(Opts, State#state{keepalive = Secs});
init([{proto_ver, v3} | Opts], State) ->
    init(Opts, State#state{proto_ver  = ?MQTT_PROTO_V3,
                           proto_name = <<"MQIsdp">>});
init([{proto_ver, v4} | Opts], State) ->
    init(Opts, State#state{proto_ver  = ?MQTT_PROTO_V4,
                           proto_name = <<"MQTT">>});
init([{proto_ver, v5} | Opts], State) ->
    init(Opts, State#state{proto_ver  = ?MQTT_PROTO_V5,
                           proto_name = <<"MQTT">>});
init([{will_topic, Topic} | Opts], State = #state{will_msg = WillMsg}) ->
    WillMsg1 = init_will_msg({topic, Topic}, WillMsg),
    init(Opts, State#state{will_flag = true, will_msg = WillMsg1});
init([{will_props, Properties} | Opts], State = #state{will_msg = WillMsg}) ->
    init(Opts, State#state{will_msg = init_will_msg({props, Properties}, WillMsg)});
init([{will_payload, Payload} | Opts], State = #state{will_msg = WillMsg}) ->
    init(Opts, State#state{will_msg = init_will_msg({payload, Payload}, WillMsg)});
init([{will_retain, Retain} | Opts], State = #state{will_msg = WillMsg}) ->
    init(Opts, State#state{will_msg = init_will_msg({retain, Retain}, WillMsg)});
init([{will_qos, QoS} | Opts], State = #state{will_msg = WillMsg}) ->
    init(Opts, State#state{will_msg = init_will_msg({qos, QoS}, WillMsg)});
init([{connect_timeout, Timeout}| Opts], State) ->
    init(Opts, State#state{connect_timeout = timer:seconds(Timeout)});
init([{ack_timeout, Timeout}| Opts], State) ->
    init(Opts, State#state{ack_timeout = timer:seconds(Timeout)});
init([force_ping | Opts], State) ->
    init(Opts, State#state{force_ping = true});
init([{force_ping, ForcePing} | Opts], State) when is_boolean(ForcePing) ->
    init(Opts, State#state{force_ping = ForcePing});
init([{properties, Properties} | Opts], State = #state{properties = InitProps}) ->
    init(Opts, State#state{properties = maps:merge(InitProps, Properties)});
init([{max_inflight, infinity} | Opts], State) ->
    init(Opts, State#state{max_inflight = infinity,
                           inflight     = #{}});
init([{max_inflight, I} | Opts], State) when is_integer(I) ->
    init(Opts, State#state{max_inflight = I,
                           inflight     = #{}});
init([auto_ack | Opts], State) ->
    init(Opts, State#state{auto_ack = true});
init([{auto_ack, AutoAck} | Opts], State) when is_boolean(AutoAck) ->
    init(Opts, State#state{auto_ack = AutoAck});
init([{retry_interval, I} | Opts], State) ->
    init(Opts, State#state{retry_interval = timer:seconds(I)});
init([{max_retry_count, N} | Opts], State) when is_integer(N) ->
    put_max_retry_count(N),
    init(Opts, State);
init([{message_delivery_timeout, T} | Opts], State) when is_integer(T) ->
    put_message_delivery_timeout(timer:seconds(T)),
    init(Opts, State);
init([{bridge_mode, Mode} | Opts], State) when is_boolean(Mode) ->
    init(Opts, State#state{bridge_mode = Mode});
init([_Opt | Opts], State) ->
    init(Opts, State).

init_will_msg({topic, Topic}, WillMsg) ->
    WillMsg#mqtt_msg{topic = iolist_to_binary(Topic)};
init_will_msg({props, Props}, WillMsg) ->
    WillMsg#mqtt_msg{props = Props};
init_will_msg({payload, Payload}, WillMsg) ->
    WillMsg#mqtt_msg{payload = iolist_to_binary(Payload)};
init_will_msg({retain, Retain}, WillMsg) when is_boolean(Retain) ->
    WillMsg#mqtt_msg{retain = Retain};
init_will_msg({qos, QoS}, WillMsg) ->
    WillMsg#mqtt_msg{qos = ?QOS_I(QoS)}.

init_parse_state(State = #state{proto_ver = Ver, properties = Properties}) ->
    MaxSize = maps:get('Maximum-Packet-Size', Properties, ?MAX_PACKET_SIZE),
    ParseState = emqtt_frame:initial_parse_state(
                   #{max_size => MaxSize, version => Ver}),
    State#state{parse_state = ParseState}.

merge_opts(Defaults, Options) ->
    lists:foldl(
      fun({Opt, Val}, Acc) ->
          lists:keystore(Opt, 1, Acc, {Opt, Val});
         (Opt, Acc) ->
          lists:usort([Opt | Acc])
      end, Defaults, Options).

callback_mode() -> state_functions.

initialized({call, From}, {connect, ConnMod}, State = #state{sock_opts = SockOpts,
                                                             connect_timeout = Timeout}) ->
    case sock_connect(ConnMod, hosts(State), SockOpts, Timeout) of
        {ok, Sock} ->
            case mqtt_connect(run_sock(State#state{conn_mod = ConnMod, socket = Sock})) of
                {ok, NewState} ->
                    {next_state, waiting_for_connack,
                     add_call(new_call(connect, From), NewState), [Timeout]};
                Error = {error, Reason} ->
                    {stop_and_reply, Reason, [{reply, From, Error}]}
            end;
        Error = {error, Reason} ->
            {stop_and_reply, {shutdown, Reason}, [{reply, From, Error}]}
    end;

initialized(EventType, EventContent, State) ->
    handle_event(EventType, EventContent, initialized, State).

mqtt_connect(State = #state{clientid    = ClientId,
                            clean_start = CleanStart,
                            bridge_mode = IsBridge,
                            username    = Username,
                            password    = Password,
                            proto_ver   = ProtoVer,
                            proto_name  = ProtoName,
                            keepalive   = KeepAlive,
                            will_flag   = WillFlag,
                            will_msg    = WillMsg,
                            properties  = Properties}) ->
    ?WILL_MSG(WillQoS, WillRetain, WillTopic, WillProps, WillPayload) = WillMsg,
    ConnProps = emqtt_props:filter(?CONNECT, Properties),
    send(?CONNECT_PACKET(
            #mqtt_packet_connect{proto_ver    = ProtoVer,
                                 proto_name   = ProtoName,
                                 is_bridge    = IsBridge,
                                 clean_start  = CleanStart,
                                 will_flag    = WillFlag,
                                 will_qos     = WillQoS,
                                 will_retain  = WillRetain,
                                 keepalive    = KeepAlive,
                                 properties   = ConnProps,
                                 clientid     = ClientId,
                                 will_props   = WillProps,
                                 will_topic   = WillTopic,
                                 will_payload = WillPayload,
                                 username     = Username,
                                 password     = Password}), State).

waiting_for_connack(cast, ?CONNACK_PACKET(?RC_SUCCESS,
                                          SessPresent,
                                          Properties),
                    State = #state{properties = AllProps,
                                   clientid   = ClientId}) ->
    case take_call(connect, State) of
        {value, #call{from = From}, State1} ->
            AllProps1 = case Properties of
                            undefined -> AllProps;
                            _ -> maps:merge(AllProps, Properties)
                        end,
            Reply = {ok, Properties},
            State2 = State1#state{clientid = assign_id(ClientId, AllProps1),
                                  properties = AllProps1,
                                  session_present = SessPresent},
            {next_state, connected, ensure_keepalive_timer(State2),
             [{reply, From, Reply}]};
        false ->
            {stop, bad_connack}
    end;

waiting_for_connack(cast, ?CONNACK_PACKET(ReasonCode,
                                          _SessPresent,
                                          Properties),
                    State = #state{proto_ver = ProtoVer}) ->
    Reason = reason_code_name(ReasonCode, ProtoVer),
    case take_call(connect, State) of
        {value, #call{from = From}, _State} ->
            Reply = {error, {Reason, Properties}},
            {stop_and_reply, {shutdown, Reason}, [{reply, From, Reply}]};
        false -> {stop, connack_error}
    end;

waiting_for_connack(timeout, _Timeout, State) ->
    case take_call(connect, State) of
        {value, #call{from = From}, _State} ->
            Reply = {error, connack_timeout},
            {stop_and_reply, connack_timeout, [{reply, From, Reply}]};
        false -> {stop, connack_timeout}
    end;

waiting_for_connack(EventType, EventContent, State) ->
    case take_call(connect, State) of
        {value, #call{from = From}, _State} ->
            case handle_event(EventType, EventContent, waiting_for_connack, State) of
                {stop, Reason, State} ->
                    Reply = {error, {Reason, EventContent}},
                    {stop_and_reply, Reason, [{reply, From, Reply}]};
                StateCallbackResult ->
                    StateCallbackResult
            end;
        false -> {stop, connack_timeout}
    end.

connected({call, From}, subscriptions, #state{subscriptions = Subscriptions}) ->
    {keep_state_and_data, [{reply, From, maps:to_list(Subscriptions)}]};

connected({call, From}, info, State) ->
    Info = lists:zip(record_info(fields, state), tl(tuple_to_list(State))),
    {keep_state_and_data, [{reply, From, Info}]};

connected({call, From}, pause, State) ->
    {keep_state, State#state{paused = true}, [{reply, From, ok}]};

connected({call, From}, resume, State) ->
    {keep_state, State#state{paused = false}, [{reply, From, ok}]};

connected({call, From}, clientid, #state{clientid = ClientId}) ->
    {keep_state_and_data, [{reply, From, ClientId}]};

connected({call, From}, SubReq = {subscribe, Properties, Topics},
          State = #state{last_packet_id = PacketId, subscriptions = Subscriptions}) ->
    case send(?SUBSCRIBE_PACKET(PacketId, Properties, Topics), State) of
        {ok, NewState} ->
            Call = new_call({subscribe, PacketId}, From, SubReq),
            Subscriptions1 =
                lists:foldl(fun({Topic, Opts}, Acc) ->
                                maps:put(Topic, Opts, Acc)
                            end, Subscriptions, Topics),
            {keep_state, ensure_ack_timer(add_call(Call,NewState#state{subscriptions = Subscriptions1}))};
        Error = {error, Reason} ->
            {stop_and_reply, Reason, [{reply, From, Error}]}
    end;

connected({call, From}, {publish, Msg = #mqtt_msg{qos = ?QOS_0}}, State) ->
    case send(Msg, State) of
        {ok, NewState} ->
            {keep_state, NewState, [{reply, From, ok}]};
        Error = {error, Reason} ->
            {stop_and_reply, Reason, [{reply, From, Error}]}
    end;

connected({call, From}, {publish, Msg = #mqtt_msg{qos = QoS}},
          State = #state{inflight = Inflight0, last_packet_id = PacketId})
    when (QoS =:= ?QOS_1); (QoS =:= ?QOS_2) ->
    Inflight = maybe_upgrade_inflight_data_structure(Inflight0),
    Msg1 = Msg#mqtt_msg{packet_id = PacketId},
    case send(Msg1, State) of
        {ok, NewState} ->
            Now = now_ts(),
            Meta = #{first_sent_at => Now, last_sent_at => Now, retry_count => 0},
            Inflight1 = maps:put(PacketId, {publish, Msg1, Meta}, Inflight),
            ensure_delivery_timer(),
            set_inflight_cnt(maps:size(Inflight1)),
            State1 = ensure_retry_timer(NewState#state{inflight = Inflight1}),
            Actions = [{reply, From, {ok, PacketId}}],
            case is_inflight_full(State1) of
                true -> {next_state, inflight_full, State1, Actions};
                false -> {keep_state, State1, Actions}
            end;
        {error, Reason} ->
            {stop_and_reply, Reason, [{reply, From, {error, {PacketId, Reason}}}]}
    end;

connected({call, From}, UnsubReq = {unsubscribe, Properties, Topics},
          State = #state{last_packet_id = PacketId}) ->
    case send(?UNSUBSCRIBE_PACKET(PacketId, Properties, Topics), State) of
        {ok, NewState} ->
            Call = new_call({unsubscribe, PacketId}, From, UnsubReq),
            {keep_state, ensure_ack_timer(add_call(Call, NewState))};
        Error = {error, Reason} ->
            {stop_and_reply, Reason, [{reply, From, Error}]}
    end;

connected({call, From}, ping, State) ->
    case send(?PACKET(?PINGREQ), State) of
        {ok, NewState} ->
            Call = new_call(ping, From),
            {keep_state, ensure_ack_timer(add_call(Call, NewState))};
        Error = {error, Reason} ->
            {stop_and_reply, Reason, [{reply, From, Error}]}
    end;

connected({call, From}, {disconnect, ReasonCode, Properties}, State) ->
    case send(?DISCONNECT_PACKET(ReasonCode, Properties), State) of
        {ok, NewState} ->
            {stop_and_reply, normal, [{reply, From, ok}], NewState};
        Error = {error, Reason} ->
            {stop_and_reply, Reason, [{reply, From, Error}]}
    end;

connected(cast, {puback, PacketId, ReasonCode, Properties}, State) ->
    send_puback(?PUBACK_PACKET(PacketId, ReasonCode, Properties), State);

connected(cast, {pubrec, PacketId, ReasonCode, Properties}, State) ->
    send_puback(?PUBREC_PACKET(PacketId, ReasonCode, Properties), State);

connected(cast, {pubrel, PacketId, ReasonCode, Properties}, State) ->
    send_puback(?PUBREL_PACKET(PacketId, ReasonCode, Properties), State);

connected(cast, {pubcomp, PacketId, ReasonCode, Properties}, State) ->
    send_puback(?PUBCOMP_PACKET(PacketId, ReasonCode, Properties), State);

connected(cast, ?PUBLISH_PACKET(_QoS, _PacketId), #state{paused = true}) ->
    keep_state_and_data;

connected(cast, Packet = ?PUBLISH_PACKET(?QOS_0, _PacketId), State) ->
     {keep_state, deliver(packet_to_msg(Packet), State)};

connected(cast, Packet = ?PUBLISH_PACKET(?QOS_1, _PacketId), State) ->
    publish_process(?QOS_1, Packet, State);

connected(cast, Packet = ?PUBLISH_PACKET(?QOS_2, _PacketId), State) ->
    publish_process(?QOS_2, Packet, State);

connected(cast, ?PUBACK_PACKET(_PacketId, _ReasonCode, _Properties) = PubAck, State) ->
    {keep_state, delete_inflight(PubAck, State)};

connected(cast, ?PUBREC_PACKET(PacketId, _ReasonCode), State = #state{inflight = Inflight0}) ->
    Inflight = maybe_upgrade_inflight_data_structure(Inflight0),
    NState = case maps:find(PacketId, Inflight) of
                 {ok, {publish, _Msg, _Meta}} ->
                     Now = now_ts(),
                     Meta = #{first_sent_at => Now,
                              last_sent_at => Now,
                              retry_count => 0
                             },
                     Inflight1 = maps:put(PacketId, {pubrel, PacketId, Meta}, Inflight),
                     State#state{inflight = Inflight1};
                 {ok, {pubrel, _Ref, _Ts}} ->
                     ?LOG(notice, "Duplicated PUBREC Packet: ~p", [PacketId], State),
                     State;
                 error ->
                     ?LOG(warning, "Unexpected PUBREC Packet: ~p", [PacketId], State),
                     State
        end,
    send_puback(?PUBREL_PACKET(PacketId), NState);

%%TODO::... if auto_ack is false, should we take PacketId from the map?
connected(cast, ?PUBREL_PACKET(PacketId, _ReasonCode),
          State = #state{awaiting_rel = AwaitingRel, auto_ack = AutoAck}) ->
     case maps:take(PacketId, AwaitingRel) of
         {Packet, AwaitingRel1} ->
             NewState = deliver(packet_to_msg(Packet), State#state{awaiting_rel = AwaitingRel1}),
             case AutoAck of
                 true  -> send_puback(?PUBCOMP_PACKET(PacketId), NewState);
                 false -> {keep_state, NewState}
             end;
         error ->
             ?LOG(warning, "Unexpected PUBREL: ~p", [PacketId], State),
             keep_state_and_data
     end;

connected(cast, ?PUBCOMP_PACKET(_PacketId, _ReasonCode, _Properties) = PubComp, State) ->
    {keep_state, delete_inflight(PubComp, State)};

connected(cast, ?SUBACK_PACKET(PacketId, Properties, ReasonCodes),
          State = #state{subscriptions = _Subscriptions}) ->
    case take_call({subscribe, PacketId}, State) of
        {value, #call{from = From}, NewState} ->
            %%TODO: Merge reason codes to subscriptions?
            Reply = {ok, Properties, ReasonCodes},
            {keep_state, NewState, [{reply, From, Reply}]};
        false ->
            keep_state_and_data
    end;

connected(cast, ?UNSUBACK_PACKET(PacketId, Properties, ReasonCodes),
          State = #state{subscriptions = Subscriptions}) ->
    case take_call({unsubscribe, PacketId}, State) of
        {value, #call{from = From, req = {_, _, Topics}}, NewState} ->
            Subscriptions1 =
              lists:foldl(fun(Topic, Acc) ->
                              maps:remove(Topic, Acc)
                          end, Subscriptions, Topics),
            {keep_state, NewState#state{subscriptions = Subscriptions1},
             [{reply, From, {ok, Properties, ReasonCodes}}]};
        false ->
            keep_state_and_data
    end;

connected(cast, ?PACKET(?PINGRESP), #state{pending_calls = []}) ->
    keep_state_and_data;
connected(cast, ?PACKET(?PINGRESP), State) ->
    case take_call(ping, State) of
        {value, #call{from = From}, NewState} ->
            {keep_state, NewState, [{reply, From, pong}]};
        false ->
            keep_state_and_data
    end;

connected(cast, ?DISCONNECT_PACKET(ReasonCode, Properties), State) ->
    {stop, {disconnected, ReasonCode, Properties}, State};

connected(info, {timeout, _TRef, keepalive}, State = #state{force_ping = true}) ->
    case send(?PACKET(?PINGREQ), State) of
        {ok, NewState} ->
            {keep_state, ensure_keepalive_timer(NewState)};
        Error -> {stop, Error}
    end;

connected(info, {timeout, TRef, keepalive},
          State = #state{conn_mod = ConnMod, socket = Sock,
                         paused = Paused, keepalive_timer = TRef}) ->
    case (not Paused) andalso should_ping(ConnMod, Sock) of
        true ->
            case send(?PACKET(?PINGREQ), State) of
                {ok, NewState} ->
                    {ok, [{send_oct, Val}]} = ConnMod:getstat(Sock, [send_oct]),
                    put(send_oct, Val),
                    {keep_state, ensure_keepalive_timer(NewState), [hibernate]};
                Error -> {stop, Error}
            end;
        false ->
            {keep_state, ensure_keepalive_timer(State), [hibernate]};
        {error, Reason} ->
            {stop, Reason}
    end;

connected(info, {timeout, TRef, ack}, State = #state{ack_timer     = TRef,
                                                     ack_timeout   = Timeout,
                                                     pending_calls = Calls}) ->
    NewState = State#state{ack_timer = undefined,
                           pending_calls = timeout_calls(Timeout, Calls)},
    {keep_state, ensure_ack_timer(NewState)};

connected(info, {timeout, TRef, retry}, State = #state{retry_timer = TRef,
                                                       inflight    = Inflight0}) ->
    Inflight = maybe_upgrade_inflight_data_structure(Inflight0),
    case maps:size(Inflight) == 0 of
        true  -> {keep_state, State#state{retry_timer = undefined}};
        false -> retry_send(State#state{retry_timer = undefined})
    end;

connected(info, {timeout, _TRef, delivery_timeout}, State = #state{inflight = Inflight}) ->
    clean_delivery_timer(),
    case maps:size(Inflight) == 0 of
        true  ->
            {keep_state, State};
        false ->
            State1 = expiry_inflight_msgs(now_ts(), State),
            ensure_delivery_timer(),
            {keep_state, State1}
    end;

connected(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, connected, Data).

inflight_full({call, _From}, {publish, #mqtt_msg{qos = QoS}}, _State) when (QoS =:= ?QOS_1); (QoS =:= ?QOS_2) ->
    {keep_state_and_data, [postpone]};
inflight_full(cast, ?PUBACK_PACKET(_PacketId, _ReasonCode, _Properties) = PubAck, State) ->
    delete_inflight_when_full(PubAck, State);
inflight_full(cast, ?PUBCOMP_PACKET(_PacketId, _ReasonCode, _Properties) = PubComp, State) ->
    delete_inflight_when_full(PubComp, State);
inflight_full(EventType, EventContent, Data) ->
    %% inflight_full is a sub-state of connected state,
    %% delegate all other events to connected state.
    connected(EventType, EventContent, Data).

handle_event({call, From}, stop, _StateName, _State) ->
    {stop_and_reply, normal, [{reply, From, ok}]};

handle_event({call, From}, stats, _StateName, _State) ->
    {keep_state_and_data, [{reply, From, collect_stats()}]};

handle_event(info, {gun_ws, ConnPid, _StreamRef, {binary, Data}},
             _StateName, State = #state{socket = ConnPid}) ->
    ?LOG(debug, "RECV Data: ~p", [Data], State),
    process_incoming(iolist_to_binary(Data), [], State);

handle_event(info, {gun_down, ConnPid, _, Reason, _, _},
             _StateName, State = #state{socket = ConnPid}) ->
    ?LOG(debug, "WebSocket down! Reason: ~p", [Reason], State),
    {stop, Reason, State};

handle_event(info, {TcpOrSsL, _Sock, Data}, _StateName, State)
    when TcpOrSsL =:= tcp; TcpOrSsL =:= ssl ->
    ?LOG(debug, "RECV Data: ~p", [Data], State),
    process_incoming(Data, [], run_sock(State));

handle_event(info, {Error, _Sock, Reason}, _StateName, State)
    when Error =:= tcp_error; Error =:= ssl_error ->
    ?LOG(error, "The connection error occured ~p, reason:~p",
    [Error, Reason], State),
    {stop, {shutdown, Reason}, State};

handle_event(info, {Closed, _Sock}, _StateName, State)
    when Closed =:= tcp_closed; Closed =:= ssl_closed ->
    ?LOG(debug, "~p", [Closed], State),
    {stop, {shutdown, Closed}, State};

handle_event(info, {'EXIT', Owner, Reason}, _, State = #state{owner = Owner}) ->
    ?LOG(debug, "Got EXIT from owner, Reason: ~p", [Reason], State),
    {stop, {shutdown, Reason}, State};

handle_event(info, {inet_reply, _Sock, ok}, _, _State) ->
    keep_state_and_data;

handle_event(info, {inet_reply, _Sock, {error, Reason}}, _, State) ->
    ?LOG(error, "Got tcp error: ~p", [Reason], State),
    {stop, {shutdown, Reason}, State};

handle_event(info, EventContent = {'EXIT', _Pid, normal}, StateName, State) ->
    ?LOG(info, "State: ~s, Unexpected Event: (info, ~p)",
         [StateName, EventContent], State),
    keep_state_and_data;

handle_event(EventType, EventContent, StateName, State) ->
    ?LOG(error, "State: ~s, Unexpected Event: (~p, ~p)",
         [StateName, EventType, EventContent], State),
    keep_state_and_data.

%% Mandatory callback functions
terminate(Reason, _StateName, State = #state{conn_mod = ConnMod, socket = Socket}) ->
    case Reason of
        {disconnected, ReasonCode, Properties} ->
            %% backward compatible
            ok = eval_msg_handler(State, disconnected, {ReasonCode, Properties});
        _ ->
            ok = eval_msg_handler(State, disconnected, Reason)
    end,
    case Socket =:= undefined of
        true -> ok;
        _ -> ConnMod:close(Socket)
    end.

code_change(_Vsn, State, Data, _Extra) ->
    {ok, State, Data}.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

should_ping(ConnMod, Sock) ->
    case ConnMod:getstat(Sock, [send_oct]) of
        {ok, [{send_oct, Val}]} ->
            OldVal = get(send_oct), put(send_oct, Val),
            OldVal == undefined orelse OldVal == Val;
        Error = {error, _Reason} ->
            Error
    end.

%% Since in 1.2.3.3 to 1.2.3.4 upgrade, we modified the data structure stored in the inflight.
%% We need to execute the following func to upgrade the data structure for the code hot upgrading.
maybe_upgrade_inflight_data_structure(Inflight) ->
    Iter = maps:iterator(Inflight),
    case maps:next(Iter) of
        none ->
            Inflight;
        {_Key, {_Type, _Msg, Meta}, _Iter1} when is_map(Meta) ->
            Inflight;
        {_, {_, _, OsTimestamp}, _Iter1} when is_tuple(OsTimestamp) ->
            maps:map(
                fun(_Key, {Type, Msg, Ts}) ->
                    Ms = timestamp_to_ms(Ts),
                    Meta = #{first_sent_at => Ms,
                             last_sent_at  => Ms,
                             retry_count   => 0
                            },
                    {Type, Msg, Meta}
                end, Iter)
    end.

is_inflight_full(#state{max_inflight = infinity}) ->
    false;
is_inflight_full(#state{max_inflight = MaxLimit, inflight = Inflight}) ->
    maps:size(Inflight) >= MaxLimit.

delete_inflight(?PUBACK_PACKET(PacketId, ReasonCode, Properties),
                State = #state{inflight = Inflight}) ->
    case maps:find(PacketId, Inflight) of
        {ok, {publish, #mqtt_msg{packet_id = PacketId}, _Meta}} ->
            ok = eval_msg_handler(State, puback, #{packet_id   => PacketId,
                                                   reason_code => ReasonCode,
                                                   properties  => Properties}),
            Inflight1 = maps:remove(PacketId, Inflight),
            set_inflight_cnt(maps:size(Inflight1)),
            State#state{inflight = Inflight1};
        error ->
            ?LOG(warning, "Unexpected PUBACK: ~p", [PacketId], State),
            State
    end;
delete_inflight(?PUBCOMP_PACKET(PacketId, ReasonCode, Properties),
                State = #state{inflight = Inflight}) ->
    case maps:find(PacketId, Inflight) of
        {ok, {pubrel, _PacketId, _Meta}} ->
            ok = eval_msg_handler(State, puback, #{packet_id   => PacketId,
                                                   reason_code => ReasonCode,
                                                   properties  => Properties}),
            Inflight1 = maps:remove(PacketId, Inflight),
            set_inflight_cnt(maps:size(Inflight1)),
            State#state{inflight = Inflight1};
        error ->
            ?LOG(warning, "Unexpected PUBCOMP Packet: ~p", [PacketId], State),
            State
     end.

delete_inflight_when_full(Packet, State) ->
    State1 = delete_inflight(Packet, State),
    case is_inflight_full(State1) of
        true -> {keep_state, State1};
        false -> {next_state, connected, State1}
    end.

expiry_inflight_msgs(Now, State = #state{inflight = Inflight}) ->
    Fun = fun(PacketId, {Type, Msg, Meta}, Acc) ->
              SentAt = maps:get(first_sent_at, Meta),
              ExpiryTime = get_message_delivery_timeout(),
              case Now - SentAt of
                  Diff when Diff >= ExpiryTime ->
                      Acc#{PacketId => {Type, Msg, Meta}};
                  _ ->
                      Acc
              end
          end,
    ExpiredMsgs = maps:fold(Fun, Inflight, #{}),
    case maps:size(ExpiredMsgs) of
        0 -> State;
        _ ->
            ExpiredMsgs1 = lists:sort(
                fun({_, {_, _, #{last_sent_at := Ts1}}}, {_, {_, _, #{last_sent_at := Ts2}}}) ->
                    Ts1 < Ts2
                end, maps:to_list(ExpiredMsgs)
            ),
            delete_expired_inflight_msgs(ExpiredMsgs1, State)
    end.

delete_expired_inflight_msgs([], State) ->
    State;
delete_expired_inflight_msgs(
  [{PacketId, {Type, Msg, _Meta}} | Msgs],
  State = #state{inflight = Inflight}
) ->
    case Type of
        publish ->
            #mqtt_msg{topic = Topic} = Msg,
            ?LOG(warning, "Message ~p expired, topic: ~ts", [PacketId, Topic], State);
        pubrel ->
            ?LOG(warning, "Pubrel ~p expired", [PacketId], State)
    end,
    ok = eval_msg_handler(State, puback, #{packet_id   => PacketId,
                                           %% Treat 16#FF as internal error
                                           reason_code => 16#FF,
                                           reason_code_name => expired,
                                           properties  => #{}}),
    inc_delivery_timeout(),
    Inflight1 = maps:remove(PacketId, Inflight),
    set_inflight_cnt(maps:size(Inflight1)),
    State1 = State#state{inflight = Inflight1},
    delete_expired_inflight_msgs(Msgs, State1).

assign_id(?NO_CLIENT_ID, Props) ->
    case maps:find('Assigned-Client-Identifier', Props) of
        {ok, Value} ->
            Value;
        _ ->
            error(bad_client_id)
    end;
assign_id(Id, _Props) ->
    Id.

publish_process(?QOS_1, Packet = ?PUBLISH_PACKET(?QOS_1, PacketId),
                State0 = #state{auto_ack = AutoAck}) ->
    State = deliver(packet_to_msg(Packet), State0),
    case AutoAck of
        true  -> send_puback(?PUBACK_PACKET(PacketId), State);
        false -> {keep_state, State}
    end;
publish_process(?QOS_2, Packet = ?PUBLISH_PACKET(?QOS_2, PacketId),
    State = #state{awaiting_rel = AwaitingRel}) ->
    case send_puback(?PUBREC_PACKET(PacketId), State) of
        {keep_state, NewState} ->
            AwaitingRel1 = maps:put(PacketId, Packet, AwaitingRel),
            {keep_state, NewState#state{awaiting_rel = AwaitingRel1}};
        Stop -> Stop
    end.

ensure_keepalive_timer(State = ?PROPERTY('Server-Keep-Alive', Secs)) ->
    ensure_keepalive_timer(timer:seconds(Secs), State#state{keepalive = Secs});
ensure_keepalive_timer(State = #state{keepalive = 0}) ->
    State;
ensure_keepalive_timer(State = #state{keepalive = I}) ->
    ensure_keepalive_timer(timer:seconds(I), State).
ensure_keepalive_timer(I, State) when is_integer(I) ->
    State#state{keepalive_timer = erlang:start_timer(I, self(), keepalive)}.

new_call(Id, From) ->
    new_call(Id, From, undefined).
new_call(Id, From, Req) ->
    #call{id = Id, from = From, req = Req, ts = os:timestamp()}.

add_call(Call, Data = #state{pending_calls = Calls}) ->
    Data#state{pending_calls = [Call | Calls]}.

take_call(Id, Data = #state{pending_calls = Calls}) ->
    case lists:keytake(Id, #call.id, Calls) of
        {value, Call, Left} ->
            {value, Call, Data#state{pending_calls = Left}};
        false -> false
    end.

timeout_calls(Timeout, Calls) ->
    timeout_calls(os:timestamp(), Timeout, Calls).
timeout_calls(Now, Timeout, Calls) ->
    lists:foldl(fun(C = #call{from = From, ts = Ts}, Acc) ->
                    case (timer:now_diff(Now, Ts) div 1000) >= Timeout of
                        true  ->
                            gen_statem:reply(From, {error, ack_timeout}),
                            Acc;
                        false -> [C | Acc]
                    end
                end, [], Calls).

ensure_ack_timer(State = #state{ack_timer     = undefined,
                                ack_timeout   = Timeout,
                                pending_calls = Calls}) when length(Calls) > 0 ->
    State#state{ack_timer = erlang:start_timer(Timeout, self(), ack)};
ensure_ack_timer(State) -> State.

ensure_retry_timer(State = #state{retry_interval = Interval}) ->
    do_ensure_retry_timer(Interval, State).

do_ensure_retry_timer(Interval, State = #state{retry_timer = undefined})
    when Interval > 0 ->
    State#state{retry_timer = erlang:start_timer(Interval, self(), retry)};
do_ensure_retry_timer(_Interval, State) ->
    State.

retry_send(State = #state{inflight = Inflight}) ->
    SortFun = fun({_, _, #{last_sent_at := Ts1}}, {_, _, #{last_sent_at := Ts2}}) -> Ts1 < Ts2 end,
    Msgs = lists:sort(SortFun, maps:values(Inflight)),
    retry_send(Msgs, now_ts(), State).

retry_send([], _Now, State) ->
    {keep_state, ensure_retry_timer(State)};
retry_send([{Type, Msg, Meta} | Msgs], Now, State = #state{retry_interval = Interval}) ->
    Ts = maps:get(last_sent_at, Meta),
    Tried = maps:get(retry_count, Meta),
    Diff = Now - Ts,
    case {Tried >= get_max_retry_count(), (Diff >= Interval)} of
        {true, _} ->
            retry_send(Msgs, Now, State);
        {false, true} -> case retry_send(Type, Msg, Meta, Now, State) of
                     {ok, NewState} -> retry_send(Msgs, Now, NewState);
                     {error, Error} -> {stop, Error}
                 end;
        {false, false} -> {keep_state, do_ensure_retry_timer(Interval - Diff, State)}
    end.

retry_send(publish, Msg = #mqtt_msg{qos = QoS, packet_id = PacketId},
           Meta, Now, State = #state{inflight = Inflight}) ->
    Msg1 = Msg#mqtt_msg{dup = (QoS =:= ?QOS_1)},
    case send(Msg1, State) of
        {ok, NewState} ->
            RetryCount = maps:get(retry_count, Meta),
            Meta1 = Meta#{last_sent_at => Now, retry_count => RetryCount + 1},
            Inflight1 = maps:put(PacketId, {publish, Msg1, Meta1}, Inflight),
            {ok, NewState#state{inflight = Inflight1}};
        Error = {error, _Reason} ->
            Error
    end;
retry_send(pubrel, PacketId, Meta, Now, State = #state{inflight = Inflight}) ->
    case send(?PUBREL_PACKET(PacketId), State) of
        {ok, NewState} ->
            RetryCount = maps:get(retry_count, Meta),
            Meta1 = Meta#{last_sent_at => Now, retry_count => RetryCount + 1},
            Inflight1 = maps:put(PacketId, {pubrel, PacketId, Meta1}, Inflight),
            {ok, NewState#state{inflight = Inflight1}};
        Error = {error, _Reason} ->
            Error
    end.

deliver(#mqtt_msg{qos = QoS, dup = Dup, retain = Retain, packet_id = PacketId,
                  topic = Topic, props = Props, payload = Payload},
        State) ->
    Msg = #{qos => QoS, dup => Dup, retain => Retain, packet_id => PacketId,
            topic => Topic, properties => Props, payload => Payload,
            client_pid => self()},
    ok = eval_msg_handler(State, publish, Msg),
    State.

now_ts() ->
    erlang:system_time(millisecond).

timestamp_to_ms(Ts) ->
    timer:now_diff(Ts, {0, 0, 0}) div 1000.

eval_msg_handler(#state{msg_handler = ?NO_MSG_HDLR,
                        owner = Owner},
                 disconnected, {ReasonCode, Properties}) when is_integer(ReasonCode) ->
    %% Special handling for disconnected message when there is no handler callback
    Owner ! {disconnected, ReasonCode, Properties},
    ok;
eval_msg_handler(#state{msg_handler = ?NO_MSG_HDLR},
                 disconnected, _OtherReason) ->
    %% do nothing to be backward compatible
    ok;
eval_msg_handler(#state{msg_handler = ?NO_MSG_HDLR,
                        owner = Owner}, Kind, Msg) ->
    Owner ! {Kind, Msg},
    ok;
eval_msg_handler(#state{msg_handler = Handler}, Kind, Msg) ->
    F = maps:get(Kind, Handler),
    _ = apply_handler_function(F, Msg),
    ok.

apply_handler_function(F, Msg)
  when is_function(F) ->
    erlang:apply(F, [Msg]);
apply_handler_function({F, A}, Msg)
  when is_function(F),
       is_list(A) ->
    erlang:apply(F, [Msg] ++ A);
apply_handler_function({M, F, A}, Msg)
  when is_atom(M),
       is_atom(F),
       is_list(A) ->
    erlang:apply(M, F, [Msg] ++ A).

packet_to_msg(#mqtt_packet{header   = #mqtt_packet_header{type   = ?PUBLISH,
                                                          dup    = Dup,
                                                          qos    = QoS,
                                                          retain = R},
                           variable = #mqtt_packet_publish{topic_name = Topic,
                                                           packet_id  = PacketId,
                                                           properties = Props},
                           payload  = Payload}) ->
    #mqtt_msg{qos = QoS, retain = R, dup = Dup, packet_id = PacketId,
               topic = Topic, props = Props, payload = Payload}.

msg_to_packet(#mqtt_msg{qos = QoS, dup = Dup, retain = Retain, packet_id = PacketId,
                       topic = Topic, props = Props, payload = Payload}) ->
    #mqtt_packet{header   = #mqtt_packet_header{type   = ?PUBLISH,
                                                qos    = QoS,
                                                retain = Retain,
                                                dup    = Dup},
                 variable = #mqtt_packet_publish{topic_name = Topic,
                                                 packet_id  = PacketId,
                                                 properties = Props},
                 payload  = Payload}.

%%--------------------------------------------------------------------
%% Socket Connect/Send

sock_connect(ConnMod, Hosts, SockOpts, Timeout) ->
    sock_connect(ConnMod, Hosts, SockOpts, Timeout, {error, no_hosts}).

sock_connect(_ConnMod, [], _SockOpts, _Timeout, LastErr) ->
    LastErr;
sock_connect(ConnMod, [{Host, Port} | Hosts], SockOpts, Timeout, _LastErr) ->
    case ConnMod:connect(Host, Port, SockOpts, Timeout) of
        {ok, SockOrPid} ->
            {ok, SockOrPid};
        Error = {error, _Reason} ->
            sock_connect(ConnMod, Hosts, SockOpts, Timeout, Error)
    end.

hosts(#state{hosts = [], host = Host, port = Port}) ->
    [{Host, Port}];
hosts(#state{hosts = Hosts}) -> Hosts.

send_puback(Packet, State) ->
    case send(Packet, State) of
        {ok, NewState}  -> {keep_state, NewState};
        {error, Reason} -> {stop, {shutdown, Reason}}
    end.

send(Msg, State) when is_record(Msg, mqtt_msg) ->
    send(msg_to_packet(Msg), State);

send(Packet, State = #state{conn_mod = ConnMod, socket = Sock, proto_ver = Ver})
    when is_record(Packet, mqtt_packet) ->
    Data = emqtt_frame:serialize(Packet, Ver),
    ?LOG(debug, "SEND Data: ~1000p", [Packet], State),
    case ConnMod:send(Sock, Data) of
        ok  -> {ok, bump_last_packet_id(State)};
        Error -> Error
    end.

run_sock(State = #state{conn_mod = ConnMod, socket = Sock}) ->
    ConnMod:setopts(Sock, [{active, once}]), State.

%%--------------------------------------------------------------------
%% Process incomming

process_incoming(<<>>, Packets, State) ->
    {keep_state, State, next_events(Packets)};

process_incoming(Bytes, Packets, State = #state{parse_state = ParseState}) ->
    try emqtt_frame:parse(Bytes, ParseState) of
        {ok, Packet, Rest, NParseState} ->
            process_incoming(Rest, [Packet|Packets], State#state{parse_state = NParseState});
        {more, NParseState} ->
            {keep_state, State#state{parse_state = NParseState}, next_events(Packets)}
    catch
        error:Error:Stacktrace -> {stop, {Error, Stacktrace}}
    end.

-compile({inline, [next_events/1]}).
next_events([]) -> [];
next_events([Packet]) ->
    {next_event, cast, Packet};
next_events(Packets) ->
    [{next_event, cast, Packet} || Packet <- lists:reverse(Packets)].

%%--------------------------------------------------------------------
%% packet_id generation

bump_last_packet_id(State = #state{last_packet_id = Id}) ->
    State#state{last_packet_id = next_packet_id(Id)}.

-spec next_packet_id(packet_id()) -> packet_id().
next_packet_id(?MAX_PACKET_ID) -> 1;
next_packet_id(Id) -> Id + 1.

%%--------------------------------------------------------------------
%% ReasonCode Name

reason_code_name(I, Ver) when Ver >= ?MQTT_PROTO_V5 ->
    reason_code_name(I);
reason_code_name(0, _Ver) -> connection_accepted;
reason_code_name(1, _Ver) -> unacceptable_protocol_version;
reason_code_name(2, _Ver) -> client_identifier_not_valid;
reason_code_name(3, _Ver) -> server_unavaliable;
reason_code_name(4, _Ver) -> malformed_username_or_password;
reason_code_name(5, _Ver) -> unauthorized_client;
reason_code_name(_, _Ver) -> unknown_error.

reason_code_name(16#00) -> success;
reason_code_name(16#01) -> granted_qos1;
reason_code_name(16#02) -> granted_qos2;
reason_code_name(16#04) -> disconnect_with_will_message;
reason_code_name(16#10) -> no_matching_subscribers;
reason_code_name(16#11) -> no_subscription_existed;
reason_code_name(16#18) -> continue_authentication;
reason_code_name(16#19) -> re_authenticate;
reason_code_name(16#80) -> unspecified_error;
reason_code_name(16#81) -> malformed_Packet;
reason_code_name(16#82) -> protocol_error;
reason_code_name(16#83) -> implementation_specific_error;
reason_code_name(16#84) -> unsupported_protocol_version;
reason_code_name(16#85) -> client_identifier_not_valid;
reason_code_name(16#86) -> bad_username_or_password;
reason_code_name(16#87) -> not_authorized;
reason_code_name(16#88) -> server_unavailable;
reason_code_name(16#89) -> server_busy;
reason_code_name(16#8A) -> banned;
reason_code_name(16#8B) -> server_shutting_down;
reason_code_name(16#8C) -> bad_authentication_method;
reason_code_name(16#8D) -> keepalive_timeout;
reason_code_name(16#8E) -> session_taken_over;
reason_code_name(16#8F) -> topic_filter_invalid;
reason_code_name(16#90) -> topic_name_invalid;
reason_code_name(16#91) -> packet_identifier_inuse;
reason_code_name(16#92) -> packet_identifier_not_found;
reason_code_name(16#93) -> receive_maximum_exceeded;
reason_code_name(16#94) -> topic_alias_invalid;
reason_code_name(16#95) -> packet_too_large;
reason_code_name(16#96) -> message_rate_too_high;
reason_code_name(16#97) -> quota_exceeded;
reason_code_name(16#98) -> administrative_action;
reason_code_name(16#99) -> payload_format_invalid;
reason_code_name(16#9A) -> retain_not_supported;
reason_code_name(16#9B) -> qos_not_supported;
reason_code_name(16#9C) -> use_another_server;
reason_code_name(16#9D) -> server_moved;
reason_code_name(16#9E) -> shared_subscriptions_not_supported;
reason_code_name(16#9F) -> connection_rate_exceeded;
reason_code_name(16#A0) -> maximum_connect_time;
reason_code_name(16#A1) -> subscription_identifiers_not_supported;
reason_code_name(16#A2) -> wildcard_subscriptions_not_supported;
reason_code_name(_Code) -> unknown_error.

%%--------------------------------------------------------------------
%% Process Dictionary

%% Added for 1.2.3.4
%%
%% Due to compatibility issues, we can't directly modify the structure of the state to store
%% these newly added configurations. So we put `max_retry_count` and `message_delivery_timeout`
%% into the process dictionary temporarily.
put_max_retry_count(N) when is_integer(N) ->
    erlang:put(max_retry_count, N).

get_max_retry_count() ->
    Default = 3,
    case erlang:get(max_retry_count) of
        undefined -> Default;
        Value     -> Value
    end.

put_message_delivery_timeout(T) when is_integer(T) ->
    erlang:put(message_delivery_timeout, T).

get_message_delivery_timeout() ->
    Default = timer:seconds(30),
    case erlang:get(message_delivery_timeout) of
        undefined -> Default;
        Value     -> Value
    end.

ensure_delivery_timer() ->
    Interval = get_message_delivery_timeout() + 1000,
    case erlang:get(delivery_timer) of
        undefined ->
            TRef = erlang:start_timer(Interval, self(), delivery_timeout),
            erlang:put(delivery_timer, TRef);
        _TRef ->
            ok
    end.

clean_delivery_timer() ->
    case erlang:get(delivery_timer) of
        undefined -> ok;
        TRef ->
            erlang:cancel_timer(TRef),
            erlang:erase(delivery_timer)
    end.

collect_stats() ->
    #{delivery_timeout => get_stats_delivery_timeout(),
      inflight_cnt => get_inflight_cnt()
     }.

get_stats_delivery_timeout() ->
    case erlang:get(delivery_timeout) of
        undefined -> 0;
        Value -> Value
    end.

inc_delivery_timeout() ->
    erlang:put(delivery_timeout, get_stats_delivery_timeout() + 1).

set_inflight_cnt(Count) when is_integer(Count) ->
    erlang:put(inflight_cnt, Count).

get_inflight_cnt() ->
    case erlang:get(inflight_cnt) of
        undefined -> 0;
        Value -> Value
    end.

%%-------------------------------------------------------------------------
%% Copyright (c) 2020-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
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
%%-------------------------------------------------------------------------

-module(emqtt).

-behaviour(gen_statem).

-include("emqtt.hrl").
-include("logger.hrl").
-include("emqtt_internal.hrl").

-export([ start_link/0
        , start_link/1
        ]).

-export([ connect/1
        , ws_connect/1
        , quic_connect/1
        , open_quic_connection/1
        , quic_mqtt_connect/1
        , start_data_stream/2
        , disconnect/1
        , disconnect/2
        , disconnect/3
        ]).

-export([status/1, ping/1]).

%% PubSub
-export([ subscribe/2
        , subscribe/3
        , subscribe/4
        , subscribe_via/4
        , publish/2
        , publish/3
        , publish/4
        , publish/5

        , publish_via/3
        , publish_via/6

        , unsubscribe/2
        , unsubscribe/3
        , unsubscribe_via/3
        , unsubscribe_via/4
        ]).

-export([ publish_async/4
        , publish_async/5
        , publish_async/6
        , publish_async/7
        , publish_async/8
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

-export([info/1, info/2, stop/1]).

%% For test cases
-export([ pause/1
        , resume/1
        ]).

-export([ initialized/3
        , waiting_for_connack/3
        , connected/3
        , reconnect/3
        , random_client_id/0
        , reason_code_name/1
        ]).

-export([ init/1
        , callback_mode/0
        , handle_event/4
        , terminate/3
        , code_change/4
        ]).

%% export for internal calls
-export([sync_publish_result/3]).

-ifdef(UPGRADE_TEST_CHEAT).
-export([format_status/2]).
-endif.

-export_type([ host/0
             , option/0
             , properties/0
             , payload/0
             , pubopt/0
             , subopt/0
             , mqtt_msg/0
             , client/0
             , via/0
             , qos/0
             , packet_id/0
             , topic/0
             ]).

-type(binary_host() :: binary()).
-type(host() :: inet:ip_address() | inet:hostname() | binary_host()).

-define(NO_HANDLER, undefined).
-define(socket_reconnecting, socket_reconnecting).

-type(mfas() :: {module(), atom(), list()} | {function(), list()}).

%% Message handler is a set of callbacks defined to handle MQTT messages
%% as well as the disconnect event.
-type(msg_handler() :: #{publish => fun((_Publish :: map()) -> any()) | mfas(),
                         pubrel => fun((_PubRel :: map()) -> any()) | mfas(),
                         connected => fun((_Properties :: term()) -> any()) | mfas(),
                         disconnected => fun(({reason_code(), _Properties :: term()}) -> any()) | mfas()
                        }).

-type(option() :: {name, atom()}
                | {owner, pid()}
                | {msg_handler, msg_handler()}
                | {host, host()}
                | {hosts, [{host(), inet:port_number()}]}
                | {port, inet:port_number()}
                | {tcp_opts, [gen_tcp:option()]}
                | {ssl, boolean()}
                | {ssl_opts, [ssl:tls_client_option()]}
                | {quic_opts, {_, _}}
                | {ws_path, string()}
                | {connect_timeout, pos_integer()}
                | {bridge_mode, boolean()}
                | {clientid, iodata()}
                | {clean_start, boolean()}
                | {username, iodata()}
                | {password, iodata() | emqtt_secret:t(binary())}
                | {proto_ver, v3 | v4 | v5}
                | {keepalive, non_neg_integer()}
                | {max_inflight, pos_integer()}
                | {retry_interval, timeout()}
                | {will_topic, iodata()}
                | {will_payload, iodata()}
                | {will_retain, boolean()}
                | {will_qos, qos()}
                | {will_props, properties()}
                | {auto_ack, boolean() | never}
                | {ack_timeout, pos_integer()}
                | {force_ping, boolean()}
                | {low_mem, boolean()}
                | {reconnect, reconnect()}
                | {reconnect_timeout, pos_integer()}
                | {with_qoe_metrics, boolean()}
                | {properties, properties()}
                | {nst,  binary()} %% @deprecated 1.13.1
                | {custom_auth_callbacks, custom_auth_callbacks()}).

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

-type(conn_mod() :: emqtt_sock | emqtt_ws | emqtt_quic).

-type(client() :: pid() | atom()).

-type(custom_auth_state() :: term()).
-type(custom_auth_handle_fn() ::
        fun((custom_auth_state(), _Reason :: atom(), properties()) ->
              {continue, _OutAuthPacket, custom_auth_state()}
            | {stop, _Reason :: term()})).
-type(custom_auth_callbacks() :: #{
    init := fun(() -> custom_auth_state()) | {function(), list()},
    handle_auth := custom_auth_handle_fn()
}).

%% 'Via' field add ability of multi stream support for QUIC transport
%% For TCP based, always try use 'default'
-type via() :: default                                         % via default socket
               | {new_data_stream, quicer:stream_opts()}       % Create and use new long living data stream
               | {new_req_stream, quicer:stream_opts()}        % @TODO create and use short lived req stream
               | {logic_stream_id, non_neg_integer(), quicer:stream_opts()}
               | inet:socket() | emqtt_quic:quic_sock()
               | ?socket_reconnecting.

-opaque(mqtt_msg() :: #mqtt_msg{}).

-type reconnect() :: infinity | non_neg_integer().
-type tref() :: reference().

-record(state, {
          name            :: atom(),
          owner           :: undefined | pid(),
          msg_handler     :: ?NO_HANDLER | msg_handler(),
          host            :: host(),
          port            :: inet:port_number(),
          hosts           :: [{host(), inet:port_number()}],
          conn_mod        :: conn_mod(),
          socket          :: undefined
                           | ssl:sslsocket()
                           | inet:socket()
                           | emqx_ws:connection()
                           | emqtt_quic:quic_sock(),
          sock_opts       :: [emqtt_sock:option()|emqtt_ws:option()],
          connect_timeout :: pos_integer(),
          bridge_mode     :: boolean(),
          clientid        :: binary(),
          clean_start     :: boolean(),
          username        :: binary() | undefined,
          password        :: undefined | emqtt_secret:t(binary()),
          proto_ver       :: version(),
          proto_name      :: iodata(),
          keepalive       :: non_neg_integer(),
          keepalive_timer :: undefined | tref(),
          force_ping      :: boolean(),
          paused          :: boolean(),
          will_msg        :: undefined | mqtt_msg(),
          properties      :: properties(),
          pending_calls   :: list(),
          subscriptions   :: map(),
          inflight        :: emqtt_inflight:inflight(
                               inflight_publish() | inflight_pubrel()
                              ),
          awaiting_rel    :: map(),
          auto_ack        :: boolean() | never,
          ack_timeout     :: pos_integer(),
          ack_timer       :: tref() | undefined,
          retry_interval  :: pos_integer(),
          retry_timer     :: tref() | undefined,
          session_present :: undefined | boolean(),
          last_packet_id  :: undefined | packet_id(),
          low_mem         :: boolean(),
          parse_state     :: undefined | emqtt_frame:parse_state(),
          reconnect       :: reconnect(),
          reconnect_timeout :: pos_integer(),
          qoe             :: boolean() | map(),
          nst             :: undefined | binary(), %% quic new session ticket
          pendings        :: pendings(),
          extra = #{}     :: map() %% extra field for easier to make appup
         }). %% note, always add the new fields at the tail for code_change.

-type(state() ::  #state{}).

-type(publish_req() :: {publish, via(), #mqtt_msg{}, expire_at(), mfas() | ?NO_HANDLER}).

-type(expire_at() :: non_neg_integer() | infinity). %% in millisecond

-type(pendings() :: queue:queue(publish_req())).

-type(publish_success() :: ok | {ok, publish_reply()}).

-type(publish_reply() :: #{packet_id := packet_id(),
                           reason_code := reason_code(),
                           reason_code_name := atom(),
                           properties => undefined | properties()
                          }).

-type(inflight_publish() :: {publish,
                             via(),
                             #mqtt_msg{},
                             sent_at(),
                             expire_at(),
                             mfas() | ?NO_HANDLER
                            }).

-type(inflight_pubrel() :: {pubrel,
                            via(),
                            packet_id(),
                            sent_at(),
                            expire_at()
                           }).

-type(sent_at() :: non_neg_integer()). %% in millisecond

-type opname() :: connect | subscribe | unsubscribe | ping.
-record(callid, {op :: opname(),
                 via  :: via(),
                 packet_id :: packet_id() | undefined
                }).
-type callid() :: #callid{}.
-export_type([publish_success/0, publish_reply/0]).


-define(PUB_REQ(Msg, Via, ExpireAt, Callback), {publish, Via, Msg, ExpireAt, Callback}).

-define(INFLIGHT_PUBLISH(Via, Msg, SentAt, ExpireAt, Callback),
        {publish, Via, Msg, SentAt, ExpireAt, Callback}).

-define(INFLIGHT_PUBREL(Via, PacketId, SentAt, ExpireAt),
        {pubrel, Via, PacketId, SentAt, ExpireAt}).

-record(call, {id, from, req, ts}).

%% Default timeout
-define(DEFAULT_KEEPALIVE, 60).
-define(DEFAULT_RETRY_INTERVAL, 30000).
-define(DEFAULT_ACK_TIMEOUT, 30000).
-define(DEFAULT_CONNECT_TIMEOUT, 60000).
-define(DEFAULT_RECONNECT_TIMEOUT, 5000).

-define(PROPERTY(Name, Val), #state{properties = #{Name := Val}}).

-define(WILL_MSG(QoS, Retain, Topic, Props, Payload),
        #mqtt_msg{qos = QoS,
		  retain = Retain,
		  topic = Topic,
		  props = Props,
		  payload = Payload
		 }).

-define(NO_CLIENT_ID, <<>>).

-define(NEED_RECONNECT(Re), (Re == infinity orelse (is_integer(Re) andalso Re > 0))).

-define(SOCK_ERROR(E), (E =:= tcp_error orelse
                        E =:= ssl_error orelse
                        E =:= quic_error orelse
                        E =:= 'EXIT')).

-define(SOCK_CLOSED(E), (E =:= tcp_closed orelse
                         E =:= ssl_closed orelse
                         E =:= quic_closed)).

-define(LOG(Level, Msg, Meta, State),
        ?SLOG(Level, (begin Meta end)#{msg => Msg, clientid => State#state.clientid}, #{})).

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
    StatmOpts = case proplists:get_bool(low_mem, Options) of
                    false -> [];
                    true ->
                        [{spawn_opt, [{min_heap_size, 16},
                                      {min_bin_vheap_size,16}
                                     ]},
                         {hibernate_after, 50}
                        ]
                end,

    case proplists:get_value(name, Options) of
        undefined ->
            gen_statem:start_link(?MODULE, [with_owner(Options)], StatmOpts);
        Name when is_atom(Name) ->
            gen_statem:start_link({local, Name}, ?MODULE, [with_owner(Options)], StatmOpts)
    end.

with_owner(Options) ->
    case proplists:get_value(owner, Options) of
        Owner when is_pid(Owner) -> Options;
        undefined -> [{owner, self()} | Options]
    end.

-spec(connect(client()) -> {ok, properties() | undefined} | {error, term()}).
connect(Client) ->
    call(Client, {connect, emqtt_sock}).

-spec(ws_connect(client()) -> {ok, properties() | undefined} | {error, term()}).
ws_connect(Client) ->
    call(Client, {connect, emqtt_ws}).

-spec(open_quic_connection(client()) -> ok | {error, term()}).
open_quic_connection(Client) ->
    call(Client, {open_connection, emqtt_quic}).

-spec(quic_mqtt_connect(client()) -> ok | {error, term()}).
quic_mqtt_connect(Client) ->
    call(Client, quic_mqtt_connect).

-spec(quic_connect(client()) -> {ok, properties()} | {error, term()}).
quic_connect(Client) ->
    call(Client, {connect, emqtt_quic}).

qos_number(?QOS_0) -> ?QOS_0;
qos_number(qos0) -> ?QOS_0;
qos_number(at_most_once) -> ?QOS_0;
qos_number(?QOS_1) -> ?QOS_1;
qos_number(qos1) -> ?QOS_1;
qos_number(at_least_once) -> ?QOS_1;
qos_number(?QOS_2) -> ?QOS_2;
qos_number(qos2) -> ?QOS_2;
qos_number(exactly_once) -> ?QOS_2.


%% @private
call(Client, Req) ->
    gen_statem:call(Client, Req, infinity).

-spec(subscribe(client(), topic() | {topic(), qos() | qos_name() | [subopt()]} | [{topic(), qos()}])
      -> subscribe_ret()).
subscribe(Client, Topic) when is_binary(Topic) ->
    subscribe(Client, {Topic, ?QOS_0});
subscribe(Client, {Topic, QoS}) when is_binary(Topic), is_atom(QoS) ->
    subscribe(Client, {Topic, qos_number(QoS)});
subscribe(Client, {Topic, QoS}) when is_binary(Topic), ?IS_QOS(QoS) ->
    subscribe(Client, [{Topic, QoS}]);
subscribe(Client, Topics) when is_list(Topics) ->
    subscribe(Client, #{}, lists:map(
                             fun({Topic, QoS}) when is_binary(Topic), is_atom(QoS) ->
                                 {Topic, [{qos, qos_number(QoS)}]};
                                ({Topic, QoS}) when is_binary(Topic), ?IS_QOS(QoS) ->
                                 {Topic, [{qos, qos_number(QoS)}]};
                                ({Topic, Opts}) when is_binary(Topic), is_list(Opts) ->
                                 {Topic, Opts}
                             end, Topics)).

-spec(subscribe(client(), topic(), qos() | qos_name() | [subopt()]) ->
                subscribe_ret();
               (client(), properties(), [{topic(), qos() | [subopt()]}]) ->
                subscribe_ret()).
subscribe(Client, Topic, QoS) when is_binary(Topic), is_atom(QoS) ->
    subscribe(Client, Topic, qos_number(QoS));
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
    subscribe(Client, Properties, Topic, qos_number(QoS));
subscribe(Client, Properties, Topic, QoS)
    when is_map(Properties), is_binary(Topic), ?IS_QOS(QoS) ->
    subscribe(Client, Properties, Topic, [{qos, QoS}]);
subscribe(Client, Properties, Topic, Opts)
    when is_map(Properties), is_binary(Topic), is_list(Opts) ->
    subscribe(Client, Properties, [{Topic, Opts}]).

-spec subscribe_via(client(), via(), properties(), [{topic(), subopt()}]) -> subscribe_ret().
subscribe_via(Client, Via, Properties, Topics)
  when is_map(Properties), is_list(Topics) ->
    Topics1 = [{Topic, parse_subopt(Opts)} || {Topic, Opts} <- Topics],
    gen_statem:call(Client, {subscribe, Via, Properties, Topics1}).

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
    parse_subopt(Opts, Result#{qos := qos_number(QoS)});
parse_subopt([_ | Opts], Result) ->
    parse_subopt(Opts, Result).

-spec(publish(client(), topic(), payload())
      -> publish_success() | {error, term()}).
publish(Client, Topic, Payload) when is_binary(Topic) ->
    publish_via(Client, default, #mqtt_msg{topic = Topic, qos = ?QOS_0, payload = iolist_to_binary(Payload)}).

-spec(publish(client(), topic(), payload(), qos() | qos_name() | [pubopt()])
      -> publish_success() | {error, term()}).
publish(Client, Topic, Payload, QoS) when is_binary(Topic), is_atom(QoS) ->
    publish(Client, Topic, Payload, [{qos, qos_number(QoS)}]);
publish(Client, Topic, Payload, QoS) when is_binary(Topic), ?IS_QOS(QoS) ->
    publish(Client, Topic, Payload, [{qos, QoS}]);
publish(Client, Topic, Payload, Opts) when is_binary(Topic), is_list(Opts) ->
    publish(Client, Topic, #{}, Payload, Opts).

-spec(publish(client(), topic(), properties(), payload(), [pubopt()])
      -> publish_success() | {error, term()}).
publish(Client, Topic, Properties, Payload, Opts) ->
  publish_via(Client, _Via = default, Topic, Properties, Payload, Opts).

-spec(publish_via(client(), via(), topic(), properties(), payload(), [pubopt()])
      -> publish_success() | {error, term()}).
publish_via(Client, Via, Topic, Properties, Payload, Opts)
  when is_binary(Topic), is_map(Properties), is_list(Opts) ->
    ok = emqtt_props:validate(Properties),
    Retain = proplists:get_bool(retain, Opts),
    QoS = qos_number(proplists:get_value(qos, Opts, ?QOS_0)),
    publish_via(Client, Via, #mqtt_msg{qos     = QoS,
                                       retain  = Retain,
                                       topic   = Topic,
                                       props   = Properties,
                                       payload = iolist_to_binary(Payload)}).

-spec(publish(client(), #mqtt_msg{}) -> publish_success() | {error, term()}).
publish(Client, #mqtt_msg{} = Msg) ->
    publish_via(Client, _Via = default, Msg).

-spec(publish_via(client(), via(), #mqtt_msg{}) -> publish_success() | {error, term()}).
publish_via(Client, Via, #mqtt_msg{} = Msg) ->
    %% copied from otp23.4 gen:do_call/4
    Mref = erlang:monitor(process, Client),
    %% Local without timeout; no need to use alias since we unconditionally
    %% will wait for either a reply or a down message which corresponds to
    %% the process being terminated (as opposed to 'noconnection')...
    publish_async(Client, Via, Msg, infinity, {fun ?MODULE:sync_publish_result/3, [self(), Mref]}),
    receive
        {Mref, Reply} ->
            erlang:demonitor(Mref, [flush]),
            %% assert return type
            case Reply of
                ok ->
                    ok;
                {ok, Result} ->
                    {ok, Result};
                {error, Reason} ->
                    {error, Reason}
            end;
        {'DOWN', Mref, _, _, Reason} ->
            exit(Reason)
    end.

sync_publish_result(Caller, Mref, Result) ->
    erlang:send(Caller, {Mref, Result}).

publish_async(Client, Topic, Payload, Callback)  ->
    publish_async(Client, _Via = default, Topic, Payload, Callback).

-spec publish_async(client(), topic(), payload(), qos() | qos_name() | [pubopt()], mfas()) -> ok;
                   (client(), via(), topic() | #mqtt_msg{}, payload() | timeout(), mfas()) -> ok.
publish_async(Client, Topic, Payload, QoS, Callback) when is_binary(Topic) ->
    publish_async(Client, _Via = default, Topic, Payload, QoS, Callback);
publish_async(Client, Via, Topic, Payload, Callback) when is_binary(Topic) ->
    publish_async(Client, Via, Topic, #{}, Payload, [{qos, ?QOS_0}], infinity, Callback);
publish_async(Client, Via, Msg = #mqtt_msg{}, Timeout, Callback) ->
    ExpireAt = case Timeout of
                    infinity -> infinity;
                    _ -> erlang:system_time(millisecond) + Timeout
                end,
    _ = erlang:send(Client, ?PUB_REQ(Msg, Via, ExpireAt, Callback)),
    ok.

-spec(publish_async(client(), via(), topic(), payload(), qos() | qos_name() | [pubopt()], mfas()) -> ok).
publish_async(Client, Via, Topic, Payload, QoS, Callback) when is_binary(Topic), is_atom(QoS) ->
    publish_async(Client, Via, Topic, #{}, Payload, [{qos, qos_number(QoS)}], infinity, Callback);
publish_async(Client, Via, Topic, Payload, QoS, Callback) when is_binary(Topic), ?IS_QOS(QoS) ->
    publish_async(Client, Via, Topic, #{}, Payload, [{qos, QoS}], infinity, Callback);
publish_async(Client, Via, Topic, Payload, Opts, Callback) when is_binary(Topic), is_list(Opts) ->
    publish_async(Client, Via, Topic, #{}, Payload, Opts, infinity, Callback).

-spec(publish_async(client(), topic(), properties(), payload(), [pubopt()],
                    timeout(), mfas())
      -> ok).
publish_async(Client, Topic, Properties, Payload, Opts, Timeout, Callback) ->
    publish_async(Client, _Via = default, Topic, Properties, Payload, Opts, Timeout, Callback).

-spec(publish_async(client(), via(), topic(), properties(), payload(), [pubopt()],
                    timeout(), mfas())
      -> ok).
publish_async(Client, Via, Topic, Properties, Payload, Opts, Timeout, Callback)
    when is_binary(Topic), is_map(Properties), is_list(Opts) ->
    ok = emqtt_props:validate(Properties),
    Retain = proplists:get_bool(retain, Opts),
    QoS = qos_number(proplists:get_value(qos, Opts, ?QOS_0)),
    publish_async(Client,
                  Via,
                  #mqtt_msg{qos     = QoS,
                            retain  = Retain,
                            topic   = Topic,
                            props   = Properties,
                            payload = iolist_to_binary(Payload)},
                  Timeout,
                  Callback).

%% QUIC only
-spec start_data_stream(client(), quicer:stream_opts())-> {ok, via()} | {error, any()}.
start_data_stream(Client, StreamOpts) ->
    call(Client, {new_data_stream, StreamOpts}).

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

-spec(unsubscribe_via(client(), via(), topic() | [topic()]) -> subscribe_ret()).
unsubscribe_via(Client, Via, Topic) when is_binary(Topic) ->
    unsubscribe_via(Client, Via, [Topic]);
unsubscribe_via(Client, Via, Topics) when is_list(Topics) ->
    unsubscribe_via(Client, Via, #{}, Topics).

-spec(unsubscribe_via(client(), via(), properties(), topic() | [topic()]) -> subscribe_ret()).
unsubscribe_via(Client, Via, Properties, Topic) when is_map(Properties), is_binary(Topic) ->
    unsubscribe_via(Client, Via, Properties, [Topic]);
unsubscribe_via(Client, Via, Properties, Topics) when is_map(Properties), is_list(Topics) ->
    gen_statem:call(Client, {unsubscribe, Via, Properties, Topics}).

-spec(ping(client()) -> pong).
ping(Client) ->
    gen_statem:call(Client, ping).

-spec(status(client()) -> initialized | connected | waiting_for_connack | reconnect).
status(Client) ->
    gen_statem:call(Client, status).

-spec(disconnect(client()) -> ok | {error, any()}).
disconnect(Client) ->
    disconnect(Client, ?RC_SUCCESS).

-spec(disconnect(client(), reason_code()) -> ok | {error, any()}).
disconnect(Client, ReasonCode) ->
    disconnect(Client, ReasonCode, #{}).

-spec(disconnect(client(), reason_code(), properties()) -> ok | {error, any()}).
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

-spec(info(client(), n_queued) -> _NumQueuedMessages :: non_neg_integer();
          (client(), n_inflight) -> _NumInflightMessages :: non_neg_integer();
          (client(), max_inflight) -> _MaxInflightMessages :: pos_integer() | infinity).
info(Client, Attr) ->
    gen_statem:call(Client, {info, Attr}).

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
    ClientId = maybe_rand_id(proplists:get_value(proto_ver, Options, v4),
                             proplists:get_value(clientid, Options, ?NO_CLIENT_ID)),
    State = check_options(
              init(Options,
                   #state{host            = {127,0,0,1},
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
                          will_msg        = undefined,
                          pending_calls   = [],
                          subscriptions   = #{},
                          inflight        = emqtt_inflight:new(infinity),
                          awaiting_rel    = #{},
                          properties      = #{},
                          auto_ack        = true,
                          ack_timeout     = ?DEFAULT_ACK_TIMEOUT,
                          retry_interval  = ?DEFAULT_RETRY_INTERVAL,
                          connect_timeout = ?DEFAULT_CONNECT_TIMEOUT,
                          low_mem         = false,
                          reconnect         = 0,
                          reconnect_timeout = ?DEFAULT_RECONNECT_TIMEOUT,
                          qoe             = false,
                          last_packet_id  = 1,
                          pendings        = queue:new()
                         })),
    {ok, initialized, init_parse_state(State)}.

maybe_rand_id(v5, ?NO_CLIENT_ID) -> ?NO_CLIENT_ID;
maybe_rand_id(_, ?NO_CLIENT_ID) -> random_client_id();
maybe_rand_id(_, ID) -> ID.

random_client_id() ->
    _ = rand:seed(exsplus, erlang:timestamp()),
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
init([{quic_opts, {_ConnOpts, _StreamOpts}} = QuicOpts | Opts], State = #state{sock_opts = SockOpts}) ->
    init(Opts, State#state{sock_opts = merge_opts(SockOpts, [QuicOpts])});
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
init([{ws_transport_options, TransportOptions} | Opts], State = #state{sock_opts = SockOpts}) ->
    init(Opts, State#state{sock_opts = [{ws_transport_options, TransportOptions}|SockOpts]});
init([{ws_headers, Headers} | Opts], State = #state{sock_opts = SockOpts}) ->
    init(Opts, State#state{sock_opts = [{ws_headers, Headers}|SockOpts]});
init([{clientid, ClientId} | Opts], State) ->
    init(Opts, State#state{clientid = iolist_to_binary(ClientId)});
init([{clean_start, CleanStart} | Opts], State) when is_boolean(CleanStart) ->
    init(Opts, State#state{clean_start = CleanStart});
init([{username, Username} | Opts], State) ->
    init(Opts, State#state{username = iolist_to_binary(Username)});
init([{password, Secret} | Opts], State) when is_function(Secret, 0) ->
    init(Opts, State#state{password = Secret});
init([{password, Password} | Opts], State) ->
    init(Opts, State#state{password = emqtt_secret:wrap(iolist_to_binary(Password))});
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
    init(Opts, State#state{will_msg = WillMsg1});
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
    init(Opts, State#state{inflight = emqtt_inflight:new(infinity)});
init([{max_inflight, I} | Opts], State) when is_integer(I) ->
    init(Opts, State#state{inflight = emqtt_inflight:new(I)});
init([auto_ack | Opts], State) ->
    init(Opts, State#state{auto_ack = true});
init([{auto_ack, AutoAck} | Opts], State) when is_atom(AutoAck) ->
    init(Opts, State#state{auto_ack = AutoAck});
init([{retry_interval, I} | Opts], State) ->
    init(Opts, State#state{retry_interval = timer:seconds(I)});
init([{bridge_mode, Mode} | Opts], State) when is_boolean(Mode) ->
    init(Opts, State#state{bridge_mode = Mode});
%% prior to 1.7.0, reconnect was of type boolean().
init([{reconnect, IsReconnect} | Opts], State) when is_boolean(IsReconnect) ->
    Re = case IsReconnect of
             true -> infinity;
             false -> 0
         end,
    init(Opts, State#state{reconnect = Re});
init([{reconnect, Reconnect} | Opts], State)
  when is_integer(Reconnect) orelse Reconnect == infinity ->
    init(Opts, State#state{reconnect = Reconnect});
init([{reconnect_timeout, I} | Opts], State) ->
    init(Opts, State#state{reconnect_timeout = timer:seconds(I)});
init([{low_mem, IsLow} | Opts], State) when is_boolean(IsLow) ->
    init(Opts, State#state{low_mem = IsLow});
init([{nst, Ticket} | Opts], State = #state{sock_opts = SockOpts}) when is_binary(Ticket) ->
    init(Opts, State#state{sock_opts = [{nst, Ticket} | SockOpts]});
init([{with_qoe_metrics, IsReportQoE} | Opts], State) when is_boolean(IsReportQoE) ->
    init(Opts, State#state{qoe = IsReportQoE});
init([{custom_auth_callbacks, #{init := InitFn,
                                handle_auth := HandleAuthFn
                               }} | Opts], State) ->
    %% HandleAuthFn :: fun((State, Reason, Props) -> {continue, OutPacket, State} | {stop, Reason}).
    {AuthInitFn, AuthInitArgs} =
        case InitFn of
            Fn when is_function(Fn, 0) ->
                %% upgrade init callback
                {fun() -> {#{}, Fn()} end, []};
            {_Fn, _Args} = FnAndArgs ->
                FnAndArgs
        end,
    {AuthProps, AuthState} = erlang:apply(AuthInitFn, AuthInitArgs),
    Extra0 = State#state.extra,
    %% TODO: to support re-authenticate, should keep the initial func and args in state
    Extra = Extra0#{auth_cb => #{handle_auth => HandleAuthFn,
                                 initial_auth_props => AuthProps,
                                 state => AuthState}},
    init(Opts, State#state{extra = Extra});
init([_Opt | Opts], State) ->
    init(Opts, State).

maybe_no_will(#mqtt_msg{topic = T} = W) when is_binary(T) andalso T =/= <<>> ->
    W;
maybe_no_will(_) ->
    undefined.

ensure_will_msg(undefined) ->
    #mqtt_msg{topic = <<>>, payload = <<>>};
ensure_will_msg(Will) ->
    Will.

init_will_msg(Input, undefined) ->
    init_will_msg(Input, ensure_will_msg(undefined));
init_will_msg({topic, Topic}, WillMsg) ->
    WillMsg#mqtt_msg{topic = iolist_to_binary(Topic)};
init_will_msg({props, Props}, WillMsg) ->
    WillMsg#mqtt_msg{props = Props};
init_will_msg({payload, Payload}, WillMsg) ->
    WillMsg#mqtt_msg{payload = iolist_to_binary(Payload)};
init_will_msg({retain, Retain}, WillMsg) when is_boolean(Retain) ->
    WillMsg#mqtt_msg{retain = Retain};
init_will_msg({qos, QoS}, WillMsg) ->
    WillMsg#mqtt_msg{qos = qos_number(QoS)}.

init_parse_state(State = #state{proto_ver = Ver, properties = Properties, will_msg = WillMsg}) ->
    MaxSize = maps:get('Maximum-Packet-Size', Properties, ?MAX_PACKET_SIZE),
    ParseState = emqtt_frame:initial_parse_state(
		   #{max_size => MaxSize, version => Ver}),
    State#state{parse_state = ParseState, will_msg = maybe_no_will(WillMsg)}.

merge_opts(Defaults, Options) ->
    lists:foldl(
      fun({Opt, Val}, Acc) ->
          lists:keystore(Opt, 1, Acc, {Opt, Val});
         (Opt, Acc) ->
          lists:usort([Opt | Acc])
      end, Defaults, Options).

check_options(State) ->
    State.

callback_mode() -> state_functions.


%%%%
%%%% State Functions
%%%%
initialized({call, From}, {connect, ConnMod}, State) ->
    case do_connect(ConnMod, qoe_inject(?FUNCTION_NAME, State)) of
        {ok, #state{connect_timeout = Timeout, socket = Via} = NewState} ->
            {next_state, waiting_for_connack,
                add_call(new_call(call_id(connect, Via), From), NewState),
                {state_timeout, Timeout, connack_timeout}};
        {error, Reason} ->
            shutdown_reply(Reason, From, {error, Reason})
    end;
initialized({call, From}, {open_connection, emqtt_quic}, #state{sock_opts = SockOpts} = State) ->
    case emqtt_quic:open_connection() of
        {ok, Conn} ->
            State1 = State#state{
                       conn_mod = emqtt_quic,
                       socket = {quic, Conn, undefined},
                       %% `handle' is quicer connecion opt
                       sock_opts = [{handle, Conn} | SockOpts]},
            {keep_state, maybe_init_quic_state(emqtt_quic, State1),
             {reply, From, ok}};
        {error, Reason} = Error ->
            shutdown_reply(Reason, From, Error)
    end;
initialized({call, From}, quic_mqtt_connect, #state{socket = {quic, Conn, undefined}} = State) ->
    {ok, NewCtrlStream} = quicer:start_stream(Conn, #{active => 1}),
    NewSocket = {quic, Conn, NewCtrlStream},
    case mqtt_connect(maybe_update_ctrl_sock(emqtt_quic, maybe_init_quic_state(emqtt_quic, State), NewSocket)) of
        {ok, #state{socket = Via} = NewState} ->
            {keep_state,
             add_call(new_call(call_id(connect, Via), From), NewState),
             {reply, From, ok}};
        {error, Reason} = Error->
            %% TODO: handle error async to allow reconnect
            shutdown_reply(Reason, From, Error)
    end;
initialized({call, From}, {new_data_stream, _StreamOpts} = Via0, State) ->
    {Via, State1} = maybe_new_stream(Via0, State),
    {keep_state, State1, {reply, From, {ok, Via}}};
initialized(info, ?PUB_REQ(#mqtt_msg{}, _Via, _ExpireAt, _Callback) = PubReq,
            State0) ->
    shoot(PubReq, State0);
initialized(EventType, EventContent, State) ->
    handle_event(EventType, EventContent, initialized, State).

do_connect(ConnMod, #state{pending_calls = Pendings,
                           sock_opts = SockOpts,
                           connect_timeout = Timeout,
                           qoe = IsQoE
                          } = State) ->
    State0 = maybe_init_quic_state(ConnMod, State),
    IsUsingQuicHandle = proplists:is_defined(handle, SockOpts),
    IsQoE =/= false andalso put(qoe, IsQoE),
    case sock_connect(ConnMod, hosts(State0), SockOpts, Timeout) of
        skip ->
            {ok, State0};
        {ok, NewSock} when not IsUsingQuicHandle ->
            State1 = maybe_update_ctrl_sock(ConnMod, State0, NewSock),
            State2 = qoe_inject(handshaked, maybe_qoe_tcp(State1)),
            NewPendings = refresh_calls(Pendings, NewSock),
            State3 = run_sock(State2#state{conn_mod = ConnMod,
                                           socket = NewSock,
                                           pending_calls = NewPendings
                                          }),
            case mqtt_connect(State3) of
                {ok, State4} ->
                    {ok, State4};
                {error, closed} ->
                    %% We may receive the `closed' error when attempting to perform MQTT
                    %% connect on a TLS socket, for example, if the client's TLS
                    %% certificate is revoked and the server closes the connection.
                    {error, closed};
                {error, Reason} ->
                    ?LOG(info, "failed_to_send_connect_packet", #{reason => Reason}, State),
                    %% Failed to send CONNECT packet.
                    %% wait for the async socket close or error event
                    {ok, State3}
            end;
        {error, econnreset} ->
            %% TODO: handle econnreset.
            %% For now this may lead to immediate shtudown even if reconnect is allowed
            {error, econnreset};
        {error, Reason} ->
            %% cannot think of other reasons for delayed retry
            {error, Reason}
    end.

-spec mqtt_connect(state()) -> {ok, state()} | {error, any()}.
mqtt_connect(State = #state{clientid    = ClientId,
                            clean_start = CleanStart,
                            bridge_mode = IsBridge,
                            username    = Username,
                            password    = Password,
                            proto_ver   = ProtoVer,
                            proto_name  = ProtoName,
                            keepalive   = KeepAlive,
                            will_msg    = WillMsg,
                            properties  = Properties0,
                            extra       = Extra
                           }) ->
    Properties = maybe_merge_auth_props(Properties0, Extra),
    ?WILL_MSG(WillQoS, WillRetain, WillTopic, WillProps, WillPayload) = ensure_will_msg(WillMsg),
    ConnProps = emqtt_props:filter(?CONNECT, Properties),
    Packet =
        ?CONNECT_PACKET(
            #mqtt_packet_connect{proto_ver    = ProtoVer,
                                 proto_name   = ProtoName,
                                 is_bridge    = IsBridge,
                                 clean_start  = CleanStart,
                                 will_flag    = (WillMsg =/= undefined),
                                 will_qos     = WillQoS,
                                 will_retain  = WillRetain,
                                 keepalive    = KeepAlive,
                                 properties   = ConnProps,
                                 clientid     = ClientId,
                                 will_props   = WillProps,
                                 will_topic   = WillTopic,
                                 will_payload = WillPayload,
                                 username     = Username,
                                 password     = emqtt_secret:unwrap(Password)}),
    send(Packet, State).

maybe_merge_auth_props(Properties, #{auth_cb := #{initial_auth_props := AuthProps}}) ->
    maps:merge(Properties, AuthProps);
maybe_merge_auth_props(Properties, _) ->
    Properties.

reconnect(state_timeout, #{retry_cnt := Cnt, reason := Reason}, State) when Cnt =< 0 ->
    shutdown(Reason, State);
reconnect(state_timeout, #{retry_cnt := Cnt}, #state{conn_mod = CMod} = State) ->
    case do_connect(CMod, State) of
        {ok, #state{connect_timeout = Timeout} = NewState} ->
            {next_state, waiting_for_connack, NewState, {state_timeout, Timeout, connack_timeout}};
        {error, Reason} ->
            #state{reconnect_timeout = Timeout} = State,
            EventContent = #{retry_cnt => next_retry_cnt(Cnt), reason => Reason},
            {keep_state_and_data, {state_timeout, Timeout, EventContent}}
    end;
reconnect({call, From}, stop, _State) ->
    shutdown_reply(normal, From, ok);
reconnect({call, From}, status, _State) ->
    {keep_state_and_data, {reply, From, reconnect}};
reconnect(info, {Close, _StaleSock}, _State) when ?SOCK_CLOSED(Close) ->
    %% ignore stale socket close events
    keep_state_and_data;
reconnect(info, {Error, StaleSock, _Reason}, #state{socket = StaleSock}) when ?SOCK_ERROR(Error) ->
    %% ignore stale socket error events
    keep_state_and_data;
reconnect(info, {'EXIT', Owner, Reason}, State = #state{owner = Owner}) ->
    ?LOG(debug, "exit_from_owner", #{reason => Reason}, State),
    shutdown({owner, Owner, Reason}, State);
reconnect(_EventType, _, _State) ->
    {keep_state_and_data, postpone}.

waiting_for_connack(cast, #mqtt_packet{} = P, State) ->
    waiting_for_connack(cast, {P, default_via(State)}, State);
waiting_for_connack(cast, {?CONNACK_PACKET(?RC_SUCCESS,
                                          SessPresent,
                                          Properties), Via},
                    State = #state{properties = AllProps,
                                   clientid = ClientId,
                                   inflight = Inflight,
                                   socket = Via,
                                   proto_ver = Ver
                                  }) ->
    AllProps1 = case Properties of
                    undefined -> AllProps;
                    _ -> maps:merge(AllProps, Properties)
                end,
    Reply = {ok, Properties},
    State1 = State#state{clientid = assign_id(ClientId, Ver, AllProps1),
                         properties = AllProps1,
                          session_present = SessPresent},
    State2 = qoe_inject(connected, State1),
    State3 = ensure_retry_timer(ensure_keepalive_timer(State2)),
    %% NOTE
    %% Server is supposedly permitted to change `Receive-Maximum` for each new connection.
    %% This is fine for the initial connection, but for reconnections, it's not clear what
    %% to do if the `Receive-Maximum` is reduced and is now less than the inflight size
    %% (see `connected(info, immediate_retry, ...)` below).
    ReceiveMaximum = maps:get('Receive-Maximum', AllProps1, infinity),
    Inflight1 = emqtt_inflight:limit(ReceiveMaximum, Inflight),
    State4 = State3#state{inflight = Inflight1},
    Retry = [{next_event, info, immediate_retry} || not emqtt_inflight:is_empty(Inflight1)],
    case take_call(call_id(connect, Via), State4) of
        {value, #call{from = From}, State5} ->
            {next_state, connected, State5, [{reply, From, Reply} | Retry]};
        false ->
            %% unkown caller, internally initiated re-connect
            ok = eval_msg_handler(State4, connected, Properties),
            {next_state, connected, State4, Retry}
    end;

waiting_for_connack(cast, {?CONNACK_PACKET(ReasonCode,
                                           _SessPresent,
                                           Properties), Via},
                    State = #state{proto_ver = ProtoVer, socket = Via}) ->
    Reason = reason_code_name(ReasonCode, ProtoVer),
    case take_call(call_id(connect, Via), State) of
        {value, #call{from = From}, _State} ->
            Reply = {error, {Reason, Properties}},
            shutdown_reply(Reason, From, Reply);
        false -> maybe_reconnect({connack_error, Reason}, State)
    end;

waiting_for_connack(cast, {?AUTH_PACKET(ReasonCode,
                                        Properties), Via},
                    State0 = #state{proto_ver = ProtoVer, socket = Via,
                                   extra = #{auth_cb := #{} = AuthCb} = Extra0}) ->
    #{handle_auth := HandleAuthFn, state := AuthState0} = AuthCb,
    Reason = reason_code_name(ReasonCode, ProtoVer),
    case HandleAuthFn(AuthState0, Reason, Properties) of
        {continue, {OutReasonCode, OutProps}, AuthState} ->
            Extra = Extra0#{auth_cb := AuthCb#{state := AuthState}},
            State1 = State0#state{extra = Extra},
            OutPacket = ?AUTH_PACKET(OutReasonCode, OutProps),
            case send(Via, OutPacket, State1) of
                {ok, State} ->
                    {keep_state, State};
                {error, Reason} ->
                    shutdown({send_auth_failed, Reason}, State1)
            end;
        {stop, StopReason} ->
            shutdown(StopReason, State0)
    end;

waiting_for_connack({call, From}, status, _State) ->
    {keep_state_and_data, {reply, From, waiting_for_connack}};
waiting_for_connack({call, _From}, Event, _State) when Event =/= stop ->
    {keep_state_and_data, postpone};

waiting_for_connack(info, ?PUB_REQ(_Msg, _Via, _ExpireAt, _Callback), _State) ->
    {keep_state_and_data, postpone};

waiting_for_connack(state_timeout, connack_timeout, State) ->
    case take_call(call_id(connect, default_via(State)), State) of
        {value, #call{from = From}, _State} ->
            shutdown_reply(connack_timeout, From, {error, connack_timeout});
        false ->
            maybe_reconnect(connack_timeout, State)
    end;

waiting_for_connack(EventType, EventContent, State) ->
    case handle_event(EventType, EventContent, waiting_for_connack, #state{socket = Via} = State) of
        {stop, Reason, NewState} ->
            case take_call(call_id(connect, Via), NewState) of
                {value, #call{from = From}, _State} ->
                    Reply = case Reason of
                                {shutdown, _ShutdownReason} ->
                                    %% All _ShutdownReason reasons returned from handle_event
                                    %% are included in EventContext
                                    {error, EventContent};
                                _ ->
                                    {error, {Reason, EventContent}}
                            end,
                    shutdown_reply(Reason, From, Reply);
                false ->
                    shutdown(Reason, NewState)
            end;
        StateCallbackResult ->
            StateCallbackResult
    end.

connected({call, From}, subscriptions, #state{subscriptions = Subscriptions}) ->
    {keep_state_and_data, [{reply, From, maps:to_list(Subscriptions)}]};

connected({call, From}, info, State) ->
    Info = lists:zip(record_info(fields, state), tl(tuple_to_list(State))),
    {keep_state_and_data, [{reply, From, Info}]};

connected({call, From}, {info, Attr}, State) ->
    Info = case Attr of
               n_queued -> queue:len(State#state.pendings);
               n_inflight -> emqtt_inflight:size(State#state.inflight);
               max_inflight -> emqtt_inflight:maxsize(State#state.inflight)
           end,
    {keep_state_and_data, [{reply, From, Info}]};

connected({call, From}, pause, State) ->
    {keep_state, State#state{paused = true}, [{reply, From, ok}]};

connected({call, From}, resume, State) ->
    {keep_state, State#state{paused = false}, [{reply, From, ok}]};

connected({call, From}, clientid, #state{clientid = ClientId}) ->
    {keep_state_and_data, [{reply, From, ClientId}]};

connected({call, From}, {subscribe, Properties, Topics}, State) ->
    connected({call, From}, {subscribe, default_via(State), Properties, Topics}, State);
connected({call, From}, SubReq = {subscribe, Via0, Properties, Topics},
          State = #state{reconnect = Re, last_packet_id = PacketId, subscriptions = Subscriptions}) ->
    {Via, State1} = maybe_new_stream(Via0, State),
    case send(Via, ?SUBSCRIBE_PACKET(PacketId, Properties, Topics), State1) of
        {ok, NewState} ->
            Call = new_call(call_id(subscribe, Via, PacketId), From, SubReq),
            Subscriptions1 =
                lists:foldl(fun({Topic, Opts}, Acc) ->
                                maps:put(Topic, Opts, Acc)
                            end, Subscriptions, Topics),
            {keep_state, ensure_ack_timer(add_call(Call,NewState#state{subscriptions = Subscriptions1}))};
        Error = {error, Reason} when ?NEED_RECONNECT(Re) ->
            enter_reconnect(Reason, State, [{reply, From, Error}]);
        Error = {error, Reason} ->
            shutdown_reply(Reason, From, Error)
    end;

connected({call, From}, {unsubscribe, Properties, Topics}, State) ->
    connected({call, From}, {unsubscribe, default_via(State), Properties, Topics}, State);
connected({call, From}, UnsubReq = {unsubscribe, Via0, Properties, Topics},
          State = #state{last_packet_id = PacketId}) ->
    {Via, State1} = maybe_new_stream(Via0, State),
    case send(Via, ?UNSUBSCRIBE_PACKET(PacketId, Properties, Topics), State1) of
        {ok, NewState} ->
            Call = new_call(call_id(unsubscribe, Via, PacketId), From, UnsubReq),
            {keep_state, ensure_ack_timer(add_call(Call, NewState))};
        Error = {error, Reason} ->
            shutdown_reply(Reason, From, Error)
    end;

connected({call, From}, ping, #state{socket = Via} = State) ->
    connected({call, From}, {ping, Via}, State);
connected({call, From}, {ping, Via0}, State) ->
    {Via, State1} = maybe_new_stream(Via0, State),
    case send(Via, ?PACKET(?PINGREQ), State1) of
        {ok, NewState} ->
            Call = new_call(call_id(ping, Via), From),
            {keep_state, ensure_ack_timer(add_call(Call, NewState))};
        Error = {error, Reason} ->
            shutdown_reply(Reason, From, Error)
    end;

connected({call, From}, {disconnect, ReasonCode, Properties}, State) ->
    connected({call, From}, {disconnect, default_via(State), ReasonCode, Properties}, State);
connected({call, From}, {disconnect, Via0, ReasonCode, Properties}, State) ->
    {Via, State1} = maybe_new_stream(Via0, State),
    case send(Via, ?DISCONNECT_PACKET(ReasonCode, Properties), State1) of
        {ok, NewState} ->
            {stop_and_reply, normal, [{reply, From, ok}], NewState};
        Error = {error, Reason} ->
            shutdown_reply(Reason, From, Error)
    end;
connected({call, From}, {new_data_stream, _StreamOpts} = Via0, State) ->
    {Via, State1} = maybe_new_stream(Via0, State),
    {keep_state, State1, {reply, From, {ok, Via}}};

connected(cast, {puback, PacketId, ReasonCode, Properties}, State) ->
    connected(cast, {puback, default_via(State), PacketId, ReasonCode, Properties}, State);
connected(cast, {puback, Via, PacketId, ReasonCode, Properties}, State) ->
    send_puback(Via, ?PUBACK_PACKET(PacketId, ReasonCode, Properties), State);

connected(cast, {pubrec, PacketId, ReasonCode, Properties}, State) ->
    connected(cast, {pubrec, default_via(State), PacketId, ReasonCode, Properties}, State);
connected(cast, {pubrec, Via, PacketId, ReasonCode, Properties}, State) ->
    send_puback(Via, ?PUBREC_PACKET(PacketId, ReasonCode, Properties), State);

connected(cast, {pubrel, PacketId, ReasonCode, Properties}, State) ->
    connected(cast, {pubrel, default_via(State), PacketId, ReasonCode, Properties}, State);
connected(cast, {pubrel, Via, PacketId, ReasonCode, Properties}, State) ->
    send_puback(Via, ?PUBREL_PACKET(PacketId, ReasonCode, Properties), State);

connected(cast, {pubcomp, PacketId, ReasonCode, Properties}, State) ->
    connected(cast, {pubcomp, default_via(State), PacketId, ReasonCode, Properties}, State);
connected(cast, {pubcomp, Via, PacketId, ReasonCode, Properties}, State) ->
    send_puback(Via, ?PUBCOMP_PACKET(PacketId, ReasonCode, Properties), State);

connected(cast, #mqtt_packet{} = P, State) ->
    connected(cast, {P, default_via(State)}, State);
connected(cast, {?PUBLISH_PACKET(_QoS, _PacketId), _Via}, #state{paused = true}) ->
    %% @FIXME what if it get dropped?
    keep_state_and_data;

connected(cast, {Packet = ?PUBLISH_PACKET(?QOS_0, _PacketId), Via}, State) ->
     {keep_state, deliver(Via, packet_to_msg(Packet), State)};

connected(cast, {Packet = ?PUBLISH_PACKET(?QOS_1, _PacketId), Via}, State) ->
    publish_qos1(Via, Packet, State);

connected(cast, {Packet = ?PUBLISH_PACKET(?QOS_2, _PacketId), Via}, State) ->
    publish_qos2(Via, Packet, State);

connected(cast, {?PUBACK_PACKET(_PacketId, _ReasonCode, _Properties) = PubAck, Via}, State) ->
    maybe_shoot(ack_inflight(Via, PubAck, State));

connected(cast, {?PUBREC_PACKET(PacketId, _ReasonCode, _Properties) = PubRec, Via}, State) ->
    send_puback(Via, ?PUBREL_PACKET(PacketId), ack_inflight(Via, PubRec, State));

connected(cast, {?PUBREL_PACKET(_PacketId) = PubRel, Via}, State) ->
    process_pubrel(Via, PubRel, State);

connected(cast, {?PUBCOMP_PACKET(_PacketId, _ReasonCode, _Properties) = PubComp, Via}, State) ->
    maybe_shoot(ack_inflight(Via, PubComp, State));

connected(cast, {?SUBACK_PACKET(PacketId, Properties, ReasonCodes), Via},
          State = #state{subscriptions = _Subscriptions}) ->
    case take_call(call_id(subscribe, Via, PacketId), State) of
        {value, #call{from = From}, NewState} ->
            NewProperties = case Properties of
                                undefined -> #{via => Via};
                                #{} -> Properties#{via => Via}
                            end,
            %%TODO: Merge reason codes to subscriptions?
            Reply = {ok, NewProperties, ReasonCodes},
            {keep_state, qoe_inject(subscribed, NewState), [{reply, From, Reply}]};
        false ->
            keep_state_and_data
    end;

connected(cast, {?UNSUBACK_PACKET(PacketId, Properties, ReasonCodes), Via},
          State = #state{subscriptions = Subscriptions}) ->
    case take_call(call_id(unsubscribe, Via, PacketId), State) of
        {value, #call{from = From, req = {_, Via, _, Topics}}, NewState} ->
            Subscriptions1 =
              lists:foldl(fun(Topic, Acc) ->
                              maps:remove(Topic, Acc)
                          end, Subscriptions, Topics),
            NewProperties = case Properties of
                                undefined ->
                                    #{ via => Via };
                                #{} ->
                                    Properties#{via => Via}
                            end,
            {keep_state, NewState#state{subscriptions = Subscriptions1},
             [{reply, From, {ok, NewProperties, ReasonCodes}}]};
        false ->
            keep_state_and_data
    end;

connected(cast, {?PACKET(?PINGRESP), _Via}, #state{pending_calls = []}) ->
    keep_state_and_data;
connected(cast, {?PACKET(?PINGRESP), Via}, State) ->
    case take_call(call_id(ping, Via), State) of
        {value, #call{from = From}, NewState} ->
            {keep_state, NewState, [{reply, From, pong}]};
        false ->
            keep_state_and_data
    end;

connected(cast, {?DISCONNECT_PACKET(ReasonCode, Properties), _Via}, State) ->
    maybe_reconnect({disconnected, ReasonCode, Properties}, State);

connected(info, {timeout, _TRef, keepalive}, State = #state{force_ping = true, low_mem = IsLowMem}) ->
    case send(?PACKET(?PINGREQ), State) of
        {ok, NewState} ->
            IsLowMem andalso erlang:garbage_collect(self(), [{type, major}]),
            {keep_state, ensure_keepalive_timer(NewState)};
        {error, Reason} ->
            maybe_reconnect(Reason, State)
    end;

connected(info, {timeout, TRef, keepalive},
          State = #state{conn_mod = ConnMod, socket = Sock,
                         last_packet_id = LastPktId,
                         paused = Paused, keepalive_timer = TRef}) ->
    case (not Paused) andalso should_ping(ConnMod, Sock, LastPktId) of
        true ->
            case send(?PACKET(?PINGREQ), State) of
                {ok, NewState} ->
                    case ConnMod:getstat(Sock, [send_oct]) of
                        {ok, [{send_oct, Val}]} ->
                            put(send_oct, Val),
                            {keep_state, ensure_keepalive_timer(NewState), [hibernate]};
                        {error, Reason} ->
                            maybe_reconnect(Reason, State)
                    end;
                {error, Reason} -> maybe_reconnect(Reason, State)
            end;
        false ->
            {keep_state, ensure_keepalive_timer(State), [hibernate]};
        {error, Reason} ->
            maybe_reconnect(Reason, State)
    end;

connected(info, {timeout, TRef, ack}, State = #state{ack_timer     = TRef,
                                                     ack_timeout   = Timeout,
                                                     pending_calls = Calls}) ->
    NewState = State#state{ack_timer = undefined,
                           pending_calls = timeout_calls(Timeout, Calls)},
    {keep_state, ensure_ack_timer(NewState)};

connected(info, immediate_retry, State = #state{clean_start = false}) ->
    %% NOTE
    %% Dropping *random* inflight messages on the floor if the inflight window now
    %% contains more messages than the current effective max inflight size. This
    %% is incorrect, strictly speaking, because some of the dropped messages may
    %% have actually reached the server, and would be acked soon.
    %% TODO
    %% Ideally, in that case we should split off "overflow" part of the inflight
    %% window into a separate queue, and retry those messages after the non-overflow
    %% part has been resent, while also draining it if there are matching acks.
    %% Isn't worth the trouble as we expect this situation to be extremely rare.
    State1 = #state{inflight = Inflight} = drop_overflow(State),
    ?LOG(debug, "replay_all_inflight_msgs_due_to_reconnected", #{count => emqtt_inflight:size(Inflight)}, State),
    Now = now_ts(),
    Pred = fun(_, _) -> true end,
    %% reset outdated via field due to reconnection
    Inflight1 = emqtt_inflight:map(
                  fun({_Via, Id}, Req) ->
                          {{default_via(State), Id}, Req}
                  end, Inflight),
    NState = retry_send(
               Now,
               emqtt_inflight:to_retry_list(Pred, Inflight1),
               State1#state{inflight = Inflight1}
              ),
    {keep_state, NState};

connected(info, immediate_retry, State = #state{clean_start = true, inflight = Inflight}) ->
    ?LOG(info, "drop_nack_msgs_due_to_reconnected", #{count => emqtt_inflight:size(Inflight)}, State),
    ok = reply_all_inflight_reqs(dropped, State),
    NState = State#state{inflight = emqtt_inflight:empty(Inflight)},
    {keep_state, NState, {next_event, info, maybe_shoot}};

connected(info, {timeout, TRef, retry}, State0 = #state{retry_timer = TRef,
                                                        inflight    = Inflight}) ->
    State = State0#state{retry_timer = undefined},
	case emqtt_inflight:is_empty(Inflight) of
        true  -> {keep_state, State};
        false -> retry_send(State)
    end;

connected(info, ?PUB_REQ(#mqtt_msg{qos = ?QOS_0}, _Via, _ExpireAt, _Callback) = PubReq, State0) ->
    shoot(PubReq, State0);

connected(info, ?PUB_REQ(#mqtt_msg{qos = QoS}, _Via, _ExpireAt, _Callback) = PubReq,
          State)
  when QoS == ?QOS_1; QoS == ?QOS_2 ->
    maybe_shoot(PubReq, State);

connected(info, maybe_shoot, State) ->
    maybe_shoot(State);

connected(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, connected, Data).

handle_event({call, From}, stop, _StateName, _State) ->
    shutdown_reply(normal, From, ok);

handle_event({call, From}, status, StateName, _State) ->
    {keep_state_and_data, {reply, From, StateName}};

handle_event(info, {gun_ws, ConnPid, StreamRef, {binary, Data}},
             _StateName, State = #state{socket = {ConnPid, StreamRef}}) ->
    ?LOG(debug, "websocket_recv_data", #{data => Data}, State),
    process_incoming(iolist_to_binary(Data), [], State);

handle_event(info, {gun_ws, ConnPid, StreamRef, {close, Code, _}},
             _StateName, State = #state{socket = {ConnPid, StreamRef}}) ->
    %% Expecting connection to be closed shortly.
    ?LOG(debug, "websocket_close", #{code => Code}, State),
    keep_state_and_data;

handle_event(info, {gun_down, ConnPid, _, Reason, _KilledStreams},
             _StateName, State = #state{socket = {ConnPid, _StreamRef}}) ->
    ?LOG(debug, "websocket_down", #{reason => Reason}, State),
    maybe_reconnect({websocket_down, Reason}, State);

handle_event(info, {ssl, session_ticket, _Ticket}, _StateName, _State) ->
    %% TLS 1.3 session ticket
    keep_state_and_data;

handle_event(info, {TcpOrSsL, _Sock, Data}, _StateName, State)
        when TcpOrSsL =:= tcp; TcpOrSsL =:= ssl ->
    ?LOG(debug, "recv_data", #{data => Data}, State),
    process_incoming(Data, [], run_sock(State));

handle_event(info, {Error, Sock, Reason}, connected, #state{socket = Sock} = State)
        when ?SOCK_ERROR(Error) ->
    ?LOG(info, "socket_error", #{error => Error, reason => Reason}, State),
    maybe_reconnect(Reason, State);

handle_event(info, {Error, Sock, Reason}, waiting_for_connack,
             #state{socket = Sock} = State)
        when ?SOCK_ERROR(Error) ->
    ?LOG(info, "socket_error_before_connack", #{error => Error, reason => Reason}, State),
    maybe_reconnect(Reason, State);

handle_event(info, {ssl_error = Error, SSLSock, Reason}, connected,
             #state{socket = #ssl_socket{ssl = SSLSock}} = State) ->
    ?LOG(info, "socket_error", #{error => Error, reason => Reason}, State),
    maybe_reconnect(Reason, State);

handle_event(info, {ssl_error = Error, SSLSock, Reason}, waiting_for_connack,
             #state{socket = #ssl_socket{ssl = SSLSock}} = State) ->
    ?LOG(info, "socket_error_before_connack",
         #{error => Error, reason => Reason}, State),
    maybe_reconnect(Reason, State);

handle_event(info, {Error, Sock, Reason}, _StateName, #state{socket = Sock} = State)
    when ?SOCK_ERROR(Error) ->
    ?LOG(error, "socket_error", #{error => Error, reason => Reason}, State),
    shutdown(Reason, State);

handle_event(info, {ssl_error = Error, SSLSock, Reason}, _StateName, #state{socket = #ssl_socket{ssl = SSLSock}} = State) ->
    ?LOG(error, "socket_error", #{error => Error, reason => Reason}, State),
    shutdown(Reason, State);

handle_event(info, {ssl_closed,  {sslsocket,{gen_tcp, Port, tls_connection,undefined}, _}} = Event,
             StateName, #state{socket = {ssl_socket, PortInUse, _}} = State)
  when PortInUse =/= Port ->
    ?LOG(debug, "ignore_sock_close", #{event => Event, state => StateName}, State),
    keep_state_and_data;
handle_event(info, {tcp_closed, Sock} = Event, StateName, #state{socket = SockInuse} = State)
    when SockInuse =/= Sock ->
    ?LOG(debug, "ignore_sock_close", #{event => Event, state => StateName}, State),
    keep_state_and_data;

handle_event(info, {Closed, _Sock}, connected, State) when ?SOCK_CLOSED(Closed) ->
    ?LOG(info, "socket_closed_when_connected", #{}, State),
    maybe_reconnect(Closed, State);

handle_event(info, {Closed, _Sock}, waiting_for_connack, State) when ?SOCK_CLOSED(Closed) ->
    ?LOG(info, "socket_closed_before_connack", #{}, State),
    maybe_reconnect(Closed, State);

handle_event(info, {Closed, Sock}, StateName, State)
    when Closed =:= tcp_closed; Closed =:= ssl_closed ->
    ?LOG(debug, "socket_closed", #{event => Closed, state => StateName, sock => Sock,
                                   inuse => State#state.socket}, State),
    shutdown(Closed, State);

handle_event(info, {'EXIT', Owner, Reason}, _, State = #state{owner = Owner}) ->
    ?LOG(debug, "got_exit_from_owner", #{reason => Reason}, State),
    shutdown({owner, Owner, Reason}, State);

handle_event(info, {inet_reply, _Sock, ok}, _, _State) ->
    keep_state_and_data;
handle_event(info, {inet_reply, _Sock, {error, Reason}}, _, State) ->
    ?LOG(error, "tcp_error", #{ reason => Reason}, State),
    maybe_reconnect(Reason, State);

%% QUIC messages
handle_event(info, {quic, _, _, _} = QuicMsg, StateName, #state{extra = Extra} = State) ->
    case emqtt_quic:handle_info(QuicMsg, StateName, Extra) of
        {next_state, NewStatName, NewCBState} ->
            {next_state, NewStatName, State#state{extra = NewCBState}};
        {next_state, NewStatName, NewCBState, Actions} ->
            {next_state, NewStatName, State#state{extra = NewCBState}, Actions};
        {keep_state, NewCBState} ->
            {keep_state, State#state{extra = NewCBState}};
        {keep_state, NewCBState, Actions} ->
            {keep_state, State#state{extra = NewCBState}, Actions};
        {repeat_state, NewCBState} ->
            {repeat_state, State#state{extra = NewCBState}};
        {repeat_state, NewCBState, Actions} ->
            {repeat_state, State#state{extra = NewCBState}, Actions};
        {stop, Reason, NewCBState} ->
            shutdown(Reason, State#state{extra = NewCBState});
        {stop_and_reply, Reason, Replies, NewCBState} ->
            {stop_and_reply, Reason, Replies, State#state{extra = NewCBState}};
        Other -> %% Without NewCBState
            Other
    end;

handle_event(info, {'EXIT', Pid, normal}, StateName, State) ->
    ?LOG(info, "unexpected_exit_ignored", #{pid => Pid, state => StateName}, State),
    keep_state_and_data;

handle_event(info, {timeout, TRef, retry}, StateName, State0 = #state{retry_timer = TRef}) ->
    ?LOG(info, "discarded_retry_timer", #{state => StateName}, State0),
    State = State0#state{retry_timer = undefined},
    {keep_state, State};

handle_event(EventType, EventContent, StateName, State) ->
    maybe_upgrade_test_cheat(EventType, EventContent, StateName, State).

-ifdef(UPGRADE_TEST_CHEAT).
%% Cheat release manager that I am the target process for code change.
%% example
%% {ok, Pid}=emqtt:start_link().
%% ets:insert(ac_tab,{{application_master, emqtt}, Pid}).
%% release_handler_1:get_supervised_procs().
maybe_upgrade_test_cheat(info, {get_child, Ref, From}, _StateName, _State) ->
    From ! {Ref, {self(), ?MODULE}},
    keep_state_and_data;
maybe_upgrade_test_cheat({call, From}, which_children, _StateName, _State) ->
    {keep_state_and_data, {reply, From, []}};
maybe_upgrade_test_cheat(_, _, _, _) ->
    handle_unknown_event(EventType, EventContent, StateName, State).
-else.
maybe_upgrade_test_cheat(EventType, EventContent, StateName, State) ->
    handle_unknown_event(EventType, EventContent, StateName, State).
-endif.

handle_unknown_event(EventType, EventContent, StateName, State) ->
    ?LOG(error, "unexpected_event",
         #{state => StateName,
           event_type => EventType,
           event => EventContent}, State),
    keep_state_and_data.

%% Mandatory callback functions
terminate(Reason, _StateName, State = #state{conn_mod = ConnMod, socket = Socket}) ->
    Reason1 = unwrap_shutdown(Reason),
    ok = reply_all_inflight_reqs(Reason1, State),
    ok = reply_all_pendings_reqs(Reason1, State),
    ok = eval_msg_handler(State, disconnected, Reason1),
    ok = close_socket(ConnMod, Socket).

%% Downgrade
code_change({down, _OldVsn}, OldState, OldData, _Extra) ->
    Tmp = tuple_to_list(OldData),
    NewData = list_to_tuple(lists:sublist(Tmp, length(Tmp) -1)),
    {ok, OldState, NewData};

code_change(_OldVsn, OldState, #state{} = OldData, _Extra) ->
    {ok, OldState, OldData};
code_change(_OldVsn, OldState, OldData, _Extra) ->
    NewData = list_to_tuple(tuple_to_list(OldData) ++ [false]),
    {ok, OldState, NewData}.

-ifdef(UPGRADE_TEST_CHEAT).
format_status(_, State) ->
    [{data, [{"State", State}]},
     {supervisor, [{"Callback", ?MODULE}]}].
-endif.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

should_ping(emqtt_quic, _Sock, LastPktId) ->
    %% Unlike TCP, we should not use socket counter since it is the counter of the connection
    %% that the stream belongs to. Instead,  we use last_packet_id to keep track of last send msg.
    Old = put(quic_send_cnt, LastPktId),
    (IsPing = (LastPktId == Old orelse Old == undefined))
        andalso put(quic_send_cnt, LastPktId+1), % count this ping
    IsPing;
should_ping(ConnMod, Sock, _LastPktId) ->
    case ConnMod:getstat(Sock, [send_oct]) of
        {ok, [{send_oct, Val}]} ->
            OldVal = put(send_oct, Val),
            OldVal == undefined orelse OldVal == Val;
        Error = {error, _Reason} ->
            Error
    end.

maybe_shoot(PubReq, State = #state{pendings = Pendings0, inflight = Inflight}) ->
    case emqtt_inflight:is_full(Inflight) of
        false ->
            shoot(PubReq, State);
        true ->
            Pendings = enqueue_publish_req(PubReq, Pendings0),
            {keep_state, State#state{pendings = Pendings}}
    end.

maybe_shoot(State0 = #state{pendings = Pendings, inflight = Inflight}) ->
    NPendings = drop_expired(Pendings),
    State = State0#state{pendings = NPendings},
    case is_pendings_empty(NPendings) orelse emqtt_inflight:is_full(Inflight) of
        false ->
            shoot(State);
        true ->
            {keep_state, State}
    end.

shoot(State = #state{pendings = Pendings}) ->
    {{value, PubReq}, NPendings} = dequeue_publish_req(Pendings),
    shoot(PubReq, State#state{pendings = NPendings}).

shoot(?PUB_REQ(Msg, default, ExpireAt, Callback), State) ->
    shoot(?PUB_REQ(Msg, default_via(State), ExpireAt, Callback), State);
shoot(?PUB_REQ(Msg = #mqtt_msg{qos = ?QOS_0}, Via0,  _ExpireAt, Callback), State0) ->
    {Via, State} = maybe_new_stream(Via0, State0),
    case send(Via, Msg, State) of
        {ok, NState} ->
            eval_callback_handler(ok, Callback),
            maybe_shoot(NState);
        {error, Reason} ->
            eval_callback_handler({error, Reason}, Callback),
            maybe_reconnect(Reason, State)
    end;
shoot(?PUB_REQ(Msg = #mqtt_msg{qos = QoS}, Via0, ExpireAt, Callback),
      State0 = #state{last_packet_id = PacketId, inflight = Inflight})
  when QoS == ?QOS_1; QoS == ?QOS_2 ->
    Msg1 = Msg#mqtt_msg{packet_id = PacketId},
    {Via, State} = maybe_new_stream(Via0, State0),
    case send(Via, Msg1, State) of
        {ok, NState} ->
            {ok, Inflight1} = emqtt_inflight:insert(
                                {Via, PacketId},
                                ?INFLIGHT_PUBLISH(Via, Msg1, now_ts(), ExpireAt, Callback),
                                Inflight
                               ),
            State1 = ensure_retry_timer(NState#state{inflight = Inflight1}),
            maybe_shoot(State1);
        {error, Reason} ->
            eval_callback_handler({error, Reason}, Callback),
            maybe_reconnect(Reason, State)
    end.

is_pendings_empty(Pendings) ->
    queue:is_empty(Pendings).

enqueue_publish_req(PubReq, Pendings) ->
    queue:in(PubReq, Pendings).

%% the previous decision ensures that the length of the queue
%% is greater than 0
dequeue_publish_req(Pendings) ->
    queue:out(Pendings).

ack_inflight(Via,
  ?PUBACK_PACKET(PacketId, ReasonCode, Properties),
  State = #state{inflight = Inflight}
 ) ->
    case emqtt_inflight:delete({Via, PacketId}, Inflight) of
        {{value, ?INFLIGHT_PUBLISH(Via, _Msg, _SentAt, _ExpireAt, Callback)}, NInflight} ->
            eval_callback_handler(
              {ok, #{packet_id => PacketId,
                     reason_code => ReasonCode,
                     reason_code_name => reason_code_name(ReasonCode),
                     properties => Properties,
                     via => Via
                    }}, Callback),
            State#state{inflight = NInflight};
        error ->
            ?LOG(warning, "unexpected_puback", #{packet_id => PacketId, via => Via}, State),
            State
    end;

ack_inflight(Via,
  ?PUBREC_PACKET(PacketId, ReasonCode, Properties),
  State = #state{inflight = Inflight}
 ) ->
    case emqtt_inflight:delete({Via, PacketId}, Inflight) of
        {{value, ?INFLIGHT_PUBLISH(Via, _Msg, _SentAt, ExpireAt, Callback)}, Inflight1} ->
            eval_callback_handler(
              {ok, #{packet_id => PacketId,
                     reason_code => ReasonCode,
                     reason_code_name => reason_code_name(ReasonCode),
                     properties => Properties,
                     via => Via
                    }}, Callback),
            {ok, NInflight} = emqtt_inflight:insert(
                                {Via, PacketId},
                                ?INFLIGHT_PUBREL(Via, PacketId, now_ts(), ExpireAt),
                                Inflight1
                               ),
            State#state{inflight = NInflight};
         {{value, ?INFLIGHT_PUBREL(Via, _PacketId, _SentAt, _ExpireAt)}, _} ->
            ?LOG(notice, "duplicated_pubrec_packet", #{via => Via, packet_id => PacketId}, State),
            State;
        error ->
            ?LOG(warning, "unexpected_pubrec_packet", #{via => Via, packet_id => PacketId}, State),
            State
    end;

ack_inflight(Via,
  ?PUBCOMP_PACKET(PacketId, _ReasonCode, _Properties),
  State = #state{inflight = Inflight}
 ) ->
    case emqtt_inflight:delete({Via, PacketId}, Inflight) of
        {{value, ?INFLIGHT_PUBREL(Via, _PacketId, _SentAt, _ExpireAt)}, NInflight} ->
            State#state{inflight = NInflight};
        error ->
            ?LOG(warning, "unexpected_pubcomp_packet", #{packet_id => PacketId}, State),
            State
     end.

drop_expired(Pendings) ->
    case queue:is_empty(Pendings) of
        true -> Pendings;
        false -> drop_expired(Pendings, now_ts())
    end.

drop_expired(Pendings, Now) ->
    case queue:peek(Pendings) of
        {value, ?PUB_REQ(_Msg, _Via, ExpireAt, Callback)} when Now > ExpireAt ->
            {_Dropped, NPendings} = dequeue_publish_req(Pendings),
            eval_callback_handler({error, timeout}, Callback),
            drop_expired(NPendings, Now);
        _ ->
            Pendings
    end.

assign_id(Id, Ver, Props) when Id =:= ?NO_CLIENT_ID orelse Id =:= undefined ->
    case maps:find('Assigned-Client-Identifier', Props) of
        {ok, Value} ->
            Value;
        _ ->
            error(#{cause => no_client_id_assigned_by_broker, proto_ver => Ver})
    end;
assign_id(Id, _Ver, _Props) ->
    Id.

publish_qos1(Via, Packet = ?PUBLISH_PACKET(?QOS_1, PacketId),
             State0 = #state{auto_ack = AutoAck}) ->
    State = deliver(Via, packet_to_msg(Packet), State0),
    case AutoAck of
        true ->
            send_puback(Via, ?PUBACK_PACKET(PacketId), State);
        _Otherwise ->
            %% AutoAck = false | never
            {keep_state, State}
    end.

publish_qos2(Via, Packet = ?PUBLISH_PACKET(?QOS_2),
             State0 = #state{auto_ack = never}) ->
    %% AutoAck = never
    %% Deliver the message, user is responsible for the whole QoS 2 flow.
    State = deliver(Via, packet_to_msg(Packet), State0),
    {keep_state, State};
publish_qos2(Via, Packet = ?PUBLISH_PACKET(?QOS_2, PacketId),
             State0 = #state{awaiting_rel = AwaitingRel}) ->
    %% AutoAck = true | false
    %% Respond with a PUBREC first, then wait for a PUBREL.
    case send_puback(Via, ?PUBREC_PACKET(PacketId), State0) of
        {keep_state, State} ->
            AwaitingRel1 = maps:put({PacketId, Via}, Packet, AwaitingRel),
            {keep_state, State#state{awaiting_rel = AwaitingRel1}};
        Stop ->
            Stop
    end.

process_pubrel(Via, Packet, State0 = #state{auto_ack = never}) ->
    %% AutoAck = never
    %% Deliver the PUBREL, user is responsible for the rest of QoS 2 flow.
    State = deliver(Via, packet_to_pubrel(Packet, Via), State0),
    {keep_state, State};
process_pubrel(Via, ?PUBREL_PACKET(PacketId, _ReasonCode = 0),
               State0 = #state{awaiting_rel = AwaitingRel, auto_ack = AutoAck}) ->
    %% AutoAck = true | false
    %% Deliver the initial message, then respond with a PUBCOMP.
    case maps:take({PacketId, Via}, AwaitingRel) of
        {Packet, AwaitingRel1} ->
            State = deliver(Via, packet_to_msg(Packet), State0#state{awaiting_rel = AwaitingRel1}),
            case AutoAck of
                true  -> send_puback(Via, ?PUBCOMP_PACKET(PacketId), State);
                false -> {keep_state, State}
            end;
        error ->
            ?LOG(warning, "unexpected_pubrel_packet", #{packet_id => PacketId}, State0),
            keep_state_and_data
    end;
process_pubrel(Via, ?PUBREL_PACKET(PacketId, ReasonCode), State) ->
    %% AutoAck = true | false
    %% User does not expect unsuccesful PUBREL, so just log it.
    ?LOG(warning, "unsuccessful_pubrel_packet",
      #{packet_id => PacketId,
        reason_code => ReasonCode,
        reason_code_name => reason_code_name(ReasonCode),
        via => Via}, State),
    keep_state_and_data.

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

set_call_via(#call{id = OldId} = Call, Via) ->
    Call#call{id = call_id(OldId, Via)}.

add_call(Call, Data = #state{pending_calls = Calls}) ->
    Data#state{pending_calls = [Call | Calls]}.

take_call(#callid{} = Id, Data = #state{pending_calls = Calls}) ->
    case lists:keytake(Id, #call.id, Calls) of
        {value, Call, Left} ->
            {value, Call, Data#state{pending_calls = Left}};
        false ->
            false
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

ensure_retry_timer(State = #state{retry_interval = Interval, inflight = Inflight}) ->
    case emqtt_inflight:is_empty(Inflight) of
        true ->
            %% nothing to retry
            State;
        false ->
            do_ensure_retry_timer(Interval, State)
    end.

do_ensure_retry_timer(Interval, State = #state{retry_timer = undefined}) when Interval > 0 ->
    State#state{retry_timer = erlang:start_timer(Interval, self(), retry)};
do_ensure_retry_timer(_Interval, State) ->
    State.

sent_at(?INFLIGHT_PUBLISH(_Via, _, SentAt, _, _)) ->
    SentAt;
sent_at(?INFLIGHT_PUBREL(_Via, _, SentAt, _)) ->
    SentAt.

drop_overflow(State = #state{inflight = Inflight}) ->
    {Overflow, Inflight1} = emqtt_inflight:trim_overflow(Inflight),
    Overflow =/= [] andalso
        ?LOG(debug, "dropped_inflight_overflow_messages", #{dropped => Overflow}, State),
    lists:foreach(
        fun({_PacketId, ?INFLIGHT_PUBLISH(_Via, _Msg, _SentAt, _ExpireAt, Callback)}) ->
                eval_callback_handler({error, dropped}, Callback);
           ({_PacketId, _InflightPubReq}) ->
                ok
        end, Overflow),
    State#state{inflight = Inflight1}.

retry_send(State = #state{retry_interval = Intv, inflight = Inflight}) ->
    try
        Now = now_ts(),
        Pred = fun(_, InflightReq) ->
                       (sent_at(InflightReq) + Intv) =< Now
               end,
        NState = retry_send(Now, emqtt_inflight:to_retry_list(Pred, Inflight), State),
        {keep_state, ensure_retry_timer(NState)}
    catch error : Reason ->
        maybe_reconnect(Reason, State)
    end.

retry_send(Now, [{{Via, PacketId}, ?INFLIGHT_PUBLISH(_Via, Msg, _, ExpireAt, Callback)} | More],
           State = #state{inflight = Inflight}) ->
    Msg1 = Msg#mqtt_msg{dup = true},
    case send(Via, Msg1, State) of
        {ok, NState} ->
            NInflightReq = ?INFLIGHT_PUBLISH(Via, Msg1, Now, ExpireAt, Callback),
            {ok, NInflight} = emqtt_inflight:update({Via, PacketId}, NInflightReq, Inflight),
            retry_send(Now, More, NState#state{inflight = NInflight});
        {error, Reason} ->
            error(Reason)
    end;
retry_send(Now, [{{Via, PacketId}, ?INFLIGHT_PUBREL(_Via, PacketId, _, ExpireAt)} | More],
           State = #state{inflight = Inflight}) ->
    case send(Via, ?PUBREL_PACKET(PacketId), State) of
        {ok, NState} ->
            NInflightReq = ?INFLIGHT_PUBREL(Via, PacketId, Now, ExpireAt),
            {ok, NInflight} = emqtt_inflight:update({Via, PacketId}, NInflightReq, Inflight),
            retry_send(Now, More, NState#state{inflight = NInflight});
        {error, Reason} ->
            error(Reason)
    end;
retry_send(_Now, [], State) ->
    State.

deliver(Via, #mqtt_msg{qos = QoS, dup = Dup, retain = Retain, packet_id = PacketId,
                       topic = Topic, props = Props, payload = Payload},
        State) ->
    Msg = #{qos => QoS, dup => Dup, retain => Retain, packet_id => PacketId,
            topic => Topic, properties => Props, payload => Payload,
            via => Via,
            client_pid => self()},
    ok = eval_msg_handler(State, publish, Msg),
    State;
deliver(_Via, {pubrel, Msg}, State) ->
    ok = eval_msg_handler(State, pubrel, Msg),
    State.

eval_msg_handler(#state{msg_handler = ?NO_HANDLER, owner = Owner}, disconnected,
        {disconnected, ReasonCode, Properties}) when is_integer(ReasonCode) ->
    %% Special handling for disconnected message when there is no handler callback
    Owner ! {disconnected, ReasonCode, Properties},
    ok;
eval_msg_handler(#state{msg_handler = ?NO_HANDLER}, disconnected, _OtherReason) ->
    %% do nothing to be backward compatible
    ok;
eval_msg_handler(#state{msg_handler = ?NO_HANDLER,
                        owner = Owner}, Kind, Msg) ->
    Owner ! {Kind, Msg},
    ok;
eval_msg_handler(#state{msg_handler = Handler}, Kind, Msg) ->
    case maps:get(Kind, Handler, undefined) of
        undefined ->
            ok;
        F ->
            _ = apply_handler_function(F, Msg),
            ok
    end.

eval_callback_handler(_Result, ?NO_HANDLER) ->
    ok;
eval_callback_handler(Result, MFAs) ->
    _ = apply_callback_function(MFAs, Result),
    ok.

%% Msg returned at the front of args (compatible with old versions)
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

%% Result returned at the end of args
apply_callback_function(F, Result)
  when is_function(F) ->
    erlang:apply(F, [Result]);
apply_callback_function({F, A}, Result)
  when is_function(F),
       is_list(A) ->
    erlang:apply(F, A ++ [Result]);
apply_callback_function({M, F, A}, Result)
  when is_atom(M),
       is_atom(F),
       is_list(A) ->
    erlang:apply(M, F, A ++ [Result]).

maybe_reconnect(Reason, #state{reconnect = Re} = State) when ?NEED_RECONNECT(Re) ->
    enter_reconnect(Reason, State);
maybe_reconnect(Reason, State) ->
    shutdown(Reason, State).

shutdown(Reason, State) ->
    {stop, wrap_shutdown(Reason), State}.

shutdown_reply(Reason, From, Reply) ->
    {stop_and_reply, wrap_shutdown(Reason), [{reply, From, Reply}]}.

reply_all_inflight_reqs(Reason, #state{inflight = Inflight}) ->
    %% reply error to all pendings caller
    emqtt_inflight:foreach(
      fun(_PacketId, ?INFLIGHT_PUBLISH(_Via, _Msg, _SentAt, _ExpireAt, Callback)) ->
              eval_callback_handler({error, Reason}, Callback);
         (_PacketId, _InflightPubReql) ->
              ok
      end, Inflight),
    ok.

reply_all_pendings_reqs(Reason, #state{pendings = Pendings}) ->
    %% reply error to all pendings caller
    lists:foreach(
          fun(?PUB_REQ(_, _, _, Callback)) ->
                  eval_callback_handler({error, Reason}, Callback)
          end, queue:to_list(Pendings)).

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

packet_to_pubrel(?PUBREL_PACKET(PacketId, ReasonCode, Props), Via) ->
    {pubrel, #{packet_id => PacketId,
               reason_code => ReasonCode,
               properties => Props,
               via => Via}}.

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
        skip ->
            skip;
        Error = {error, _Reason} ->
            sock_connect(ConnMod, Hosts, SockOpts, Timeout, Error)
    end.

hosts(#state{hosts = [], host = Host, port = Port}) ->
    [{host(Host), Port}];
hosts(#state{hosts = Hosts}) ->
    [{host(Host), Port} || {Host, Port} <- Hosts].

host(Bin) when is_binary(Bin) -> binary_to_list(Bin);
host(Host) -> Host.

send_puback(Via, Packet, State) ->
    case send(Via, Packet, State) of
        {ok, NewState}  -> {keep_state, NewState};
        {error, Reason} -> maybe_reconnect(Reason, State)
    end.

send(Msg, State) ->
    send(default_via(State), Msg, State).

%% send(default, Msg, #state{socket = Sock} = State) ->
%%     send(Sock, Msg, State);
send(Via, Msg, State) when is_record(Msg, mqtt_msg) ->
    send(Via, msg_to_packet(Msg), State);

send(Sock, Packet, State = #state{conn_mod = ConnMod, proto_ver = Ver})
    when is_record(Packet, mqtt_packet) ->
    Data = emqtt_frame:serialize(Packet, Ver),
    case ConnMod:send(Sock, Data) of
        ok  ->
            ?LOG(debug, "send_data", #{packet => redact_packet(Packet), socket => Sock}, State),
            {ok, bump_last_packet_id(State)};
        {error, Reason} ->
            ?LOG(debug, "send_data_failed", #{reason => Reason, packet => redact_packet(Packet), socket => Sock}, State),
            {error, Reason}
    end.

run_sock(State = #state{conn_mod = emqtt_quic}) ->
    State;
run_sock(State = #state{conn_mod = ConnMod, socket = Sock}) ->
    %% error is discarded, if socket is already closed,
    %% so the next 'send' call will return {error, closed} or {error, einval}
    %% then it should decide if it should shutdown or retry
    _ = ConnMod:setopts(Sock, [{active, once}]),
    State.

%%--------------------------------------------------------------------
%% Process incomming

process_incoming(<<>>, Packets, #state{socket = Via} = State) ->
    {keep_state, State, next_events(Via, Packets)};

process_incoming(Bytes, Packets, State = #state{parse_state = ParseState, socket = Via}) ->
    try emqtt_frame:parse(Bytes, ParseState) of
        {ok, Packet, Rest, NParseState} ->
            process_incoming(Rest, [Packet|Packets], State#state{parse_state = NParseState});
        {more, NParseState} ->
            {keep_state, State#state{parse_state = NParseState}, next_events(Via, Packets)}
    catch
        error:Reason:St ->
            maybe_reconnect({parse_packets_error, Reason, St}, State)
    end.

-compile({inline, [next_events/2]}).
next_events(_Via, []) -> [];
next_events(Via, [Packet]) ->
    {next_event, cast, {Packet, Via}};
next_events(Via, Packets) ->
    [{next_event, cast, {Packet, Via}} || Packet <- lists:reverse(Packets)].

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
reason_code_name(3, _Ver) -> server_unavailable;
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

enter_reconnect(Reason, State) ->
    enter_reconnect(Reason, State, []).
enter_reconnect(Reason, #state{reconnect = Cnt, reconnect_timeout = Timeout} = State, Actions) ->
    EventContent = #{retry_cnt => Cnt, reason => Reason},
    {next_state, reconnect, prepare_reconnect(State),
        [{state_timeout, Timeout, EventContent} | Actions]}.

prepare_reconnect(#state{
        retry_timer = RetryTimer,
        keepalive_timer = KeepAliveTimer,
        sock_opts = OldSockOpts,
        ack_timer = AckTimer,
        socket = OldSocket,
        conn_mod = ConnMod
    } = State) ->
    ok = close_socket(ConnMod, OldSocket),
    ok = cancel_timer(RetryTimer),
    ok = cancel_timer(KeepAliveTimer),
    ok = cancel_timer(AckTimer),
    State1 = update_for_reconnecting(State),
    State1#state{
        sock_opts = proplists:delete(handle, OldSockOpts),
        retry_timer = undefined,
        keepalive_timer = undefined
    }.

next_retry_cnt(infinity) -> infinity;
next_retry_cnt(Cnt) -> Cnt - 1.

wrap_shutdown(normal) -> normal;
wrap_shutdown({shutdown, _} = Reason) -> Reason;
wrap_shutdown(Reason) -> {shutdown, Reason}.

unwrap_shutdown({shutdown, Reason}) -> Reason;
unwrap_shutdown(Reason) -> Reason.

close_socket(_, undefined) ->
    ok;
close_socket(_, ?socket_reconnecting) ->
    ok;
close_socket(ConnMod, Socket) ->
    _ = ConnMod:close(Socket),
    ok.

cancel_timer(undefined) ->
    ok;
cancel_timer(Tref) ->
    %% we do not care if the timer is already expired
    %% the expire event will be discarded when not in connected state
    _ = erlang:cancel_timer(Tref),
    ok.

-spec qoe_inject(atom(), state()) -> state().
qoe_inject(_Tag, #state{qoe = false} = S) ->
    S;
qoe_inject(Tag, #state{qoe = true} = S) ->
    TS = erlang:monotonic_time(millisecond),
    S#state{qoe = #{Tag => TS}};
qoe_inject(Tag, #state{qoe = QoE} = S) when is_map(QoE) ->
    TS = erlang:monotonic_time(millisecond),
    S#state{qoe = QoE#{ Tag => TS}}.

now_ts() ->
    erlang:system_time(millisecond).

-spec maybe_init_quic_state(module(), #state{}) -> #state{}.
maybe_init_quic_state(emqtt_quic, Old = #state{extra = #{control_stream_sock := {quic, _, _} }}) ->
    %% Already opened
    Old;
maybe_init_quic_state(emqtt_quic, State) ->
    do_init_quic_state(State);
maybe_init_quic_state(_, Old) ->
    Old.

do_init_quic_state(#state{extra = Extra, clientid = Cid,
                          reconnect = Re, parse_state = PS} = Old) ->
    Old#state{extra = emqtt_quic:init_state(Extra#{ clientid => Cid
                                                  , conn_parse_state => PS %% set once
                                                  , data_stream_socks => []
                                                  , logic_stream_map => #{}
                                                  , control_stream_sock => undefined
                                                  , reconnect => ?NEED_RECONNECT(Re)})}.

update_data_streams(#{ data_stream_socks := Socks
                     , conn_parse_state := PS
                     , stream_parse_state := PSS
                     } = Extra, NewSock) ->
    Extra#{ data_stream_socks := [ NewSock | Socks ]
          , stream_parse_state := PSS#{NewSock => PS}
          }.

update_data_streams(#{ data_stream_socks := Socks
                     , conn_parse_state := PS
                     , logic_stream_map := LSM
                     , stream_parse_state := PSS
                     } = Extra, LogicStreamId, NewSock) ->
    Extra#{ data_stream_socks := [ NewSock | Socks ]
          , logic_stream_map := LSM#{LogicStreamId => NewSock}
          , stream_parse_state := PSS#{NewSock => PS}
          }.

get_logic_stream(#{logic_stream_map := LSM}, ID) ->
    maps:get(ID, LSM, undefined).

maybe_update_ctrl_sock(emqtt_quic, #state{socket = {quic, Conn, Stream}
                                         } = OldState, _Sock)
  when Stream =/= undefined andalso Conn =/= undefined ->
    OldState;
maybe_update_ctrl_sock(emqtt_quic, #state{ extra = #{conn_parse_state := PS} = OldExtra
                                         } = OldState, Sock) ->
    OldState#state{ extra = OldExtra#{ control_stream_sock := Sock
                                     , stream_parse_state => #{Sock => PS} %% Clone Connection PS
                                     }
                  , socket = Sock
                  };
maybe_update_ctrl_sock(_, Old, _) ->
    Old.

-spec maybe_new_stream(via(), #state{}) -> {inet:socket() | emqtt_quic:quic_sock(), #state{}}.
maybe_new_stream({new_data_stream, StreamOpts}, #state{conn_mod = emqtt_quic,
                                                       socket = {quic, Conn, _Stream},
                                                       extra = Extra
                                                      } = State) ->
    %% @TODO handle error
    {ok, NewStream} = quicer:start_stream(Conn, StreamOpts),
    NewSock = {quic, Conn, NewStream},
    NewState = State#state{extra = update_data_streams(Extra, NewSock)},
    {NewSock, NewState};
maybe_new_stream({logic_stream_id, LSID, StreamOpts}, #state{conn_mod = emqtt_quic,
                                                       socket = {quic, Conn, _Stream},
                                                       extra = Extra
                                                      } = State) ->
    case get_logic_stream(Extra, LSID) of
        undefined ->
            {ok, NewStream} = quicer:start_stream(Conn, StreamOpts),
            P = maps:get(priority, StreamOpts, undefined),
            is_integer(P) andalso
                            (begin ok = quicer:setopt(NewStream, priority, P),
                             {ok, P} = quicer:getopt(NewStream, priority, false)
                             end),
            NewSock = {quic, Conn, NewStream},
            NewState = State#state{extra = update_data_streams(Extra, LSID, NewSock)},
            {NewSock, NewState};
        Sock ->
            {Sock, State}
    end;
maybe_new_stream(Def, State) ->
    {Def, State}.

%% @doc use socket as default via
-spec default_via(#state{}) -> via().
default_via(#state{socket = Via})->
    Via.

%% Update #state{} for reconnecting, forget about old connections.
update_for_reconnecting(#state{socket = Socket, pending_calls = Calls} = State0)
  when Socket =/= ?socket_reconnecting ->
    NewSocket = ?socket_reconnecting,
    PendingCalls = refresh_calls(Calls, ?socket_reconnecting),
    State1 = maybe_reinit_quic_state(State0),
    State1#state{socket = NewSocket, pending_calls = PendingCalls}.

maybe_reinit_quic_state(#state{extra = #{control_stream_sock := _}} = S) ->
    do_init_quic_state(S);
maybe_reinit_quic_state(S) ->
    S.

refresh_calls(Calls, Via) ->
    lists:map(fun(X)-> set_call_via(X, Via) end, Calls).

%% @doc avoid sensitive data leakage in the debug log
redact_packet(#mqtt_packet{variable = #mqtt_packet_connect{} = Conn} = Packet) ->
    Packet#mqtt_packet{variable = Conn#mqtt_packet_connect{password = <<"******">>}};
redact_packet(Packet) ->
    Packet.

-spec call_id(opname(),
              via(),
              packet_id() | undefined
             ) -> callid().
call_id(Op, Via, PacketId) ->
    #callid{op = Op, via = Via, packet_id = PacketId}.

-spec call_id(callid() | opname(), via()) -> callid().
call_id(#callid{} = C, Via) ->
    C#callid{via = Via};
call_id(Op, Via) when is_atom(Op) ->
    call_id(Op, Via, undefined).


maybe_qoe_tcp(#state{qoe = false} = S) ->
    S;
maybe_qoe_tcp(#state{qoe = QoE} = S) when is_map(QoE) ->
    S#state{qoe = QoE#{tcp_connected_at => get(tcp_connected_at)}}.

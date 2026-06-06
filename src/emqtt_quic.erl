%%-------------------------------------------------------------------------
%% Copyright (c) 2021-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
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

%% @doc QUIC transport for emqtt, backed by the pure-Erlang `quic' library.
-module(emqtt_quic).
-include("logger.hrl").

-define(LOG(Level, Msg, Meta, State),
        ?SLOG(Level, maps:merge(#{msg => Msg, clientid => maps:get(clientid, State)}, Meta), #{})).

-export([ connect/4
        , send/2
        , close/1
        , open_connection/3
        , open_stream/1
        , open_stream/2
        ]).

-export([ getstat/2
        , sockname/1
        ]).

-export([ init_state/2
        , has_ctrl_stream/1
        , set_ctrl_stream/2
        , add_data_stream/2
        , add_logic_stream/3
        , get_logic_stream/2
        ]).

-export([handle_info/3]).

-export_type([quic_sock/0]).

-type cb_data() :: #{ clientid := binary()
                    , conn_parse_state := emqtt_frame:parse_state()
                    , stream_parse_state := #{ quic_sock() => emqtt_frame:parse_state() }
                    , data_stream_socks := [quic_sock()]
                    , control_stream_sock := undefined | quic_sock()
                    , logic_stream_map := #{non_neg_integer() => quic_sock()}
                    }.
-type conn() :: pid().
-type stream() :: non_neg_integer().
-type quic_sock() :: {quic, conn(), stream()}.
-type quic_msg() :: {quic, conn(), tuple()}.

-spec init_state(binary(), emqtt_frame:parse_state()) -> cb_data().
init_state(ClientId, ParseState) ->
    #{ clientid => ClientId
     , conn_parse_state => ParseState
     , stream_parse_state => #{}
     , data_stream_socks => []
     , logic_stream_map => #{}
     , control_stream_sock => undefined
     }.

-spec has_ctrl_stream(cb_data()) -> boolean().
has_ctrl_stream(#{control_stream_sock := {quic, _, _}}) -> true;
has_ctrl_stream(_) -> false.

-spec set_ctrl_stream(quic_sock(), cb_data()) -> cb_data().
set_ctrl_stream(Sock, #{conn_parse_state := PS, stream_parse_state := PSS} = CBData) ->
    CBData#{ control_stream_sock := Sock
           , stream_parse_state := PSS#{Sock => PS}
           }.

-spec add_data_stream(quic_sock(), cb_data()) -> cb_data().
add_data_stream(Sock, #{ data_stream_socks := Socks
                       , conn_parse_state := PS
                       , stream_parse_state := PSS
                       } = CBData) ->
    CBData#{ data_stream_socks := [Sock | Socks]
           , stream_parse_state := PSS#{Sock => PS}
           }.

-spec add_logic_stream(non_neg_integer(), quic_sock(), cb_data()) -> cb_data().
add_logic_stream(LogicId, Sock, #{logic_stream_map := LSM} = CBData) ->
    add_data_stream(Sock, CBData#{logic_stream_map := LSM#{LogicId => Sock}}).

-spec get_logic_stream(non_neg_integer(), cb_data()) -> quic_sock() | undefined.
get_logic_stream(LogicId, #{logic_stream_map := LSM}) ->
    maps:get(LogicId, LSM, undefined).

%% @doc Establish a connection and open the control stream. Blocks until
%% the QUIC handshake completes; the synchronous contract matches the one
%% emqtt's state machine expects from any `ConnMod:connect/4'.
-spec connect(inet:hostname() | inet:ip_address(), inet:port_number(),
              proplists:proplist(), timeout())
             -> {ok, quic_sock()} | skip | {error, term()}.
connect(Host, Port, Opts, Timeout) ->
    case proplists:is_defined(handle, Opts) of
        true ->
            skip;
        false ->
            case do_connect(Host, Port, Opts, Timeout) of
                {ok, Conn} ->
                    case open_stream(Conn) of
                        {ok, Stream} ->
                            {ok, {quic, Conn, Stream}};
                        {error, _} = Error ->
                            _ = quic:safe_close(Conn),
                            Error
                    end;
                {error, _} = Error ->
                    Error
            end
    end.

%% @doc Connect without opening a stream; pairs with `emqtt:quic_mqtt_connect/1'.
-spec open_connection([{inet:hostname() | inet:ip_address(), inet:port_number()}],
                      proplists:proplist(), timeout())
                     -> {ok, conn()} | {error, term()}.
open_connection([{Host, Port} | _], Opts, Timeout) ->
    do_connect(Host, Port, Opts, Timeout).

-spec open_stream(conn()) -> {ok, stream()} | {error, term()}.
open_stream(Conn) ->
    quic:open_stream(Conn).

%% Supported stream options: `priority' (non_neg_integer urgency).
-spec open_stream(conn(), map() | proplists:proplist()) -> {ok, stream()} | {error, term()}.
open_stream(Conn, StreamOpts) when is_list(StreamOpts) ->
    open_stream(Conn, maps:from_list(StreamOpts));
open_stream(Conn, StreamOpts) when is_map(StreamOpts) ->
    case quic:open_stream(Conn) of
        {ok, Stream} = OK ->
            case maps:get(priority, StreamOpts, undefined) of
                P when is_integer(P) ->
                    ok = quic:set_stream_priority(Conn, Stream, P, false);
                _ ->
                    ok
            end,
            OK;
        Error ->
            Error
    end.

do_connect(Host, Port, Opts, Timeout) ->
    ConnOpts = conn_opts(Host, Opts, Timeout),
    case quic:connect(Host, Port, ConnOpts, self()) of
        {ok, Conn} ->
            case wait_connected(Conn, Timeout) of
                ok -> {ok, Conn};
                {error, _} = Error ->
                    _ = quic:safe_close(Conn),
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

wait_connected(Conn, Timeout) ->
    receive
        {quic, Conn, {connected, _Info}} -> ok;
        {quic, Conn, {Tag, Reason}} when Tag =:= closed; Tag =:= error -> {error, Reason}
    after Timeout ->
        {error, timeout}
    end.

send({quic, Conn, Stream}, Bin) ->
    quic:send_data(Conn, Stream, Bin, false).

%% Stub: QUIC keepalive uses `last_packet_id' (see `emqtt:should_ping/1');
%% the byte counters fetched by the generic keepalive path are unused.
getstat({quic, _Conn, _Stream}, Options) ->
    {ok, [{Opt, 0} || Opt <- Options]}.

close({quic, Conn, _Stream}) ->
    quic:close(Conn).

sockname({quic, Conn, _Stream}) ->
    quic:sockname(Conn).

-spec handle_info(quic_msg(), atom(), cb_data()) -> gen_statem:event_handler_result(atom()).
handle_info({quic, Conn, Inner}, _StateName, CBData) ->
    handle_event(Inner, Conn, CBData).

%% A peer FIN closes the read side; for the control stream that's the
%% MQTT session ending.
handle_event({stream_data, StreamId, Bin, Fin}, Conn, CBData) ->
    Via = {quic, Conn, StreamId},
    case handle_stream_data(Via, Bin, CBData) of
        {stop, _, _} = Stop ->
            Stop;
        {keep_state, CBData1, Actions} when Fin ->
            {CBData2, CloseActions} = on_stream_closed(Via, Conn, CBData1),
            {keep_state, CBData2, Actions ++ CloseActions};
        {keep_state, _, _} = Result ->
            Result
    end;

handle_event({connected, _Info}, _Conn, _CBData) ->
    keep_state_and_data;

handle_event({session_ticket, Ticket}, _Conn, #{clientid := Cid}) ->
    try ets:insert(quic_clients_nsts, {Cid, Ticket}) catch _:_ -> ok end,
    keep_state_and_data;

%% Stale events for an old connection (e.g. lingering in the mailbox
%% across a reconnect) are ignored — only the active ctrl-stream conn
%% drives state transitions.
handle_event({closed, _Reason}, Conn, CBData) ->
    case is_active_conn(Conn, CBData) of
        true ->
            ?LOG(info, "quic_connection_closed", #{}, CBData),
            {keep_state, CBData, [{next_event, info, {quic_closed, Conn}}]};
        false ->
            keep_state_and_data
    end;

handle_event({Tag, StreamId, _ErrorCode}, Conn, CBData)
  when Tag =:= stream_reset; Tag =:= stop_sending ->
    {NewCBData, Actions} = on_stream_closed({quic, Conn, StreamId}, Conn, CBData),
    {keep_state, NewCBData, Actions};

handle_event(_Other, _Conn, _CBData) ->
    keep_state_and_data.

handle_stream_data(Via, Bin, #{stream_parse_state := PSS} = CBData) ->
    ?LOG(debug, "recv_data", #{data => Bin}, CBData),
    case maps:get(Via, PSS, undefined) of
        undefined ->
            ?LOG(warning, "unknown_stream_data", #{stream => Via}, CBData),
            {stop, {unknown_stream_data, Via}, CBData};
        PS ->
            case emqtt_frame:parse_all(Bin, PS) of
                {ok, Packets, NewPS} ->
                    {keep_state, CBData#{stream_parse_state := PSS#{Via => NewPS}},
                     [{next_event, cast, {P, Via}} || P <- Packets]};
                {error, Reason} ->
                    {stop, Reason, CBData}
            end
    end.

is_active_conn(Conn, #{control_stream_sock := {quic, Conn, _}}) -> true;
is_active_conn(_Conn, _CBData) -> false.

on_stream_closed(Via, Conn, #{ data_stream_socks := DataStreams
                             , stream_parse_state := PSS
                             , control_stream_sock := CtrlSock
                             } = CBData) ->
    case lists:member(Via, DataStreams) of
        true ->
            {CBData#{ data_stream_socks := lists:delete(Via, DataStreams)
                    , stream_parse_state := maps:remove(Via, PSS)
                    }, []};
        false when Via =:= CtrlSock ->
            {CBData, [{next_event, info, {quic_closed, Conn}}]};
        false ->
            ?LOG(warning, "unknown_stream_closed", #{stream => Via}, CBData),
            {CBData, []}
    end.

-spec conn_opts(inet:hostname() | inet:ip_address(), proplists:proplist(), timeout())
               -> map().
conn_opts(Host, SockOpts, Timeout) ->
    {UserConnOpts, _} = proplists:get_value(quic_opts, SockOpts, {[], []}),
    SslOpts = proplists:get_value(ssl_opts, SockOpts, []),
    Pairs = [{alpn,            [<<"mqtt">>]},
             {verify,          translate_verify(proplists:get_value(verify, SockOpts, verify_none))},
             {connect_timeout, translate_timeout(Timeout)},
             {server_name,     sni(SslOpts, Host)},
             {cacerts,         proplists:get_value(cacerts, SslOpts)},
             {session_ticket,  proplists:get_value(nst, SockOpts)}],
    Derived = maps:from_list([KV || {_, V} = KV <- Pairs, V =/= undefined]),
    %% User-supplied quic_opts override the derived defaults.
    maps:merge(Derived, maps:from_list(UserConnOpts)).

translate_timeout(infinity) -> undefined;
translate_timeout(T)        -> T.

translate_verify(verify_none)            -> false;
translate_verify(verify_peer)            -> true;
translate_verify(B) when is_boolean(B)   -> B.

%% Derive SNI from Host unless explicitly set. An IP address is not a valid
%% SNI, so it yields `undefined`.
sni(SslOpts, Host) ->
    case proplists:get_value(server_name_indication, SslOpts) of
        S when is_binary(S) -> S;
        S when is_list(S)   -> list_to_binary(S);
        _                   -> host_to_sni(Host)
    end.

host_to_sni(H) when is_binary(H) -> H;
host_to_sni(H) when is_list(H)   -> list_to_binary(H);
host_to_sni(_)                   -> undefined.  % IP address tuple

%%-------------------------------------------------------------------------
%% Copyright (c) 2021-2022 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqtt_quic).

-ifndef(BUILD_WITHOUT_QUIC).
-include_lib("quicer/include/quicer.hrl").
-else.
-define(QUIC_STREAM_SHUTDOWN_FLAG_NONE          , 0).
-define(QUICER_CONNECTION_EVENT_MASK_NST        , 1).
-define(QUIC_STREAM_SHUTDOWN_FLAG_GRACEFUL      , 1).
-endif.

-export([ connect/4
        , send/2
        , recv/2
        , close/1
        ]).

-export([ setopts/2
        , getstat/2
        , sockname/1
        ]).

connect(Host, Port, Opts, Timeout) ->
    KeepAlive =  proplists:get_value(keepalive, Opts, 60),
    ConnOpts = [ {alpn, ["mqtt"]}
               , {idle_timeout_ms, timer:seconds(KeepAlive * 3)}
               , {handshake_idle_timeout_ms, 3000}
               , {peer_unidi_stream_count, 1}
               , {peer_bidi_stream_count, 1}
               , {quic_event_mask, ?QUICER_CONNECTION_EVENT_MASK_NST}
               %% uncomment for decrypt wireshark trace
               %%, {sslkeylogfile, "/tmp/SSLKEYLOGFILE"}
               | Opts] ++ local_addr(Opts),
    case quicer:connect(Host, Port, ConnOpts, Timeout) of
        {ok, Conn} ->
            case quicer:start_stream(Conn, [{active, false}]) of
                {ok, Stream} ->
                    {ok, {quic, Conn, Stream}};
                Error ->
                    Error
            end;
        {error, transport_down, Reason} ->
            {error, {transport_down, Reason}};
        {error, _} = Error ->
            Error
    end.

send({quic, _Conn, Stream}, Bin) ->
    case quicer:async_send(Stream, Bin) of
        {ok, _Len} ->
            ok;
        Other ->
            Other
    end.

recv({quic, _Conn, Stream}, Count) ->
    quicer:recv(Stream, Count).

getstat({quic, Conn, _Stream}, Options) ->
    quicer:getstat(Conn, Options).

setopts({quic, _Conn, Stream}, Opts) ->
    [ ok = quicer:setopt(Stream, Opt, OptV)
      || {Opt, OptV} <- Opts ],
    ok.

close({quic, Conn, Stream}) ->
    quicer:async_shutdown_stream(Stream, ?QUIC_STREAM_SHUTDOWN_FLAG_GRACEFUL, 0),
    timer:sleep(100),
    quicer:close_connection(Conn).

sockname({quic, Conn, _Stream}) ->
    quicer:sockname(Conn).

local_addr(SOpts) ->
    case { proplists:get_value(port, SOpts, 0),
           proplists:get_value(ip, SOpts, undefined)} of
        {0, undefined} ->
            [];
        {Port, undefined} ->
            [{param_conn_local_address, ":" ++ integer_to_list(Port)}];
        {Port, IpAddr} when is_tuple(IpAddr) ->
            [{param_conn_local_address, inet:ntoa(IpAddr) ++ ":" ++integer_to_list(Port)}]
    end.

%%-------------------------------------------------------------------------
%% Copyright (c) 2020-2022 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqtt_ws).

-export([ connect/4
        , send/2
        , close/1
        ]).

-export([ setopts/2
        , getstat/2
        ]).

-type option() :: {ws_path, string()}.
-type connection() :: {_Conn :: pid(), gun:stream_ref()}.

-export_type([option/0, connection/0]).

-define(WS_OPTS, #{compress => false,
                   protocols => [{<<"mqtt">>, gun_ws_h}]
                  }).

-define(WS_HEADERS, [{<<"cache-control">>, <<"no-cache">>}]).

connect(Host0, Port, Opts, Timeout) ->
    Host1 = convert_host(Host0),
    {ok, _} = application:ensure_all_started(gun),
    %% 1. open connection
    TransportOptions = proplists:get_value(ws_transport_options, Opts, []),
    ConnOpts = opts(TransportOptions, #{connect_timeout => Timeout,
                                        retry => 0}),
    case gun:open(Host1, Port, ConnOpts) of
        {ok, ConnPid} ->
            case gun:await_up(ConnPid, Timeout) of
                {ok, _} ->
                    case upgrade(ConnPid, Opts, Timeout) of
                        {ok, StreamRef} -> {ok, {ConnPid, StreamRef}};
                        Error -> Error
                    end;
                Error ->
                    Error
            end;
        Error ->
            Error
    end.

opts([], Acc) -> Acc;
opts([{Name, Value} | More], Acc) ->
    opts(More, Acc#{Name => Value}).

-spec(upgrade(pid(), list(), timeout())
      -> {ok, Headers :: list()} | {error, Reason :: term()}).
upgrade(ConnPid, Opts, Timeout) ->
    %% 2. websocket upgrade
    Path = proplists:get_value(ws_path, Opts, "/mqtt"),
    CustomHeaders = proplists:get_value(ws_headers, Opts, []),
    StreamRef = gun:ws_upgrade(ConnPid, Path, ?WS_HEADERS ++ CustomHeaders, ?WS_OPTS),
    receive
        {gun_upgrade, ConnPid, StreamRef, [<<"websocket">>], _Headers} ->
            {ok, StreamRef};
        {gun_response, ConnPid, _, _, Status, Headers} ->
            {error, {ws_upgrade_failed, Status, Headers}};
        {gun_error, ConnPid, StreamRef, Reason} ->
            {error, {ws_upgrade_failed, Reason}};
        {gun_down, ConnPid, _, Reason, _} ->
            {error, {ws_upgrade_failed, Reason}}
    after Timeout ->
        {error, timeout}
    end.

%% fake stats:)
getstat(_WsPid, Options) ->
    {ok, [{Opt, 0} || Opt <- Options]}.

setopts(_WsPid, _Opts) ->
    ok.

-spec(send({pid(), gun:stream_ref()}, iodata()) -> ok).
send({WsPid, StreamRef}, Data) ->
    gun:ws_send(WsPid, StreamRef, {binary, Data}).

-spec(close({pid(), gun:stream_ref()}) -> ok).
close({WsPid, _StreamRef}) ->
    gun:shutdown(WsPid).

-spec convert_host(inet:ip_address() | inet:hostname()) -> inet:hostname().
convert_host(Host) ->
    case Host of
        %% `inet:is_ip_address/1` is available since OTP 25
        Ip4 when is_tuple(Ip4) andalso tuple_size(Ip4) =:= 4 -> inet:ntoa(Host);
        Ip6 when is_tuple(Ip6) andalso tuple_size(Ip6) =:= 8 -> inet:ntoa(Host);
        _ -> Host
    end.

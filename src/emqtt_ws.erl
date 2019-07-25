%%--------------------------------------------------------------------
%% Copyright (c) 2019 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqtt_ws).

-export([ connect/4
        , send/2
        , close/1
        ]).

-define(WS_OPTS, #{compress => false,
                   protocols => [{<<"mqtt">>, gun_ws_h}]
                  }).

connect(Host, Port, WsOpts, Timeout) ->
    {ok, _} = application:ensure_all_started(gun),
    %% 1. open connection
    ConnOpts = #{connect_timeout => Timeout,
                 retry => 3,
                 retry_timeout => 30000
                },
    case gun:open(Host, Port, ConnOpts) of
        {ok, ConnPid} ->
            {ok, _} = gun:await_up(ConnPid, Timeout),
            case upgrade(ConnPid, WsOpts, Timeout) of
                {ok, _Headers} -> {ok, ConnPid};
                Error -> Error
            end;
        Error -> Error
    end.

-spec(upgrade(pid(), list(), timeout())
      -> {ok, Headers :: list()} | {error, Reason :: term()}).
upgrade(ConnPid, WsOpts, Timeout) ->
    %% 2. websocket upgrade
    Path = proplists:get_value(ws_path, WsOpts, "/mqtt"),
    StreamRef = gun:ws_upgrade(ConnPid, Path, [], ?WS_OPTS),
    receive
        {gun_upgrade, ConnPid, StreamRef, [<<"websocket">>], Headers} ->
            {ok, Headers};
        {gun_response, ConnPid, _, _, Status, Headers} ->
            {error, {ws_upgrade_failed, Status, Headers}};
        {gun_error, ConnPid, StreamRef, Reason} ->
            {error, {ws_upgrade_failed, Reason}}
    after Timeout ->
        {error, timeout}
    end.

-spec(send(pid(), iodata()) -> ok).
send(WsPid, Data) ->
    gun:ws_send(WsPid, {binary, Data}).

-spec(close(pid()) -> ok).
close(WsPid) ->
    gun:shutdown(WsPid).


%%--------------------------------------------------------------------
%% Copyright (c) 2021 EMQ Technologies Co., Ltd. All Rights Reserved.
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
-module(quic_server).

-export([ start_link/2
        , stop/1
        ]).

start_link(Port, Opts) ->
    spawn_link(fun() -> quic_server(Port, Opts) end).

quic_server(Port, Opts) ->
    {ok, L} = quicer:listen(Port, Opts),
    server_loop(L).

server_loop(L) ->
    {ok, Conn} = quicer:accept(L, [], 10000),
    {ok, Stm} = quicer:accept_stream(Conn, 10000),
    receive
        {quic, <<"ping">>, _, _, _, _} ->
            quicer:send(Stm, <<"pong">>),
            server_loop(L);
        stop -> ok
    end.

stop(Server) ->
    Server ! stop.


%%--------------------------------------------------------------------
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
%%--------------------------------------------------------------------
-module(quic_server).

-export([ start_link/2
        , stop/1
        ]).

start_link(Port, Opts) ->
    spawn_link(fun() -> quic_server(Port, Opts) end).

quic_server(Port, Opts) ->
    {ok, L} = quicer:listen(Port, Opts),
    spawn_link(fun() -> accepter_loop(L) end),
    spawn_link(fun() -> accepter_loop(L) end),
    receive
        stop ->
            quicer:close_listener(L),
            ok
    end.

accepter_loop(L) ->
    case quicer:accept(L, [], 30000) of
        {ok, Conn} ->
            case quicer:handshake(Conn, 1000) of
                {ok, Conn} ->
                    server_conn_loop(Conn);
                _ ->
                    ct:pal("server handshake failed~n", []),
                    ok
            end;
        {error, timeout} ->
            ct:pal("server accpet conn timeout ~n", []),
            ok
    end,
    accepter_loop(L).


server_conn_loop(Conn) ->
    case quicer:accept_stream(Conn, [{active, false}]) of
        {ok, Stm} ->
            %% Assertion
            {ok, false} = quicer:getopt(Stm, active),
            server_stream_loop(Conn, Stm);
        {error, timeout} ->
            ct:pal("server accpet steam timeout ~n", []),
            ok
    end.

server_stream_loop(Conn, Stm) ->
    quicer:setopt(Stm, active, true),
    receive
        {quic, <<"ping">>, Stm, #{}} ->
            quicer:send(Stm, <<"pong">>)
    end,
    receive
        %% graceful shutdown
        {quic, peer_send_shutdown, Stm, undefined} ->
            quicer:close_connection(Conn);
        %% Conn shutdown
        {quic, shutdown, Conn, _} ->
            ok
    end.

stop(Server) ->
    Server ! stop.

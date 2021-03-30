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
-module(emqtt_quic_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("eunit/include/eunit.hrl").

all() -> emqx_ct:all(?MODULE).

t_quic_sock(Config) ->
    Port = 4567,
    SslOpts = [{cert, certfile(Config)},
               {key,  keyfile(Config)}
              ],
    Server = quic_server:start_link(Port, SslOpts),
    {ok, Sock} = emqtt_quic:connect("127.0.0.1", Port, [], 3000),
    send_and_recv_with(Sock),
    ok = emqtt_quic:close(Sock),
    quic_server:stop(Server).

send_and_recv_with(Sock) ->
    {ok, {{127,0,0,1}, _}} = emqtt_quic:sockname(Sock),
    ok = emqtt_quic:send(Sock, <<"ping">>),
    {ok, <<"pong">>} = emqtt_quic:recv(Sock, 0),
    ok = emqtt_quic:setopts(Sock, [{active, 100}]),
    {ok, Stats} = emqtt_quic:getstat(Sock, [send_cnt, recv_cnt]),
    [{send_cnt, Cnt}, {recv_cnt, Cnt}] = Stats,
    %% @todo impl counting.
    ?assert((Cnt == 1) or (Cnt == 3) or (Cnt==todo)).

%%--------------------------------------------------------------------
%% Helper functions
%%--------------------------------------------------------------------

certfile(Config) ->
    filename:join([test_dir(Config), "certs", "test.crt"]).

keyfile(Config) ->
    filename:join([test_dir(Config), "certs", "test.key"]).

test_dir(Config) ->
    filename:dirname(filename:dirname(proplists:get_value(data_dir, Config))).

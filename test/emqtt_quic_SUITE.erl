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

all() -> emqx_common_test_helpers:all(?MODULE).

init_per_suite(Config) ->
    emqtt_test_lib:start_emqx(),
    application:ensure_all_started(quicer),
    Config.

end_per_suite(_) ->
    emqtt_test_lib:stop_emqx(),
    ok.

t_quic_sock(Config) ->
    Port = 4567,
    SslOpts = [ {cert, certfile(Config)}
              , {key,  keyfile(Config)}
              , {idle_timeout_ms, 10000}
              , {server_resumption_level, 2} % QUIC_SERVER_RESUME_AND_ZERORTT
              , {peer_bidi_stream_count, 10}
              , {alpn, ["mqtt"]}
              ],
    Server = quic_server:start_link(Port, SslOpts),
    timer:sleep(500),
    {ok, Sock} = emqtt_quic:connect("localhost",
                                    Port,
                                    [{alpn, ["mqtt"]}, {active, false}],
                                    3000),
    send_and_recv_with(Sock),
    ok = emqtt_quic:close(Sock),
    quic_server:stop(Server).

send_and_recv_with(Sock) ->
    {ok, {IP, _}} = emqtt_quic:sockname(Sock),
    ?assert(lists:member(tuple_size(IP), [4, 8])),
    ok = emqtt_quic:send(Sock, <<"ping">>),
    {ok, <<"pong">>} = emqtt_quic:recv(Sock, 0),
    ok = emqtt_quic:setopts(Sock, [{active, 100}]),
    {ok, Stats} = emqtt_quic:getstat(Sock, [send_cnt, recv_cnt]),
    %% connection level counters, not stream level
    [{send_cnt, _}, {recv_cnt, _}] = Stats.

%%--------------------------------------------------------------------
%% Helper functions
%%--------------------------------------------------------------------

certfile(Config) ->
    filename:join([test_dir(Config), "certs", "test.crt"]).

keyfile(Config) ->
    filename:join([test_dir(Config), "certs", "test.key"]).

test_dir(Config) ->
    filename:dirname(filename:dirname(proplists:get_value(data_dir, Config))).

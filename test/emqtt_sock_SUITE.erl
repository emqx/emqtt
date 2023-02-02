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

-module(emqtt_sock_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

all() -> emqx_common_test_helpers:all(?MODULE) ++ [{group, all}].

groups() ->
    [ {all, [ {group, unknown_ca}
            , {group, known_ca}
            ]}
    , {unknown_ca, [ {group, server}
                   , {group, wildcard_server}
                   ]}
    , {known_ca, [ {group, server}
                 , {group, wildcard_server}
                 ]}
    , {server, [ {group, server_verify_peer}
               , {group, server_verify_none}
               ]}
    , {wildcard_server, [ {group, server_verify_peer}
                        , {group, server_verify_none}
                        ]}
    , {server_verify_peer, [ {group, client_verify_peer}
                           , {group, client_verify_none}
                           ]}
    , {server_verify_none, [ {group, client_verify_peer}
                           , {group, client_verify_none}
                           ]}
    , {client_verify_peer, [gen_connect_test]}
    , {client_verify_none, [gen_connect_test]}
    ].

init_per_group(all, Config) ->
    Config;
init_per_group(unknown_ca, Config) ->
    [{is_same_ca, false} | Config];
init_per_group(known_ca, Config) ->
    [{is_same_ca, true} | Config];
init_per_group(client_verify_peer, Config) ->
    [{client_verify, verify_peer} | Config];
init_per_group(client_verify_none, Config) ->
    [{client_verify, verify_none} | Config];
init_per_group(wildcard_server, Config) ->
    [{is_wildcard_server, true} | Config];
init_per_group(server, Config) ->
    [{is_wildcard_server, false} | Config];
init_per_group(server_verify_peer, Config) ->
    [{server_verify, verify_peer} | Config];
init_per_group(server_verify_none, Config) ->
    [{server_verify, verify_none} | Config].

end_per_group(all, Config) ->
    Config;
end_per_group(unknown_ca, Config) ->
    proplists:delete(is_same_ca, Config);
end_per_group(known_ca, Config) ->
    proplists:delete(is_same_ca, Config);
end_per_group(client_verify_peer, Config) ->
    proplists:delete(client_verify, Config);
end_per_group(client_verify_none, Config) ->
    proplists:delete(client_verify, Config);
end_per_group(wildcard_server, Config) ->
    proplists:delete(is_wildcard_server, Config);
end_per_group(server, Config) ->
    proplists:delete(is_wildcard_server, Config);
end_per_group(server_verify_peer, Config) ->
    proplists:delete(server_verify, Config);
end_per_group(server_verify_none, Config) ->
    proplists:delete(server_verify, Config).


init_per_suite(Config) ->
    emqtt_test_lib:ensure_test_module(emqx_common_test_helpers),
    DataDir = cert_dir(Config),
    _ = emqtt_test_lib:gen_ca(DataDir, "ca"),
    _ = emqtt_test_lib:gen_host_cert("wildcard.localhost", "ca", DataDir, true),
    _ = emqtt_test_lib:gen_host_cert("localhost", "ca", DataDir),
    _ = emqtt_test_lib:gen_host_cert("client", "ca", DataDir),
    _ = emqtt_test_lib:gen_ca(DataDir, "other-ca"),
    _ = emqtt_test_lib:gen_host_cert("other-client", "other-ca", DataDir),

    [ %% Clients
      {unknown_client_cert_files, [{cacertfile, emqtt_test_lib:ca_cert_name(DataDir, "other-ca")},
                                   {keyfile,  emqtt_test_lib:key_name(DataDir, "other-client")},
                                   {certfile,  emqtt_test_lib:cert_name(DataDir, "other-client")},
                                   {server_name_indication, true}
                                  ]}
    , {known_client_cert_files, [{cacertfile, emqtt_test_lib:ca_cert_name(DataDir, "ca")},
                                 {keyfile,  emqtt_test_lib:key_name(DataDir, "client")},
                                 {certfile,  emqtt_test_lib:cert_name(DataDir, "client")},
                                 {server_name_indication, true}
                                ]}
      %% Servers
    , {wildcard_server_cert_files, [{cacertfile, emqtt_test_lib:ca_cert_name(DataDir, "ca")},
                                    {keyfile,  emqtt_test_lib:key_name(DataDir, "wildcard.localhost")},
                                    {certfile,  emqtt_test_lib:cert_name(DataDir, "wildcard.localhost")}
                                   ]}
    , {common_server_cert_files, [{cacertfile, emqtt_test_lib:ca_cert_name(DataDir, "ca")},
                                  {keyfile,  emqtt_test_lib:key_name(DataDir, "localhost")},
                                  {certfile,  emqtt_test_lib:cert_name(DataDir, "localhost")}
                                 ]}
    | Config].

end_per_suite(_Config) ->
    ok.

init_per_testcase(gen_connect_test, Config) ->
    ServerVerify = ?config(server_verify, Config),
    ClientVerify = ?config(client_verify, Config),
    IsWildcard = ?config(is_wildcard_server, Config),
    IsSameCA = ?config(is_same_ca, Config),

    ServerFiles = case IsWildcard of
                      true -> ?config(wildcard_server_cert_files , Config);
                      false -> ?config(common_server_cert_files, Config)
                  end,

    ClientFiles = case IsSameCA of
                      true -> ?config(known_client_cert_files , Config);
                      false -> ?config(unknown_client_cert_files, Config)
                  end,

    IsPass = if ClientVerify =:= verify_none andalso ServerVerify =:= verify_none -> true;
                ClientVerify =:= verify_peer andalso IsSameCA -> true;
                ClientVerify =:= verify_none andalso not IsSameCA -> false;
                ServerVerify =:= verify_peer andalso IsSameCA -> true;
                ServerVerify =:= verify_peer andalso not IsSameCA -> false;
                true -> false
             end,
    [ {server_ssl_opts, [ {verify, ServerVerify} | ServerFiles]}
    , {client_ssl_opts, [ {verify, ClientVerify} | ClientFiles]}
    , {target_host, case IsWildcard of
                        true -> "a.wildcard.localhost";
                        false -> "localhost"
                    end}
    , {expect_pass, IsPass}
     | Config];
init_per_testcase(_, Config) ->
    Config.

%%--------------------------------------------------------------------
%% Test cases
%%--------------------------------------------------------------------

t_tcp_sock(_) ->
    Server = tcp_server:start_link(4001),
    {ok, Sock} = emqtt_sock:connect("127.0.0.1", 4001, [], 3000),
    send_and_recv_with(Sock),
    ok = emqtt_sock:close(Sock),
    ok = tcp_server:stop(Server).

t_ssl_sock(Config) ->
    SslOpts = [{certfile, certfile(Config)},
               {keyfile,  keyfile(Config)}
              ],
    {Server, _} = ssl_server:start_link(4443, SslOpts),
    {ok, Sock} = emqtt_sock:connect("127.0.0.1", 4443, [{ssl_opts, []}], 3000),
    send_and_recv_with(Sock),
    ok = emqtt_sock:close(Sock),
    ssl_server:stop(Server).

gen_connect_test(Config) ->
    {Server, LSock} = ssl_server:start_link(0, ?config(server_ssl_opts, Config)),
    {ok, {_, SPort}} = ssl:sockname(LSock),
    ConnRes = emqtt_sock:connect(?config(target_host, Config), SPort,
                             [{ssl_opts, ?config(client_ssl_opts, Config)}], 3000),
    case ?config(expect_pass, Config) of
        true ->
            {ok, Sock} = ConnRes,
            send_and_recv_with(Sock);
        false ->
            case ConnRes of
                {ok, Sock} ->
                    %% connect success but get disconnect later
                    ?assertException(error, {badmatch, _}, send_and_recv_with(Sock));
                _ ->
                    ?assertMatch({error,
                                  {tls_alert,
                                   {unknown_ca,
                                    _}}}, ConnRes)
            end
    end,
    ssl_server:stop(Server).

send_and_recv_with(Sock) ->
    {ok, [{send_cnt, SendCnt}, {recv_cnt, RecvCnt}]} = emqtt_sock:getstat(Sock, [send_cnt, recv_cnt]),
    {ok, {{127,0,0,1}, _}} = emqtt_sock:sockname(Sock),
    ok = emqtt_sock:send(Sock, <<"hi">>),
    {ok, <<"hi">>} = emqtt_sock:recv(Sock, 0),
    ok = emqtt_sock:setopts(Sock, [{active, 100}]),
    {ok, Stats} = emqtt_sock:getstat(Sock, [send_cnt, recv_cnt]),
    Stats = [{send_cnt, SendCnt + 1}, {recv_cnt, RecvCnt + 1}].

%%--------------------------------------------------------------------
%% Helper functions
%%--------------------------------------------------------------------
certfile(Config) ->
    filename:join([cert_dir(Config), "test.crt"]).

keyfile(Config) ->
    filename:join([test_dir(Config), "certs", "test.key"]).

cert_dir(Config) ->
    filename:join([test_dir(Config), "certs"]).
test_dir(Config) ->
    filename:dirname(filename:dirname(proplists:get_value(data_dir, Config))).


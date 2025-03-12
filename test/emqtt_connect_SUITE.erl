%%--------------------------------------------------------------------
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
%%--------------------------------------------------------------------

-module(emqtt_connect_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

-define(ALL_IF_IP6, {0, 0, 0, 0, 0, 0, 0, 0}).

-define(HOSTS,
        [{ip4, [<<"127.0.0.1">>, "127.0.0.1", {127, 0, 0, 1}]},
         {ip6, ["localhost"]}
        ]).

-define(PORTS, #{
                {ip4, connect} =>      {1883,  []},
                {ip4, ws_connect} =>   {8083,  []},
                {ip4, quic_connect} => {14567, []},
                {ip6, connect} =>      {21883, [{tcp_opts, [{tcp_module, inet6_tcp}]}]},
                {ip6, ws_connect} =>   {28083,
                                        [{ws_transport_options, [{protocols, [http]}, {tcp_opts, [inet6]}]},
                                         {ws_headers, [{<<"host">>, <<"[::1]:28083">>}]}
                                        ]},
                {ip6, quic_connect} => {34567, []}
               }).


all() ->
    [{group, ip4}] ++
    [{group, ip6} || is_ip6_available()].

connect_groups() ->
    [{group, tcp},
     {group, ws}
    ] ++
    [{group, quic} || emqtt_test_lib:has_quic()].

groups() ->
    [{ip4, [], connect_groups()}] ++
    [{ip6, [], connect_groups()} || is_ip6_available()] ++
    [{tcp, [], [t_connect, t_reconnect]},
     {ws, [], [t_connect, t_reconnect]},
     {quic, [], [t_connect, t_reconnect]}
    ].

suite() ->
    [{timetrap, {seconds, 15}}].

init_per_suite(Config) ->
    ok = emqtt_test_lib:start_emqx(),
    Config.

end_per_suite(_Config) ->
    emqtt_test_lib:stop_emqx().

init_per_group(ip4, Config) ->
    [{ip_type, ip4} | Config];
init_per_group(ip6, Config) ->
    ok = emqtt_test_lib:ensure_listener(tcp, mqtt_ip6, ?ALL_IF_IP6, 21883),
    ok = emqtt_test_lib:ensure_listener(ws, mqtt_ip6, ?ALL_IF_IP6, 28083),
    case emqtt_test_lib:has_quic() of
        true ->
            ok = emqtt_test_lib:ensure_listener(quic, mqtt_ip6, ?ALL_IF_IP6, 34567);
        false ->
            ok
    end,
    [{ip_type, ip6}, {listener, mqtt_ip6} | Config];
init_per_group(tcp, Config) ->
    [{conn_fun, connect}, {transport, tcp} | Config];
init_per_group(ws, Config) ->
    [{conn_fun, ws_connect}, {transport, ws} | Config];
init_per_group(quic, Config) ->
    [{conn_fun, quic_connect}, {transport, quic}, {listener, mqtt} | Config].

end_per_group(_, Config) ->
    Config.

t_connect(Config) ->
    IpType = ?config(ip_type, Config),
    ConnFun = ?config(conn_fun, Config),
    Hosts = ?config(IpType, ?HOSTS),
    {Port, Opts} = maps:get({IpType, ConnFun}, ?PORTS),
    lists:foreach(
      fun(Host) ->
        ct:pal("Connecting to ~p at port ~p via ~p", [Host, Port, ConnFun]),
        {ok, C} = emqtt:start_link([{host, Host}, {port, Port}] ++ Opts),
        {ok, _} = emqtt:ConnFun(C),
        ct:pal("Connected to ~p at port ~p via ~p", [Host, Port, ConnFun]),
        pong = emqtt:ping(C),
        connected = emqtt:status(C),
        ok = emqtt:disconnect(C)
      end,
      Hosts).

t_reconnect(Config) ->
    %% Outermost group defines listener name:
    ListenerName = lists:last([default] ++ [L || {listener, L} <- Config]),
    ListenerId = atom_to_list(?config(transport, Config)) ++ ":" ++ atom_to_list(ListenerName),
    ConnFun = ?config(conn_fun, Config),
    [Host | _] = ?config(ip4, ?HOSTS),
    {Port, Opts} = maps:get({ip4, ConnFun}, ?PORTS),
    ct:pal("Connecting to ~p at port ~p via ~p", [Host, Port, ConnFun]),
    {ok, C} = emqtt:start_link([{host, Host},
                                {port, Port},
                                {reconnect, 3},
                                {reconnect_timeout, 1}] ++ Opts),
    {ok, _} = emqtt:ConnFun(C),
    ct:pal("Connected to ~p at port ~p via ~p", [Host, Port, ConnFun]),
    ok = emqx_listeners:restart_listener(ListenerId),
    pong = emqtt:ping(C),
    connected = emqtt:status(C),
    ct:pal("Reconnected to ~p at port ~p via ~p", [Host, Port, ConnFun]),
    ok = emqtt:disconnect(C).

is_ip6_available() ->
    is_ip6_available(30000).

is_ip6_available(Port) ->
    Opts = [inet6, {ip, {0,0,0,0,0,0,0,0}}],
    case gen_tcp:listen(Port, Opts) of
        {ok, Sock} ->
            gen_tcp:close(Sock),
            true;
        {error, eaddrinuse} ->
            is_ip6_available(Port + 1);
        {error, Reason} ->
            ct:pal("Cannot listen on IPv6: ~p", [Reason]),
            false
    end.

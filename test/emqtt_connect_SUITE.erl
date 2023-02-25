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

-include("emqtt.hrl").

-include_lib("eunit/include/eunit.hrl").

-include_lib("common_test/include/ct.hrl").

-define(HOSTS,
        [{ip4,
          [
           <<"127.0.0.1">>,
           "127.0.0.1",
           {127, 0, 0, 1}
          ]},
         {ip6,
          [
           "::1",
           <<"::1">>,
           {0, 0, 0, 0, 0, 0, 0, 1}
          ]}]).

-define(LOOPBACK_IP6, {0, 0, 0, 0, 0, 0, 0, 1}).

-define(PORTS, #{
                {ip4, connect} =>      {1883,  []},
                {ip4, ws_connect} =>   {8083,  []},
                {ip4, quic_connect} => {14567, []},
                {ip6, connect} =>      {21883, [{tcp_opts, [{tcp_module, inet6_tcp}]}]},
                {ip6, ws_connect} =>   {28083,
                                        [{ws_transport_options, [{tcp_module, inet6_tcp}]},
                                         {ws_headers, [{<<"host">>, <<"[::1]:28083">>}]}
                                        ]},
                {ip6, quic_connect} => {34567, []}
               }).

all() ->
    [ {group, ip6}
    , {group, ip4}
    ].


connect_groups() -> [
                     {group, connect},
                     {group, ws_connect},
                     {group, quic_connect}
                    ].

groups() ->
    [{ip6, [], connect_groups()},
     {ip4, [], connect_groups()},
     {connect, [], [t_connect]},
     {ws_connect, [], [t_connect]},
     {quic_connect, [], [t_connect]}].

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
    case os:getenv("CI") of
        false ->
            ok = emqtt_test_lib:ensure_listener(tcp, mqtt_ip6, ?LOOPBACK_IP6, 21883),
            ok = emqtt_test_lib:ensure_listener(ws, mqtt_ip6, ?LOOPBACK_IP6, 28083),
            ok = emqtt_test_lib:ensure_listener(quic, mqtt_ip6, ?LOOPBACK_IP6, 34567),
            [{ip_type, ip6} | Config];
        _ ->
            {skip, "Github runners do not support ipv6"}
    end;
init_per_group(connect, Config) ->
    [{conn_fun, connect} | Config];
init_per_group(ws_connect, Config) ->
    [{conn_fun, ws_connect} | Config];
init_per_group(quic_connect, Config) ->
    [{conn_fun, quic_connect} | Config].

end_per_group(_, Config) ->
    Config.

t_connect(Config) ->
    IpType = ?config(ip_type, Config),
    ConnFun = ?config(conn_fun, Config),
    Hosts = ?config(IpType, ?HOSTS),
    {Port, Opts} = maps:get({IpType, ConnFun}, ?PORTS),
    lists:foreach(
      fun(Host) ->
        ct:pal("Connecting to ~p:~p via ~p", [Host, Port, ConnFun]),
        {ok, C} = emqtt:start_link([{host, Host}, {port, Port}] ++ Opts),
        {ok, _} = emqtt:ConnFun(C),
        ct:pal("Connected to ~p:~p via ~p", [Host, Port, ConnFun]),
        ok= emqtt:disconnect(C)
      end,
      Hosts).



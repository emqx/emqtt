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

-module(emqtt_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

-import(lists, [nth/2]).

-include("emqtt.hrl").

-include_lib("eunit/include/eunit.hrl").

-include_lib("common_test/include/ct.hrl").

-define(TOPICS, [<<"TopicA">>, <<"TopicA/B">>, <<"Topic/C">>, <<"TopicA/C">>,
                 <<"/TopicA">>]).

-define(WILD_TOPICS, [<<"TopicA/+">>, <<"+/C">>, <<"#">>, <<"/#">>, <<"/+">>,
                      <<"+/+">>, <<"TopicA/#">>]).

%% The broker's TCP listener port. Tests that need a real listener use TCP
%% regardless of the group, because host selection is transport independent
%% and a QUIC (UDP) connect to a dead port only fails by timeout.
-define(TCP_PORT, 1883).

-define(WAIT(Pattern, Result),
        receive
            Pattern ->
                Result
        after 5000 -> error(timeout)
        end).

-define(COLLECT_ASYNC_RESULT(C),
        fun _CollectFun(Acc) ->
                receive
                    {publish_async_result, N, Result} ->
                        _CollectFun([{N, Result} | Acc]);
                    {'EXIT', C, _} = Msg ->
                        _CollectFun([Msg | Acc])
                after 5000 ->
                      lists:reverse(Acc)
                end
        end([])).

all() ->
    [ {group, mqttv3}
    , {group, mqttv4}
    , {group, mqttv5}
    , {group, general}
    | [{group, quic} || emqtt_test_lib:has_quic()]
    ].

groups() ->
    [{general, [],
      [t_connect,
       t_connect_timeout,
       t_subscribe,
       t_subscribe_qoe,
       t_subscribe_qoe_ssl,
       t_publish,
       t_publish_reply_error,
       t_publish_process_monitor,
       t_publish_port_error,
       t_publish_port_error_retry,
       t_publish_in_reconnect,
       t_publish_async,
       t_eval_callback_in_order,
       t_ack_inflight_and_shoot_cycle,
       t_unsubscribe,
       t_ping,
       t_disconnect_on_pingresp_timeout,
       t_reconnect_after_pingresp_timeout,
       t_puback,
       t_pubrec,
       t_pubrel,
       t_pubcomp,
       t_reconnect_disabled,
       t_reconnect_enabled,
       t_retry_CONNECT_packet_send,
       t_retry_CONNECT_asyn_socket_error,
       t_reconnect_enabled_server_disconnect,
       t_reconnect_stop,
       t_reconnect_reach_max_attempts,
       t_reconnect_immediate_retry,
       t_drop_calls_on_reconnect,
       t_subscriptions,
       t_info,
       t_stop,
       t_pause_resume,
       t_init,
       t_init_external_secret,
       t_hosts_order_preserved,
       t_hosts_failover,
       t_shuffle_hosts_order_varies,
       t_shuffle_hosts_disabled,
       t_shuffle_hosts_failover,
       t_shuffle_hosts_single,
       t_ws_upgrade_options_default,
       t_ws_upgrade_options_custom,
       t_connected,
       t_qos2_flow_autoack_never,
       t_ssl_error_client_reject_server,
       t_ssl_error_server_reject_client,
       t_frame_parse_error,
       t_active_default_recv,
       t_active_n_rearm,
       t_active_n_rearm_ssl]},

    {mqttv3,[],
      [basic_test_v3]},
    {mqttv4, [],
      [basic_test_v4,
       %% anonymous_test,
       retry_interval_test,
       will_message_test,
       will_retain_message_test,
       offline_message_queueing_test,
       overlapping_subscriptions_test,
       redelivery_on_reconnect_test,
       dollar_topics_test]},
    {mqttv5, [],
      [basic_test_v5,
       retain_as_publish_test]}
    | [ {quic, [], [ {group, general}
                   , {group, mqttv3}
                   , {group, mqttv4}
                   , {group, mqttv5}
                   ]}
        || emqtt_test_lib:has_quic()
      ]
    ].

suite() ->
    [{timetrap, {seconds, 60}}].

init_per_suite(Config) ->
    ok = emqtt_test_lib:ensure_broker(),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TC, Config) ->
    Config.

end_per_testcase(TC, _Config)
  when TC =:= t_reconnect_enabled orelse
       TC =:= t_reconnect_disabled orelse
       TC =:= t_reconnect_stop orelse
       TC =:= t_reconnect_reach_max_attempts ->
    process_flag(trap_exit, false),
    ok = emqtt_test_lib:start_listeners(),
    meck:unload(),
    ok;
end_per_testcase(_TC, _Config) ->
    ok = emqtt_test_lib:clear_delays(),
    meck:unload(),
    ok.

init_per_group(quic, Config) ->
    merge_config(Config, [{port, 14567}, {conn_fun, quic_connect}]);
init_per_group(_, Config) ->
    case lists:keyfind(conn_fun, 1, Config) of
        false ->
            merge_config(Config, [{port, 1883}, {ssl_port, 8883}, {conn_fun, connect}]);
        _ ->
            Config
    end.

end_per_group(_, Config) ->
    Config.

receive_messages(Count) ->
    receive_messages(Count, []).

receive_messages(0, Msgs) ->
    Msgs;
receive_messages(Count, Msgs) ->
    receive
        {publish, Msg} ->
            receive_messages(Count-1, [Msg|Msgs]);
        _Other ->
            receive_messages(Count, Msgs)
    after 100 ->
        Msgs
    end.

clean_retained(Topic) ->
    {ok, Clean} = emqtt:start_link([{clean_start, true}]),
    {ok, _} = emqtt:connect(Clean),
    {ok, _} = emqtt:publish(Clean, Topic, #{}, <<"">>, [{qos, ?QOS_1}, {retain, true}]),
    ok = emqtt:disconnect(Clean).

t_props(_) ->
    ok = emqtt_props:validate(#{'Payload-Format-Indicator' => 0}).

t_connect(Config) ->
    ConnFun = ?config(conn_fun, Config),
    Port = ?config(port, Config),
    {ok, C} = emqtt:start_link([{port, Port}]),
    {ok, _} = emqtt:ConnFun(C),
    ct:pal("C is connected ~p", [C]),
    ok= emqtt:disconnect(C),
    {ok, C1} = emqtt:start_link([ {clean_start, true}
                                , {port, Port}
                                ]),
    {ok, _} = emqtt:ConnFun(C1),
    ct:pal("C1 is connected ~p", [C1]),
    ok= emqtt:disconnect(C1),

    {ok, C2} = emqtt:start_link(#{ clean_start => true
                                 , port => Port
                                 }
                               ),
    {ok, _} = emqtt:ConnFun(C2),
    ct:pal("C2 is connected ~p", [C2]),
    ok= emqtt:disconnect(C2).

t_connect_timeout(Config) ->
    ConnFun = ?config(conn_fun, Config),
    Port = ?config(port, Config),
    process_flag(trap_exit, true),
    {ok, C} = emqtt:start_link([{port, Port},
                                {connect_timeout, 1}]),
    F = fun(Sock, _) ->
                C ! {inet_reply, Sock, ok},
                ok
        end,
    meck:new(emqtt_sock, [passthrough, no_history]),
    meck:expect(emqtt_sock, send, F),

    mock_quic_send(F),

    ?assertEqual({error, connack_timeout}, emqtt:ConnFun(C)),

    meck:unload(emqtt_sock),
    unmock_quic().

t_reconnect_disabled(Config) ->
    ConnFun = ?config(conn_fun, Config),
    Port = ?config(port, Config),
    process_flag(trap_exit, true),
    {ok, C} = emqtt:start_link([{port, Port}]),
    {ok, _} = emqtt:ConnFun(C),
    MRef = erlang:monitor(process, C),
    ok = emqtt_test_lib:stop_listeners(),
    receive
        {'DOWN', MRef, process, C, _Info} ->
            receive
                {'EXIT', C, {shutdown, tcp_closed}} when ConnFun =:= connect->
                    ok;
                {'EXIT', C, {shutdown, Reason}} when ConnFun =:= quic_connect->
                    ct:pal("shutdown with reason~p", [Reason]),
                    ok
            after 100 ->
                    ct:fail(no_shutdown)
            end
    after 500 ->
            ct:fail(conn_still_alive)
    end.

t_ssl_error_client_reject_server(Config) ->
    ct:timetrap({seconds, 1}),
    Port = proplists:get_value(ssl_port, Config, 8883),
    DataDir = cert_dir(Config),
    Ns = atom_to_list(?FUNCTION_NAME),
    F = fun(Name) -> Ns ++ "-" ++ atom_to_list(Name) end,
    emqtt_test_lib:gen_ca(DataDir, F(ca)),
    emqtt_test_lib:gen_ca(DataDir, F(ca2)),
    emqtt_test_lib:gen_host_cert(F(server), F(ca), DataDir, true),
    emqtt_test_lib:gen_host_cert(F(client), F(ca2), DataDir, true),
    emqtt_test_lib:set_ssl_options(<<"ssl:default">>,
                                   #{ verify => verify_none
                                    , certfile => emqtt_test_lib:cert_name(DataDir, F(server))
                                    , keyfile => emqtt_test_lib:key_name(DataDir, F(server))
                                    }),
    process_flag(trap_exit, true),
    {ok, C} = emqtt:start_link([{port, Port},
                                {ssl, true},
                                {ssl_opts, [ {certfile, emqtt_test_lib:cert_name(DataDir, F(client))}
                                           , {keyfile, emqtt_test_lib:key_name(DataDir, F(client))}
                                           , {cacertfile, emqtt_test_lib:ca_cert_name(DataDir, F(client))}
                                           , {verify, verify_peer}
                                           ]}
                               ]),
    ?assertMatch({error, {tls_alert, {unknown_ca, _}}}, emqtt:connect(C)),
    ok.

t_ssl_error_server_reject_client(Config) ->
    ct:timetrap({seconds, 1}),
    Port = proplists:get_value(ssl_port, Config, 8883),
    DataDir = cert_dir(Config),
    Ns = atom_to_list(?FUNCTION_NAME),
    F = fun(Name) -> Ns ++ "-" ++ atom_to_list(Name) end,
    emqtt_test_lib:gen_ca(DataDir, F(ca)),
    emqtt_test_lib:gen_ca(DataDir, F(ca2)),
    emqtt_test_lib:gen_host_cert(F(server), F(ca), DataDir, true),
    emqtt_test_lib:gen_host_cert(F(client), F(ca2), DataDir, true),
    emqtt_test_lib:set_ssl_options(<<"ssl:default">>,
                                   #{ verify => verify_peer
                                    , cacertfile => emqtt_test_lib:ca_cert_name(DataDir, F(ca))
                                    , certfile => emqtt_test_lib:cert_name(DataDir, F(server))
                                    , keyfile => emqtt_test_lib:key_name(DataDir, F(server))
                                    }),
    process_flag(trap_exit, true),
    {ok, C} = emqtt:start_link([{port, Port},
                                {ssl, true},
                                {ssl_opts, [ {certfile, emqtt_test_lib:cert_name(DataDir, F(client))}
                                           , {keyfile, emqtt_test_lib:key_name(DataDir, F(client))}
                                           , {verify, verify_none}
                                           ]}
                               ]),
    {error, Reason} = emqtt:connect(C),
    %% The shutdown reason itself, not the raw `{ssl_error, Sock, Reason}'
    %% socket event; same shape as in `t_ssl_error_client_reject_server'.
    ?assertMatch({tls_alert, {unknown_ca, _}}, Reason),
    ok.

%% Receiving bytes that do not parse as an MQTT frame — e.g. the TLS alert a
%% TLS listener sends back when a plain TCP client posts MQTT CONNECT to it —
%% must yield a compact typed error: not the raw `{tcp, Port, Data}' socket
%% event, and no stacktrace in the reason. A fake server is used instead of a
%% real TLS listener so the alert bytes are delivered deterministically
%% (a real TLS stack may close the socket before the alert is flushed).
t_frame_parse_error(_Config) ->
    ct:timetrap({seconds, 10}),
    {ok, L} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]),
    {ok, Port} = inet:port(L),
    TestPid = self(),
    Server = spawn_link(fun() ->
        {ok, S} = gen_tcp:accept(L, 5000),
        {ok, _Connect} = gen_tcp:recv(S, 0, 5000),
        %% TLS alert record: fatal (2), unexpected_message (10)
        ok = gen_tcp:send(S, <<21, 3, 3, 0, 2, 2, 10>>),
        TestPid ! {sent, self()},
        %% Keep the socket open so the close does not race the data delivery.
        receive stop -> ok after 5000 -> ok end
    end),
    process_flag(trap_exit, true),
    {ok, C} = emqtt:start_link([{host, "127.0.0.1"}, {port, Port}]),
    ?assertMatch({error, {frame_parse_error, _}}, emqtt:connect(C)),
    receive
        {'EXIT', C, ExitReason} ->
            ?assertMatch({shutdown, {frame_parse_error, _}}, ExitReason)
    after 1000 ->
        ok
    end,
    receive {sent, Server} -> ok after 1000 -> ok end,
    unlink(Server),
    Server ! stop,
    ok.

t_reconnect_enabled(Config) ->
    ConnFun = ?config(conn_fun, Config),
    Port = ?config(port, Config),
    Topic = nth(1, ?TOPICS),
    process_flag(trap_exit, true),
    {ok, C} = emqtt:start_link([{port, Port},
                                {reconnect, true},
                                {clean_start, false},
                                {reconnect_timeout, 1}]), % 1 sec
    {ok, _} = emqtt:ConnFun(C),
    MRef = erlang:monitor(process, C),
    ok = emqtt_test_lib:stop_listeners(),
    receive
        {'DOWN', MRef, process, C, _Info} ->
            ct:fail(conn_dead)
    after 100 ->
            timer:apply_after(5000, emqtt_test_lib, start_listeners, []),
            true = retry_if_errors([false], fun emqtt_test_lib:is_running/0),
            ct:pal("emqx is up"),
            connected = retry_if_errors([reconnect, waiting_for_connack],
                                       fun() ->
                                               {StateName, _Data} = sys:get_state(C),
                                               StateName
                                       end),
            ct:pal("Old client is reconnected"),
            {ok, _, [0]} = emqtt:subscribe(C, Topic),
            {ok, C2} = emqtt:start_link([{port, Port}, {reconnect, true}, {clean_start, false}]),
            [{Topic, #{qos := 0}}] = emqtt:subscriptions(C),
            {ok, _} = emqtt:ConnFun(C2),
            {ok, _} = emqtt:publish(C2, Topic, <<"t_reconnect_enabled">>, [{qos, 1}]),
            Via = proplists:get_value(socket, emqtt:info(C)),
            ?assertEqual(
               [#{client_pid => C,
                  dup => false,packet_id => undefined,
                  payload => <<"t_reconnect_enabled">>,
                  properties => undefined,qos => 0,
                  retain => false,
                  topic => <<"TopicA">>,
                  via => Via
                 }
               ], receive_messages(1))
    end.

t_retry_CONNECT_packet_send(Config) ->
    retry_CONNECT_packet_send(true, Config).

t_retry_CONNECT_asyn_socket_error(Config) ->
    retry_CONNECT_packet_send(false, Config).

retry_CONNECT_packet_send(SendError, Config) ->
    ConnFun = ?config(conn_fun, Config),
    Port = ?config(port, Config),
    process_flag(trap_exit, true),
    meck:new(emqtt_sock, [passthrough, no_history]),
    meck:new(emqtt_quic, [passthrough, no_history]),
    Tester = self(),
    F = fun(Sock, _Packet) ->
                Msg = case ConnFun of
                    connect ->
                        {tcp_error, Sock, closed};
                    quic_connect ->
                        {quic_error, Sock, closed}
                end,
                _ = erlang:send_after(10, self(), Msg),
                Tester ! sync,
                case SendError of
                    true ->
                        {error, einval};
                    false ->
                        ok
                end
        end,
    meck:expect(emqtt_sock, send, F),
    meck:expect(emqtt_quic, send, F),
    {ok, C} = emqtt:start_link([{port, Port},
                                {reconnect, true},
                                {clean_start, false},
                                {reconnect_timeout, 1}]), % 1 sec
    spawn_link(fun() ->
                       Res =  emqtt:ConnFun(C),
                       Tester ! {connect_result, Res}
               end),
    receive
        sync -> ok
    after
        1000 ->
            error(timeout)
    end,
    %% unload mock, expect reconnect to succeed
    meck:unload(emqtt_sock),
    meck:unload(emqtt_quic),
    receive
        {connect_result, Res} ->
            ?assertMatch({ok, _}, Res)
    after
        3000 ->
            error(timeout)
    end,
    ok.

t_reconnect_enabled_server_disconnect(Config) ->
    ConnFun = ?config(conn_fun, Config),
    Port = ?config(port, Config),
    ClientId = atom_to_binary(?FUNCTION_NAME),
    Topic = ClientId,
    process_flag(trap_exit, true),
    {ok, C} = emqtt:start_link([{clientid, ClientId},
                                {port, Port},
                                {reconnect, true},
                                {clean_start, false},
                                {reconnect_timeout, 1}]), % 1 sec
    {ok, _} = emqtt:ConnFun(C),
    MRef = erlang:monitor(process, C),
    ok = emqtt_test_lib:kick_client(ClientId),
    receive
        {'DOWN', MRef, process, C, _Info} ->
            ct:fail(conn_dead)
    after 100 ->
            ok
    end,
    connected = retry_if_errors([reconnect, waiting_for_connack],
                                fun() ->
                                        {StateName, _Data} = sys:get_state(C),
                                        StateName
                                end),
    receive
        {connected, _}  -> ct:pal("Old client is reconnected")
    after 1500 ->
        ct:fail("reconnected timeout")
    end,
    {ok, _, [0]} = emqtt:subscribe(C, Topic),
    {ok, C2} = emqtt:start_link([{port, Port}, {reconnect, true}, {clean_start, false}]),
    [{Topic, #{qos := 0}}] = emqtt:subscriptions(C),
    {ok, _} = emqtt:ConnFun(C2),
    {ok, _} = emqtt:publish(C2, Topic, <<"t_reconnect_enabled">>, [{qos, 1}]),
    Via = proplists:get_value(socket, emqtt:info(C)),
    ?assertEqual(
       [#{client_pid => C,
          dup => false,packet_id => undefined,
          payload => <<"t_reconnect_enabled">>,
          properties => undefined,qos => 0,
          retain => false,
          topic => ClientId,
          via => Via
         }
       ], receive_messages(1)),
    emqtt:stop(C).

t_reconnect_stop(Config) ->
    ConnFun = ?config(conn_fun, Config),
    Port = ?config(port, Config),
    process_flag(trap_exit, true),
    {ok, C} = emqtt:start_link([{port, Port},
                                {reconnect, true},
                                {clean_start, false},
                                {reconnect_timeout, 1}]), % 1 sec
    {ok, _} = emqtt:ConnFun(C),
    MRef = erlang:monitor(process, C),
    ok = emqtt_test_lib:stop_listeners(),
    receive
        {'DOWN', MRef, process, C, _Info} ->
            ct:fail(conn_dead)
    after 500 ->
            ok = emqtt:stop(C),
            receive
                {'DOWN', MRef, process, C, _Info} ->
                    receive
                        {'EXIT', C, normal} ->
                            ok
                    after 100 ->
                            ct:fail(no_exit)
                    end
            after 6000 ->
                    ct:fail(conn_still_alive)
            end
    end.

t_reconnect_reach_max_attempts(Config) ->
    ConnFun = ?config(conn_fun, Config),
    Port = ?config(port, Config),
    process_flag(trap_exit, true),
    {ok, C} = emqtt:start_link([{port, Port},
                                {reconnect, 2},
                                {clean_start, false},
                                {reconnect_timeout, 1}]), % 1 sec
    {ok, _} = emqtt:ConnFun(C),
    MRef = erlang:monitor(process, C),

    %% meck connect, close funcs to speed up
    meck:new(emqtt_sock, [passthrough, no_history]),
    meck:expect(emqtt_sock, connect, fun(_, _, _, _) -> {error, fake_conn_error} end),
    meck:expect(emqtt_sock, close, fun(_) -> ok end),

    case emqtt_test_lib:has_quic() of
        true ->
            meck:expect(emqtt_quic, connect, fun(_, _, _, _) -> {error, fake_conn_error} end),
            meck:expect(emqtt_quic, close, fun(_) -> ok end);
        _ ->
            ok
    end,

    ok = emqtt_test_lib:stop_listeners(),

    receive
        {'DOWN', MRef, process, C, {shutdown, fake_conn_error}} -> ok
    after 5000 ->
        ct:fail(conn_still_alive)
    end,
    meck:unload(emqtt_sock),
    unmock_quic().

t_reconnect_immediate_retry(Config) ->
    ConnFun = ?config(conn_fun, Config),
    case ConnFun of
        quic_connect ->
            %% Note: quicer will throw `stm_send_error` once emqtt reconnected
            ct:pal("skipped", []),
            ok;
        _ ->
            test_reconnect_immediate_retry(Config)
    end.

test_reconnect_immediate_retry(Config) ->
    ConnFun = ?config(conn_fun, Config),
    Port = ?config(port, Config),
    Topic = nth(1, ?TOPICS),
    {ok, C} = emqtt:start_link([{port, Port},
                                {max_inflight, 2},
                                {reconnect, true},
                                {clean_start, false},
                                {reconnect_timeout, 1}]), % 1 sec
    {ok, _} = emqtt:ConnFun(C),

    %% meck to stop return PUBACK
    meck:new(emqtt_sock, [passthrough, no_history]),
    meck:expect(emqtt_sock, send, fun(_, _) -> ok end),

    mock_quic_send(fun(_, _) -> ok end),

    Parent = self(),
    ok = emqtt:publish_async(C, Topic, <<"inflight1">>, [{qos, 1}],
                             fun(R) -> Parent ! {publish_async_result, 1, R} end),
    ok = emqtt:publish_async(C, Topic, <<"inflight2">>, [{qos, 1}],
                             fun(R) -> Parent ! {publish_async_result, 2, R} end),
    ok = emqtt:publish_async(C, Topic, <<"enqueue1">>, [{qos, 1}],
                             fun(R) -> Parent ! {publish_async_result, 3, R} end),
    ok = emqtt:publish_async(C, Topic, <<"enqueue2">>, [{qos, 1}],
                             fun(R) -> Parent ! {publish_async_result, 4, R} end),

    ok = emqtt_test_lib:stop_listeners(),
    meck:unload(emqtt_sock),
    unmock_quic(),

    ok = emqtt_test_lib:start_listeners(),

    ?assertMatch([{1, {ok, _}},
                  {2, {ok, _}},
                  {3, {ok, _}},
                  {4, {ok, _}}], ?COLLECT_ASYNC_RESULT(C)),

    ok = emqtt:disconnect(C).

t_subscribe(Config) ->
    ConnFun = ?config(conn_fun, Config),
    Port = ?config(port, Config),

    Topic = nth(1, ?TOPICS),
    {ok, C} = emqtt:start_link([{clean_start, true}, {proto_ver, v5}, {port, Port}, {with_qoe_metrics, false}]),
    {ok, _} = emqtt:ConnFun(C),

    {ok, _, [0]} = emqtt:subscribe(C, Topic),
    {ok, _, [0]} = emqtt:subscribe(C, Topic, at_most_once),
    {ok, _, [0]} = emqtt:subscribe(C, {Topic, at_most_once}),
    {ok, _, [0]} = emqtt:subscribe(C, #{}, Topic, at_most_once),

    {ok, _, [1]} = emqtt:subscribe(C, Topic, 1),
    {ok, _, [1]} = emqtt:subscribe(C, {Topic, 1}),
    {ok, _, [1]} = emqtt:subscribe(C, #{}, Topic, 1),

    {ok, _, [2]} = emqtt:subscribe(C, Topic, [{qos, ?QOS_2}]),
    {ok, _, [2]} = emqtt:subscribe(C, #{}, Topic, [{qos, ?QOS_2}, {nl, false}, {other, ignore}]),

    {ok, _, [0,1,2]} = emqtt:subscribe(C, [{Topic, at_most_once},{Topic, 1}, {Topic, [{qos, ?QOS_2}]}]),
    ?assert(false == proplists:get_value(qoe, emqtt:info(C))),
    ok = emqtt:disconnect(C).

t_subscribe_qoe(Config) ->
    ConnFun = ?config(conn_fun, Config),
    Port = ?config(port, Config),

    Topic = nth(1, ?TOPICS),
    {ok, C} = emqtt:start_link([{clean_start, true}, {proto_ver, v5}, {port, Port}, {with_qoe_metrics, true}]),
    {ok, _} = emqtt:ConnFun(C),

    {ok, _, [0]} = emqtt:subscribe(C, Topic),
    {ok, _, [0]} = emqtt:subscribe(C, Topic, at_most_once),
    {ok, _, [0]} = emqtt:subscribe(C, {Topic, at_most_once}),
    {ok, _, [0]} = emqtt:subscribe(C, #{}, Topic, at_most_once),

    {ok, _, [1]} = emqtt:subscribe(C, Topic, 1),
    {ok, _, [1]} = emqtt:subscribe(C, {Topic, 1}),
    {ok, _, [1]} = emqtt:subscribe(C, #{}, Topic, 1),

    {ok, _, [2]} = emqtt:subscribe(C, Topic, [{qos, ?QOS_2}]),
    {ok, _, [2]} = emqtt:subscribe(C, #{}, Topic, [{qos, ?QOS_2}, {nl, false}, {other, ignore}]),

    {ok, _, [0,1,2]} = emqtt:subscribe(C, [{Topic, at_most_once},{Topic, 1}, {Topic, [{qos, ?QOS_2}]}]),
    QoE = proplists:get_value(qoe, emqtt:info(C)),
    ?assert(is_map(QoE)),
    ?assert(undefined == maps:get(tcp_connected_at, QoE)),
    ok = emqtt:disconnect(C).

t_subscribe_qoe_ssl(Config) ->
    ConnFun = connect,
    Port = proplists:get_value(ssl_port, Config, 8883),
    Topic = nth(1, ?TOPICS),
    DataDir = cert_dir(Config),
    Ns = atom_to_list(?FUNCTION_NAME),
    F = fun(Name) -> Ns ++ "-" ++ atom_to_list(Name) end,
    emqtt_test_lib:gen_ca(DataDir, F(ca)),
    emqtt_test_lib:gen_host_cert(F(server), F(ca), DataDir, true),
    emqtt_test_lib:gen_host_cert(F(client), F(ca), DataDir, true),
    emqtt_test_lib:set_ssl_options(<<"ssl:default">>,
                                   #{ verify => verify_none
                                    , certfile => emqtt_test_lib:cert_name(DataDir, F(server))
                                    , keyfile => emqtt_test_lib:key_name(DataDir, F(server))
                                    }),
    process_flag(trap_exit, true),
    {ok, C} = emqtt:start_link([{clean_start, true}, {proto_ver, v5}, {port, Port}, {with_qoe_metrics, true},
                                {ssl, true},
                                {ssl_opts, [{verify, verify_none}]}
                               ]),
    {ok, _} = emqtt:ConnFun(C),
    {ok, _, [0]} = emqtt:subscribe(C, Topic),
    {ok, _, [0]} = emqtt:subscribe(C, Topic, at_most_once),
    {ok, _, [0]} = emqtt:subscribe(C, {Topic, at_most_once}),
    {ok, _, [0]} = emqtt:subscribe(C, #{}, Topic, at_most_once),

    {ok, _, [1]} = emqtt:subscribe(C, Topic, 1),
    {ok, _, [1]} = emqtt:subscribe(C, {Topic, 1}),
    {ok, _, [1]} = emqtt:subscribe(C, #{}, Topic, 1),

    {ok, _, [2]} = emqtt:subscribe(C, Topic, [{qos, ?QOS_2}]),
    {ok, _, [2]} = emqtt:subscribe(C, #{}, Topic, [{qos, ?QOS_2}, {nl, false}, {other, ignore}]),

    {ok, _, [0,1,2]} = emqtt:subscribe(C, [{Topic, at_most_once},{Topic, 1}, {Topic, [{qos, ?QOS_2}]}]),
    QoE = proplists:get_value(qoe, emqtt:info(C)),
    ?assert(is_map(QoE)),
    ?assert(is_integer(maps:get(tcp_connected_at, QoE))),
    ok = emqtt:disconnect(C).

t_publish(Config) ->
    ConnFun = ?config(conn_fun, Config),
    Port = ?config(port, Config),

    Topic = nth(1, ?TOPICS),
    {ok, C} = emqtt:start_link([{clean_start, true}, {port, Port}]),
    {ok, _} = emqtt:ConnFun(C),

    ok = emqtt:publish(C, Topic, <<"t_publish">>),
    ok = emqtt:publish(C, Topic, <<"t_publish">>, 0),
    ok = emqtt:publish(C, Topic, <<"t_publish">>, at_most_once),
    {ok, Reply1} = emqtt:publish(C, Topic, <<"t_publish">>, [{qos, 1}]),
    {ok, Reply2} = emqtt:publish(C, Topic, #{}, <<"t_publish">>, [{qos, 2}]),

    ?assertMatch(#{packet_id := _,
                   reason_code := 0,
                   reason_code_name := success
                  }, Reply1),

    ?assertMatch(#{packet_id := _,
                   reason_code := 0,
                   reason_code_name := success
                  }, Reply2),

    ok = emqtt:disconnect(C).

t_publish_reply_error(Config) ->
    ConnFun = ?config(conn_fun, Config),
    Port = ?config(port, Config),

    process_flag(trap_exit, true),

    Topic = nth(1, ?TOPICS),
    {ok, C} = emqtt:start_link([{clean_start, true}, {port, Port}]),
    {ok, _} = emqtt:ConnFun(C),

    %% reply closed
    meck:new(emqtt_sock, [passthrough, no_history]),
    meck:expect(emqtt_sock, send, fun(_, _) -> {error, closed} end),

    mock_quic_send(fun(_, _) -> {error, closed} end),

    ?assertEqual({error, closed}, emqtt:publish(C, Topic, <<"t_publish">>)),

    %% shutdown if an send error occured
    receive
        {'EXIT', C, _} -> ok
    after 1000 ->
              ?assert(false)
    end,

    meck:unload(emqtt_sock),
    unmock_quic().

t_publish_process_monitor(Config) ->
    ConnFun = ?config(conn_fun, Config),
    Port = ?config(port, Config),

    process_flag(trap_exit, true),

    Topic = nth(1, ?TOPICS),
    {ok, C} = emqtt:start_link([{clean_start, true}, {port, Port}]),
    {ok, _} = emqtt:ConnFun(C),

    %% reply ok
    meck:new(emqtt_sock, [passthrough, no_history]),
    meck:expect(emqtt_sock, send, fun(_, _) -> ok end),

    mock_quic_send(fun(_, _) -> ok end),

    %% kill client process
    spawn(fun() -> timer:sleep(1000), exit(C, kill) end),

    ?assertException(exit, killed, emqtt:publish(C, Topic, <<"t_publish">>, ?QOS_1)),

    meck:unload(emqtt_sock),
    unmock_quic().

t_publish_port_error(Config) ->
    ConnFun = ?config(conn_fun, Config),
    case ConnFun of
        quic_connect ->
            ct:pal("skipped", []),
            ok;
        _ ->
            test_publish_port_error(Config)
    end.

test_publish_port_error(Config) ->
    Port = case ?config(port, Config) of
               undefined -> 1883;
               P -> P
           end,
    Topic = nth(1, ?TOPICS),
    {ok, C} = emqtt:start_link([{clean_start, true}, {port, Port}]),
    unlink(C),
    Tester = self(),
    meck:new(emqtt_sock, [passthrough, no_history]),
    %% catch the socket port
    meck:expect(emqtt_sock, connect,
                fun(Host, PortN, Opts, Timeout) ->
                        {ok, Sock} = meck:passthrough([Host, PortN, Opts, Timeout]),
                        Tester ! {socket, Sock},
                        {ok, Sock}
                end),
    {ok, _} = emqtt:connect(C),
    %% balckhole the publish packets, so the publish call is blocked
    meck:expect(emqtt_sock, send, fun(_, _) -> Tester ! sent, ok end),
    Sock = ?WAIT({socket, S}, S),
    Payload = atom_to_binary(?FUNCTION_NAME),
    spawn(
      fun() ->
              Tester ! {publish_result, emqtt:publish(C, Topic, #{}, Payload, [{qos, 1}])}
      end),
    receive sent -> ok end,
    %% killing the socket now should result in an error reply, (but not EXIT exception)
    exit(Sock, kill),
    PublishResult = receive {publish_result, R} -> R
                    after 5000 ->
                              ct:fail(timeout)
                    end,
    ?assertEqual({error, killed}, PublishResult),
    meck:unload(emqtt_sock).

t_publish_port_error_retry(Config) ->
    ConnFun = ?config(conn_fun, Config),
    case ConnFun of
        quic_connect ->
            ct:pal("skipped", []),
            ok;
        _ ->
            test_publish_port_error_retry(Config)
    end.

test_publish_port_error_retry(Config) ->
    Port = case ?config(port, Config) of
               undefined -> 1883;
               P -> P
           end,
    Topic = nth(1, ?TOPICS),
    {ok, C} = emqtt:start_link([{clean_start, false},
                                {port, Port},
                                %% no timer based retry, test state transition retry
                                {retry_interval, 1},
                                {reconnect, true},
                                %% seconds
                                {reconnect_timeout, 2}
                               ]),
    unlink(C),
    Tester = self(),
    meck:new(emqtt_sock, [passthrough, no_history]),
    %% catch the socket port
    meck:expect(emqtt_sock, connect,
                fun(Host, PortN, Opts, Timeout) ->
                        {ok, Sock} = meck:passthrough([Host, PortN, Opts, Timeout]),
                        Tester ! {socket, Sock},
                        {ok, Sock}
                end),
    {ok, _} = emqtt:connect(C),
    Sock = ?WAIT({socket, S}, S),
    %% balckhole the publish packets, so the publish call is blocked
    meck:expect(emqtt_sock, send,
                fun(_, Msg) ->
                        MsgBin = iolist_to_binary(Msg),
                        case binary:match(MsgBin, <<"MQTT">>) of
                            nomatch ->
                                Tester ! {sent, MsgBin};
                            _ ->
                                gen_statem:cast(C, ?CONNACK_PACKET(?RC_SUCCESS))
                        end,
                        ok
                end),
    Payload = atom_to_binary(?FUNCTION_NAME),
    spawn(
      fun() ->
              Tester ! {publish_result, emqtt:publish(C, Topic, #{}, Payload, [{qos, 1}])}
      end),
    WaitForPayload = fun W() ->
                             receive
                                 {sent, Bin} ->
                                     case binary:match(Bin, Payload) of
                                         nomatch -> W();
                                         _ -> ok
                                     end
                             after
                                 10_000 ->
                                     error(timeout)
                             end
                     end,
    WaitForPayload(),
    %% fake a socket close after the first attempt is sent
    C ! {tcp_error, Sock, fake_error},
    %% socket will be re-established
    ?WAIT({socket, _}, ok),
    %% payload should be sent again
    WaitForPayload(),
    %% now stop the process while there is one inflight
    emqtt:disconnect(C),
    %% should still get a reply, but not EXIT exception!
    Result = ?WAIT({publish_result, R}, R),
    ?assertEqual(Result, {error, normal}),
    meck:unload(emqtt_sock).

t_publish_in_reconnect(Config) ->
    ConnFun = ?config(conn_fun, Config),
    Port = ?config(port, Config),

    Topic = nth(1, ?TOPICS),
    {ok, C} = emqtt:start_link([{port, Port},
                                {clean_start, false},
                                {reconnect, true},
                                {reconnect_timeout, 1}]), % 1 sec
    {ok, _} = emqtt:ConnFun(C),

    %% enqueue PUBLISH request in reconnect state
    ok = emqtt_test_lib:stop_listeners(),
    timer:sleep(1000),
    Parent = self(),
    ?assertEqual(reconnect, emqtt:status(C)),
    ok = emqtt:publish_async(C, Topic, <<"enqueue_in_reconnect">>, 0,
                             fun(R) -> Parent ! {publish_async_result, 1, R} end),

    %% The broker takes 2 seconds to authenticate the client
    ok = emqtt_test_lib:delay_authn(2000),
    meck:new(emqtt, [passthrough, no_history]),
    Self = self(),
    meck:expect(emqtt,
                waiting_for_connack,
                fun(EventType, Event, Data) ->
                        Self ! waiting_for_connack,
                        meck:passthrough([EventType, Event, Data])
                end),

    %% enqueue PUBLISH request in waiting_for_connack state
    ok = emqtt_test_lib:start_listeners(),
    ?WAIT(waiting_for_connack, ok),
    ?assertEqual(waiting_for_connack, emqtt:status(C)),
    ok = emqtt:publish_async(C, Topic, <<"enqueue_in_waiting_for_connack">>, 1,
                             fun(R) -> Parent ! {publish_async_result, 2, R} end),

    ?assertMatch([{1, ok},
                  {2, {ok, _}}], ?COLLECT_ASYNC_RESULT(C)),

    meck:unload(emqtt).

%% Verify that with {retry_calls_on_reconnect, false}, the calls like emqtt:subscribe
%% will receive error {error, disconnected} instead of being retried on client reconnect
t_drop_calls_on_reconnect(Config) ->
    ConnFun = ?config(conn_fun, Config),
    Port = ?config(port, Config),

    %% Create a client with retry_calls_on_reconnect set to false
    Topic = nth(1, ?TOPICS),
    {ok, C} = emqtt:start_link([{port, Port},
                                {clean_start, false},
                                {retry_calls_on_reconnect, false},
                                {reconnect, true},
                                {reconnect_timeout, 1}]), % 1 sec
    {ok, _} = emqtt:ConnFun(C),

    %% make subscribe be slow so that we could emulate a disconnect during subscribe
    ok = emqtt_test_lib:delay_authz(2000),

    %% Subscribe
    Self = self(),
    spawn_link(fun() ->
                      Result = emqtt:subscribe(C, Topic, 1),
                      Self ! {subscribe_result, Result}
               end),
    ct:sleep(100),

    %% While subscribing, stop emqx. This should cause a disconnect and a reconnect attempt
    ok = emqtt_test_lib:stop_listeners(),

    %% Verify that the subscribe call returned {error, disconnected}
    receive
        {subscribe_result, Result} ->
            ?assertEqual({error, disconnected}, Result)
    after 1000 ->
            ct:fail("subscribe should fail with disconnected")
    end,

    %% Clean up
    ok = emqtt_test_lib:start_listeners().

t_publish_async(Config) ->
    ConnFun = ?config(conn_fun, Config),
    Port = ?config(port, Config),

    Topic = nth(1, ?TOPICS),
    {ok, C} = emqtt:start_link([{clean_start, true}, {port, Port}]),
    {ok, _} = emqtt:ConnFun(C),

    Parent = self(),
    ok = emqtt:publish_async(C, Topic, <<"t_publish_async_1">>,
                             fun(R) -> Parent ! {publish_async_result, 1, R} end),
    ok = emqtt:publish_async(C, Topic, <<"t_publish_async_2">>, 0,
                             fun(R) -> Parent ! {publish_async_result, 2, R} end),
    ok = emqtt:publish_async(C, Topic, <<"t_publish_async_3">>, at_most_once,
                             fun(R) -> Parent ! {publish_async_result, 3, R} end),
    ok = emqtt:publish_async(C, Topic, <<"t_publish_async_4">>, [{qos, 1}],
                             fun(R) -> Parent ! {publish_async_result, 4, R} end),
    ok = emqtt:publish_async(C, Topic, #{}, <<"t_publish_async_5">>, [{qos, 2}], 5000,
                             fun(R) -> Parent ! {publish_async_result, 5, R} end),

    ?assertMatch([{1, ok},
                  {2, ok},
                  {3, ok},
                  {4, {ok, _}},
                  {5, {ok, _}}], ?COLLECT_ASYNC_RESULT(C)),
    ok = emqtt:disconnect(C).

t_eval_callback_in_order(Config) ->
    ConnFun = ?config(conn_fun, Config),
    Port = ?config(port, Config),

    process_flag(trap_exit, true),

    {ok, C} = emqtt:start_link([{clean_start, true}, {port, Port},
                                {retry_interval, 2}, {max_inflight, 2}]),
    {ok, _} = emqtt:ConnFun(C),

    meck:new(emqtt_sock, [passthrough, no_history]),
    meck:expect(emqtt_sock, send, fun(_, _) -> ok end),

    mock_quic_send(fun(_, _) -> ok end),

    Parent = self(),
    ok = emqtt:publish_async(C, <<"topic">>, <<"1">>, 0,
                             fun(R) -> Parent ! {publish_async_result, 1, R} end),
    ok = emqtt:publish_async(C, <<"topic">>, <<"2">>, 1,
                             fun(R) -> Parent ! {publish_async_result, 2, R} end),
    ok = emqtt:publish_async(C, <<"topic">>, <<"3">>, 1,
                             fun(R) -> Parent ! {publish_async_result, 3, R} end),
    ok = emqtt:publish_async(C, <<"topic">>, <<"4">>, 2,
                             fun(R) -> Parent ! {publish_async_result, 4, R} end),
    ok = emqtt:publish_async(C, <<"topic">>, <<"5">>, 2,
                             fun(R) -> Parent ! {publish_async_result, 5, R} end),

    timer:sleep(1000),

    %% mock the send function to get an sending error

    meck:unload(emqtt_sock),
    unmock_quic(),

    meck:new(emqtt_sock, [passthrough, no_history]),
    meck:expect(emqtt_sock, send, fun(_, _) -> {error, closed} end),

    mock_quic_send(fun(_, _) -> {error, closed} end),

    ?assertMatch([{1, ok}, %% qos0: treat send as successfully
                  {2, {error, closed}}, %% from inflight
                  {3, {error, closed}},
                  {4, {error, closed}}, %% from pending request queue
                  {5, {error, closed}},
                  {'EXIT', C, {shutdown, closed}}], ?COLLECT_ASYNC_RESULT(C)),

    meck:unload(emqtt_sock),
    unmock_quic().

t_ack_inflight_and_shoot_cycle(Config) ->
    ConnFun = ?config(conn_fun, Config),
    Port = ?config(port, Config),

    {ok, C} = emqtt:start_link([{clean_start, true}, {port, Port},
                                {retry_interval, 30}, {max_inflight, 2}]),
    {ok, _} = emqtt:ConnFun(C),

    process_flag(trap_exit, true),
    Parent = self(),

    SendFun = fun(_Sock, Data) ->
                      {ok, Pkt, _, _} = emqtt_frame:parse(iolist_to_binary(Data)),
                      Parent ! {publish_async_sent, Pkt},
                      ok
              end,
    ok = meck:new(emqtt_sock, [passthrough, no_history]),
    ok = meck:expect(emqtt_sock, send, SendFun),

    mock_quic_send(SendFun),

    ok = emqtt:publish_async(C, <<"topic">>, <<"1">>, 1,
                             fun(R) -> Parent ! {publish_async_result, 1, R} end),
    ok = emqtt:publish_async(C, <<"topic">>, <<"2">>, 1,
                             fun(R) -> Parent ! {publish_async_result, 2, R} end),
    ok = emqtt:publish_async(C, <<"topic">>, <<"3">>, 1,
                             fun(R) -> Parent ! {publish_async_result, 3, R} end),
    ok = emqtt:publish_async(C, <<"topic">>, <<"4">>, 1,
                             fun(R) -> Parent ! {publish_async_result, 4, R} end),

    CollectSentFun =
        fun _CollectSentFun(Acc) ->
                receive
                    {publish_async_sent, Pkt} ->
                        _CollectSentFun([Pkt| Acc]);
                    {'EXIT', C, _} = Msg ->
                        _CollectSentFun([Msg | Acc])
                after 500 ->
                      lists:reverse(Acc)
                end
        end,
    %% the first 2 msgs in flight, other msgs in the queue
    InflightMsgs1 = CollectSentFun([]),
    ?assertMatch([?PUBLISH_PACKET(_, _, _, <<"1">>),
                  ?PUBLISH_PACKET(_, _, _, <<"2">>)
                 ], InflightMsgs1),

    %% ack the fisrt 2 msgs
    lists:foreach(
      fun(?PUBLISH_PACKET(_, _, PacketId, _)) ->
              gen_statem:cast(C, ?PUBACK_PACKET(PacketId))
      end, InflightMsgs1),

    CollectResFun =
        fun _CollectResFun(Acc) ->
                receive
                    {publish_async_result, N, Result} ->
                        _CollectResFun([{N, Result} | Acc]);
                    {'EXIT', C, _} = Msg ->
                        _CollectResFun([Msg | Acc])
                after 500 ->
                      lists:reverse(Acc)
                end
        end,

    CompMsgs1 = CollectResFun([]),
    InflightMsgs2 = CollectSentFun([]),

    %% the first 2 msgs has sent successfully
    ?assertMatch([{1, {ok, _}},
                  {2, {ok, _}}
                 ], CompMsgs1),
    %% the 3,4 msg will be sent due to inflight window moved
    ?assertMatch([?PUBLISH_PACKET(_, _, _, <<"3">>),
                  ?PUBLISH_PACKET(_, _, _, <<"4">>)
                 ], InflightMsgs2),

    %% ack the 3,4 msg
    lists:foreach(
      fun(?PUBLISH_PACKET(_, _, PacketId, _)) ->
              gen_statem:cast(C, ?PUBACK_PACKET(PacketId))
      end, InflightMsgs2),

    CompMsgs2 = CollectResFun([]),
    %% the 3,4 msgs has sent successfully
    ?assertMatch([{3, {ok, _}},
                  {4, {ok, _}}
                 ], CompMsgs2),

    ok = meck:unload(emqtt_sock),
    unmock_quic(),
    ok = emqtt:disconnect(C).

t_unsubscribe(Config) ->
    ConnFun = ?config(conn_fun, Config),
    Port = ?config(port, Config),

    Topic1 = nth(1, ?TOPICS),
    Topic2 = nth(2, ?TOPICS),
    Topic3 = nth(3, ?TOPICS),
    Topic4 = nth(4, ?TOPICS),
    {ok, C} = emqtt:start_link([{clean_start, true}, {port, Port}]),
    {ok, _} = emqtt:ConnFun(C),
    {ok, _, [0,0,0,0]} = emqtt:subscribe(C, [{Topic1, 0}, {Topic2, 0}, {Topic3, 0}, {Topic4, 0}]),

    {ok, _, _} = emqtt:unsubscribe(C, Topic1),
    {ok, _, _} = emqtt:unsubscribe(C, [Topic2]),
    {ok, _, _} = emqtt:unsubscribe(C, #{}, Topic3),
    {ok, _, _} = emqtt:unsubscribe(C, #{}, [Topic4]),

    ok = emqtt:disconnect(C).

t_ping(Config) ->
    ConnFun = ?config(conn_fun, Config),
    Port = ?config(port, Config),
    {ok, C} = emqtt:start_link([{clean_start, true}, {port, Port}]),
    {ok, _} = emqtt:ConnFun(C),
    pong = emqtt:ping(C),
    ok = emqtt:disconnect(C).

t_disconnect_on_pingresp_timeout(Config) ->
    erlang:process_flag(trap_exit, true),
    ConnFun = ?config(conn_fun, Config),
    Port = ?config(port, Config),
    ClientId = atom_to_binary(?FUNCTION_NAME),
    {ok, C} = emqtt:start_link([
        {clean_start, true},
        {port, Port},
        {keepalive, 1},
        {clientid, ClientId},
        {reconnect, 0}
    ]),
    Topic = <<"t">>,
    {ok, _} = emqtt:ConnFun(C),
    %% The channel freezes for 10 seconds in the authorization of the next PUBLISH
    ok = emqtt_test_lib:delay_authz(10000),
    ok = emqtt:publish(C, Topic, <<"pingresp_test">>, ?QOS_0),
    %% emqtt should shutdown because of pingresp_timeout. The PUBLISH counts as
    %% activity, so the first PINGREQ goes out about 1 second later, and its
    %% timeout is detected 1 to 2 keepalive intervals after that.
    Exited = receive
        {'EXIT', C, _} ->
            true
    after 6000 ->
        false
    end,
    ?assert(Exited, "Client should shutdown because of pingresp_timeout").

t_reconnect_after_pingresp_timeout(Config) ->
    erlang:process_flag(trap_exit, true),
    ConnFun = ?config(conn_fun, Config),
    Port = ?config(port, Config),
    ClientId = atom_to_binary(?FUNCTION_NAME),
    %% The client reconnects after the frozen channel has woken and seen its connection
    %% closed, so the next connection is the only one the broker holds for this client
    {ok, C} = emqtt:start_link([
        {clean_start, true},
        {port, Port},
        {keepalive, 1},
        {clientid, ClientId},
        {reconnect, true},
        {reconnect_timeout, 6}
    ]),
    StateName = fun() -> {Name, _Data} = sys:get_state(C), Name end,
    Topic = <<"t">>,
    {ok, _} = emqtt:ConnFun(C),
    %% The channel freezes for 5 seconds in the authorization of the next PUBLISH, so the
    %% connection is lost with a PINGREQ outstanding
    ok = emqtt_test_lib:delay_authz(5000),
    ok = emqtt:publish(C, Topic, <<"pingresp_test">>, ?QOS_0),
    _ = retry_if_errors([connected], StateName),
    connected = retry_if_errors([reconnect, waiting_for_connack], StateName),
    Socket = proplists:get_value(socket, emqtt:info(C)),
    %% The new connection outlives three keepalive intervals on the same socket
    timer:sleep(3000),
    ?assertEqual(connected, StateName()),
    ?assertEqual(Socket, proplists:get_value(socket, emqtt:info(C))),
    ok = emqtt:disconnect(C).

t_puback(Config) ->
    ConnFun = ?config(conn_fun, Config),
    Port = ?config(port, Config),
    {ok, C} = emqtt:start_link([{clean_start, true}, {port, Port}]),
    {ok, _} = emqtt:ConnFun(C),
    ok = emqtt:puback(C, 0),
    ok = emqtt:disconnect(C).

t_pubrec(Config) ->
    ConnFun = ?config(conn_fun, Config),
    Port = ?config(port, Config),
    {ok, C} = emqtt:start_link([{clean_start, true}, {port, Port}]),
    {ok, _} = emqtt:ConnFun(C),
    ok = emqtt:pubrec(C, 0),
    ok = emqtt:disconnect(C).

t_pubrel(Config) ->
    ConnFun = ?config(conn_fun, Config),
    Port = ?config(port, Config),
    {ok, C} = emqtt:start_link([{clean_start, true}, {port, Port}]),
    {ok, _} = emqtt:ConnFun(C),
    ok = emqtt:pubrel(C, 0),
    ok = emqtt:disconnect(C).

t_pubcomp(Config) ->
    ConnFun = ?config(conn_fun, Config),
    Port = ?config(port, Config),
    {ok, C} = emqtt:start_link([{clean_start, true}, {port, Port}]),
    {ok, _} = emqtt:ConnFun(C),
    ok = emqtt:pubcomp(C, 0),
    ok = emqtt:disconnect(C).

t_subscriptions(Config) ->
    ConnFun = ?config(conn_fun, Config),
    Port = ?config(port, Config),
    Topic = nth(1, ?TOPICS),

    {ok, C} = emqtt:start_link([{clean_start, true}, {port, Port}]),
    {ok, _} = emqtt:ConnFun(C),

    [] = emqtt:subscriptions(C),
    {ok, _, [0]} = emqtt:subscribe(C, Topic, 0),

    [{Topic, #{qos := 0}}] = emqtt:subscriptions(C),

    ok = emqtt:disconnect(C).

t_info(Config) ->
    ConnFun = ?config(conn_fun, Config),
    Port = ?config(port, Config),
    {ok, C} = emqtt:start_link([{name, test_info}, {clean_start, true}, {port, Port}]),
    {ok, _} = emqtt:ConnFun(C),
    [ ?assertEqual(test_info, Value) || {Key, Value} <- emqtt:info(C), Key =:= name],
    ok = emqtt:disconnect(C).

t_stop(Config) ->
    ConnFun = ?config(conn_fun, Config),
    Port = ?config(port, Config),
    {ok, C} = emqtt:start_link([{clean_start, true}, {port, Port}]),
    {ok, _} = emqtt:ConnFun(C),
    ok = emqtt:stop(C).

t_pause_resume(Config) ->
    ConnFun = ?config(conn_fun, Config),
    Port = ?config(port, Config),
    {ok, C} = emqtt:start_link([{clean_start, true}, {port, Port}]),
    {ok, _} = emqtt:ConnFun(C),
    ok = emqtt:pause(C),
    ok = emqtt:resume(C),
    ok = emqtt:disconnect(C).

t_init(Config) ->
    ConnFun = ?config(conn_fun, Config),
    Port = ?config(port, Config),
    {ok, C1} = emqtt:start_link([{name, test},
                                 {owner, self()},
                                 {host, {127,0,0,1}},
                                 {port, Port},
                                 {ssl, false},
                                 {ssl_opts, #{}},
                                 {clientid, <<"test">>},
                                 {clean_start, true},
                                 {username, <<"username">>},
                                 {password, <<"password">>},
                                 {keepalive, 2},
                                 {connect_timeout, 2},
                                 {ack_timeout, 2},
                                 {force_ping, true},
                                 {properties, #{}},
                                 {max_inflight, 1},
                                 {auto_ack, true},
                                 {bridge_mode, true},
                                 {retry_interval, 10},
                                 {other, ignore},
                                 {proto_ver, v3}]),

    {ok, _} = emqtt:ConnFun(C1),
    ok = emqtt:disconnect(C1),

    {ok, C2} = emqtt:start_link([{proto_ver, v4},
                                 {msg_handler,undefined},
                                 {hosts, [{{127,0,0,1}, Port}]},
                                                % {ws_path, "abcd"},
                                 {max_inflight, infinity},
                                 force_ping,
                                 auto_ack]),
    {ok, _} = emqtt:ConnFun(C2),
    ok = emqtt:disconnect(C2),

    {ok, C3} = emqtt:start_link([{proto_ver, v5},
                                 {port, Port},
                                 {hosts, [{{127,0,0,1}, Port}]},
                                 {will_topic, nth(3, ?TOPICS)},
                                 {will_payload, <<"will_retain_message_test">>},
                                 {will_qos, ?QOS_1},
                                 {will_retain, true},
                                 {will_props, #{}}]),
    {ok, _} = emqtt:ConnFun(C3),
    ok = emqtt:disconnect(C3).

t_init_external_secret(Config) ->
    ConnFun = ?config(conn_fun, Config),
    Port = ?config(port, Config),
    Secret = fun() -> <<"password">> end,
    {ok, C} = emqtt:start_link([{host, {127,0,0,1}},
                                {port, Port},
                                {clientid, <<"test">>},
                                {username, <<"username">>},
                                {password, Secret},
                                {proto_ver, v3}]),
    {ok, _} = emqtt:ConnFun(C),
    ok = emqtt:disconnect(C).

%% The `hosts' list must be tried in the configured order, head first.
%% Regression test: `init/2' used to build the list with a prepending fold,
%% which reversed it.
t_hosts_order_preserved(Config) ->
    ConnFun = ?config(conn_fun, Config),
    process_flag(trap_exit, true),
    Hosts = [{{127,0,0,1}, 10001}, {{127,0,0,2}, 10002}, {{127,0,0,3}, 10003}],
    ok = mock_connect_recorder(conn_mod(ConnFun)),
    {ok, C} = emqtt:start_link([{hosts, Hosts}]),
    %% every connect fails, so the last host's error is returned
    ?assertEqual({error, {refused, {127,0,0,3}, 10003}}, emqtt:ConnFun(C)),
    ?assertEqual(Hosts, collect_connect_attempts()),
    ok.

%% When the first host is down, the client connects to the next one.
t_hosts_failover(_Config) ->
    DeadPort = unused_port(),
    {ok, C} = emqtt:start_link([{hosts, [{{127,0,0,1}, DeadPort},
                                         {{127,0,0,1}, ?TCP_PORT}]}]),
    {ok, _} = emqtt:connect(C),
    ok = emqtt:disconnect(C).

%% With `shuffle_hosts', every connect attempt tries the hosts in a fresh
%% random order: each attempt is a permutation of the configured list, and
%% more than one permutation shows up over many attempts. With 3 hosts and
%% 30 attempts, the chance that all attempts pick the same order is 6^-29.
t_shuffle_hosts_order_varies(Config) ->
    ConnFun = ?config(conn_fun, Config),
    process_flag(trap_exit, true),
    Hosts = [{{127,0,0,1}, 10001}, {{127,0,0,2}, 10002}, {{127,0,0,3}, 10003}],
    ok = mock_connect_recorder(conn_mod(ConnFun)),
    Orders = lists:map(
               fun(_) ->
                       {ok, C} = emqtt:start_link([{hosts, Hosts}, {shuffle_hosts, true}]),
                       {error, {refused, _, _}} = emqtt:ConnFun(C),
                       collect_connect_attempts()
               end, lists:seq(1, 30)),
    lists:foreach(fun(Order) -> ?assertEqual(Hosts, lists:sort(Order)) end, Orders),
    ?assert(length(lists:usort(Orders)) > 1, Orders),
    ok.

%% `{shuffle_hosts, false}' keeps the configured order.
t_shuffle_hosts_disabled(Config) ->
    ConnFun = ?config(conn_fun, Config),
    process_flag(trap_exit, true),
    Hosts = [{{127,0,0,1}, 10001}, {{127,0,0,2}, 10002}, {{127,0,0,3}, 10003}],
    ok = mock_connect_recorder(conn_mod(ConnFun)),
    lists:foreach(
      fun(_) ->
              {ok, C} = emqtt:start_link([{hosts, Hosts}, {shuffle_hosts, false}]),
              ?assertEqual({error, {refused, {127,0,0,3}, 10003}}, emqtt:ConnFun(C)),
              ?assertEqual(Hosts, collect_connect_attempts())
      end, lists:seq(1, 10)),
    ok.

%% With shuffling on and only the last configured host alive, every
%% attempt still ends up connected.
t_shuffle_hosts_failover(_Config) ->
    Hosts = [{{127,0,0,1}, unused_port()},
             {{127,0,0,1}, unused_port()},
             {{127,0,0,1}, ?TCP_PORT}],
    lists:foreach(
      fun(_) ->
              {ok, C} = emqtt:start_link([{hosts, Hosts}, {shuffle_hosts, true}]),
              {ok, _} = emqtt:connect(C),
              ok = emqtt:disconnect(C)
      end, lists:seq(1, 10)),
    ok.

%% Shuffling a single-entry list, or the `host'/`port' fallback used when
%% `hosts' is not set, is a no-op.
t_shuffle_hosts_single(_Config) ->
    {ok, C1} = emqtt:start_link([{hosts, [{{127,0,0,1}, ?TCP_PORT}]},
                                 {shuffle_hosts, true}]),
    {ok, _} = emqtt:connect(C1),
    ok = emqtt:disconnect(C1),
    {ok, C2} = emqtt:start_link([{host, {127,0,0,1}},
                                 {port, ?TCP_PORT},
                                 {shuffle_hosts, true}]),
    {ok, _} = emqtt:connect(C2),
    ok = emqtt:disconnect(C2).

%% With no `ws_upgrade_options', `emqtt_ws:connect/4' passes the default
%% gun ws options through unchanged.
t_ws_upgrade_options_default(_Config) ->
    ok = mock_gun_ws_upgrade(),
    {ok, {_, _}} = emqtt_ws:connect("127.0.0.1", 8083, [], 1000),
    ?assertEqual(#{compress => false,
                    protocols => [{<<"mqtt">>, gun_ws_h}]},
                 collect_ws_upgrade_opts()),
    ok.

%% `ws_upgrade_options' are merged into the default gun ws options, and can
%% both add new options (e.g. `max_frame_size') and override defaults
%% (e.g. `compress').
t_ws_upgrade_options_custom(_Config) ->
    ok = mock_gun_ws_upgrade(),
    {ok, {_, _}} = emqtt_ws:connect("127.0.0.1", 8083,
                                    [{ws_upgrade_options,
                                      [{max_frame_size, 100000},
                                       {compress, true}]}], 1000),
    ?assertEqual(#{compress => true,
                    protocols => [{<<"mqtt">>, gun_ws_h}],
                    max_frame_size => 100000},
                 collect_ws_upgrade_opts()),
    ok.

t_initialized(_) ->
    error('TODO').

t_waiting_for_connack(_) ->
    error('TODO').

t_connected(Config) ->
    ConnFun = ?config(conn_fun, Config),
    Port = ?config(port, Config),
    {ok, C} = emqtt:start_link([{clean_start, true}, {port, Port}]),
    {ok, _} = emqtt:ConnFun(C),
    Clientid = gen_statem:call(C, clientid),
    [ ?assertMatch(Clientid, Value) || {Key, Value} <- emqtt:info(C), Key =:= clientid].

t_qos2_flow_autoack_never(Config) ->
    ConnFun = ?config(conn_fun, Config),
    Port = ?config(port, Config),
    ClientId = atom_to_binary(?FUNCTION_NAME),
    Topic = nth(1, ?TOPICS),
    {ok, C1} = emqtt:start_link([
        {port, Port},
        {clientid, ClientId},
        {clean_start, true},
        {auto_ack, never}
    ]),
    {ok, _} = emqtt:ConnFun(C1),
    {ok, _, [2]} = emqtt:subscribe(C1, Topic, qos2),
    {ok, _} = emqtt:publish(C1, Topic, <<"qos 2">>, 2),
    #{packet_id := PktId} = receive
        {publish, Msg} ->
            ?assertMatch(#{packet_id := _, payload := <<"qos 2">>, qos := 2}, Msg),
            Msg
    after 100 ->
        ct:fail("No message received")
    end,
    ok = emqtt:pubrec(C1, PktId, ?RC_SUCCESS),
    receive
        {pubrel, PubRel} ->
            ?assertMatch(#{packet_id := PktId, reason_code := ?RC_SUCCESS}, PubRel)
    after 100 ->
        ct:fail("No pubrel received")
    end,
    ok = emqtt:pubcomp(C1, PktId, ?RC_SUCCESS),
    ok = emqtt:disconnect(C1),
    {ok, C2} = emqtt:start_link([
        {port, Port},
        {clientid, ClientId},
        {clean_start, false},
        {auto_ack, never}
    ]),
    {ok, _} = emqtt:ConnFun(C2),
    receive
        Anything ->
            ct:fail("Unexpected message: ~p", [Anything])
    after 100 ->
        ok = emqtt:disconnect(C2)
    end.

t_inflight_full(_) ->
    error('TODO').

t_handle_event(_) ->
    error('TODO').

t_terminate(_) ->
    error('TODO').

t_code_change(_) ->
    error('TODO').

t_reason_code_name(_) ->
    error('TODO').

basic_test(Opts) ->
    ConnFun = ?config(conn_fun, Opts),
    Port = ?config(port, Opts),
    Topic = nth(1, ?TOPICS),
    ct:print("Basic test starting"),
    {ok, C} = emqtt:start_link([{port, Port}| Opts]),
    {ok, _} = emqtt:ConnFun(C),
    {ok, _, [1]} = emqtt:subscribe(C, Topic, qos1),
    {ok, _, [2]} = emqtt:subscribe(C, Topic, qos2),
    {ok, _} = emqtt:publish(C, Topic, <<"qos 2">>, 2),
    {ok, _} = emqtt:publish(C, Topic, <<"qos 2">>, 2),
    {ok, _} = emqtt:publish(C, Topic, <<"qos 2">>, 2),
    ?assertEqual(3, length(receive_messages(3))),
    ok = emqtt:disconnect(C).

basic_test_v3(Config) ->
    basic_test([{proto_ver, v3} | Config]).

basic_test_v4(Config) ->
    basic_test([{proto_ver, v4} | Config]).


%%$ NOTE,  Mask the test anonymous_test for emqx 5.0 since `auth' is moved out of emqx core app

%% anonymous_test(_Config) ->
%%     application:set_env(emqx, allow_anonymous, false),

%%     process_flag(trap_exit, true),
%%     {ok, C1} = emqtt:start_link(),
%%     {_,{unauthorized_client,_}} = emqtt:connect(C1),
%%     receive {'EXIT', _, _} -> ok
%%     after 500 -> error("allow_anonymous")
%%     end,
%%     process_flag(trap_exit, false),

%%     application:set_env(emqx, allow_anonymous, true),
%%     {ok, C2} = emqtt:start_link([{username, <<"test">>}, {password, <<"password">>}]),
%%     {ok, _} = emqtt:connect(C2),
%%     ok = emqtt:disconnect(C2).

retry_interval_test(Config) ->
    ConnFun = ?config(conn_fun, Config),
    Port = ?config(port, Config),

    {ok, Pub} = emqtt:start_link([{clean_start, true}, {retry_interval, 2}, {port, Port}]),
    {ok, _} = emqtt:ConnFun(Pub),

    CRef = counters:new(1, [atomics]),

    meck:new(emqtt_sock, [passthrough, no_history]),
    meck:expect(emqtt_sock, send, fun(_, _) -> counters:add(CRef, 1, 1), ok end),

    mock_quic_send(fun(_, _) -> counters:add(CRef, 1, 1) end),

    ok = emqtt:publish_async(Pub, nth(1, ?TOPICS), <<"msg1">>, 1, fun(_) -> ok end),

    timer:sleep(timer:seconds(1)),
    ok = emqtt:publish_async(Pub, nth(1, ?TOPICS), <<"msg2">>, 1, fun(_) -> ok end),

    timer:sleep(timer:seconds(2)),
    %% msg1 resent once
    ?assertEqual(3, counters:get(CRef, 1)),

    timer:sleep(timer:seconds(2)),
    %% msg1 resent twice
    %% msg2 resent once
    ?assertEqual(5, counters:get(CRef, 1)),

    meck:unload(emqtt_sock),
    unmock_quic(),
    ok = emqtt:disconnect(Pub).

will_message_test(Config) ->
    ConnFun = ?config(conn_fun, Config),
    Port = ?config(port, Config),
    {ok, C1} = emqtt:start_link([{clean_start, true}, {port, Port},
                                 {will_topic, nth(3, ?TOPICS)},
                                 {will_payload, <<"client disconnected">>},
                                 {keepalive, 2}]),
    {ok, _} = emqtt:ConnFun(C1),

    {ok, C2} = emqtt:start_link([{port, Port}]),
    {ok, _} = emqtt:ConnFun(C2),

    {ok, _, [2]} = emqtt:subscribe(C2, nth(3, ?TOPICS), 2),
    timer:sleep(10),
    ok = emqtt:stop(C1),
    timer:sleep(5),
    ?assertEqual(1, length(receive_messages(1))),
    ok = emqtt:disconnect(C2),
    ct:print("Will message test succeeded").

will_retain_message_test(Config) ->
    ConnFun = ?config(conn_fun, Config),
    Port = ?config(port, Config),

    Topic = nth(3, ?TOPICS),
    clean_retained(Topic),

    {ok, C1} = emqtt:start_link([{clean_start, true}, {port, Port},
                                 {will_topic, Topic},
                                 {will_payload, <<"will_retain_message_test">>},
                                 {will_qos, ?QOS_1},
                                 {will_retain, true},
                                 {will_props, #{}},
                                 {keepalive, 2}]),
    {ok, _} = emqtt:ConnFun(C1),

    {ok, C2} = emqtt:start_link([{port, Port}]),
    {ok, _} = emqtt:ConnFun(C2),
    {ok, _, [2]} = emqtt:subscribe(C2, Topic, 2),
    timer:sleep(5),
    [?assertMatch( #{qos := 1, retain := false, topic := Topic} ,Msg1) || Msg1 <- receive_messages(1)],
    ok = emqtt:disconnect(C2),

    {ok, C3} = emqtt:start_link([{port, Port}]),
    {ok, _} = emqtt:ConnFun(C3),
    {ok, _, [2]} = emqtt:subscribe(C3, Topic, 2),
    timer:sleep(5),
    [?assertMatch( #{qos := 1, retain := true, topic := Topic} ,Msg2) || Msg2 <- receive_messages(1)],
    ok = emqtt:disconnect(C3),

    %% The broker publishes the will message after it sees C1 go away. Wait
    %% for it, or it can be retained after the clean up below.
    {ok, C4} = emqtt:start_link([{port, Port}]),
    {ok, _} = emqtt:ConnFun(C4),
    {ok, _, [2]} = emqtt:subscribe(C4, Topic, 2),
    ok = emqtt:stop(C1),
    receive
        {publish, #{client_pid := C4, topic := Topic,
                    payload := <<"will_retain_message_test">>}} ->
            ok
    after 5000 ->
            ct:fail(no_will_message)
    end,
    ok = emqtt:disconnect(C4),
    clean_retained(Topic),
    ct:print("Will retain message test succeeded").

offline_message_queueing_test(Config) ->
    ConnFun = ?config(conn_fun, Config),
    Port = ?config(port, Config),

    {ok, C1} = emqtt:start_link([{clean_start, false}, {clientid, <<"c1">>}, {port, Port}]),
    {ok, _} = emqtt:ConnFun(C1),

    {ok, _, [2]} = emqtt:subscribe(C1, nth(6, ?WILD_TOPICS), 2),
    ok = emqtt:disconnect(C1),
    {ok, C2} = emqtt:start_link([{clean_start, true}, {clientid, <<"c2">>}, {port, Port}]),
    {ok, _} = emqtt:ConnFun(C2),

    ok = emqtt:publish(C2, nth(2, ?TOPICS), <<"qos 0">>, 0),
    {ok, _} = emqtt:publish(C2, nth(3, ?TOPICS), <<"qos 1">>, 1),
    {ok, _} = emqtt:publish(C2, nth(4, ?TOPICS), <<"qos 2">>, 2),
    timer:sleep(10),
    emqtt:disconnect(C2),
    {ok, C3} = emqtt:start_link([{clean_start, false}, {clientid, <<"c1">>}, {port, Port}]),
    {ok, _} = emqtt:ConnFun(C3),

    timer:sleep(10),
    emqtt:disconnect(C3),
    ?assertEqual(3, length(receive_messages(3))).

overlapping_subscriptions_test(Config) ->
    ConnFun = ?config(conn_fun, Config),
    Port = ?config(port, Config),

    {ok, C} = emqtt:start_link([{port, Port}]),
    {ok, _} = emqtt:ConnFun(C),

    {ok, _, [2, 1]} = emqtt:subscribe(C, [{nth(7, ?WILD_TOPICS), 2},
                                                {nth(1, ?WILD_TOPICS), 1}]),
    timer:sleep(10),
    {ok, _} = emqtt:publish(C, nth(4, ?TOPICS), <<"overlapping topic filters">>, 2),
    timer:sleep(10),

    Num = length(receive_messages(2)),
    ?assert(lists:member(Num, [1, 2])),
    if
        Num == 1 ->
            ct:print("This server is publishing one message for all
                     matching overlapping subscriptions, not one for each.");
        Num == 2 ->
            ct:print("This server is publishing one message per each
                     matching overlapping subscription.");
        true -> ok
    end,
    emqtt:disconnect(C).

redelivery_on_reconnect_test(Config) ->
    ct:print("Redelivery on reconnect test starting"),
    ConnFun = ?config(conn_fun, Config),
    Port = ?config(port, Config),

    {ok, C1} = emqtt:start_link([{clean_start, false}, {clientid, <<"c">>}, {port, Port}]),
    {ok, _} = emqtt:ConnFun(C1),

    {ok, _, [2]} = emqtt:subscribe(C1, nth(7, ?WILD_TOPICS), 2),
    timer:sleep(10),
    ok = emqtt:pause(C1),
    {ok, _} = emqtt:publish(C1, nth(2, ?TOPICS), <<>>,
                                  [{qos, 1}, {retain, false}]),
    {ok, _} = emqtt:publish(C1, nth(4, ?TOPICS), <<>>,
                                  [{qos, 2}, {retain, false}]),
    timer:sleep(10),
    ok = emqtt:disconnect(C1),
    ?assertEqual(0, length(receive_messages(2))),
    {ok, C2} = emqtt:start_link([{clean_start, false}, {clientid, <<"c">>}, {port, Port}]),
    {ok, _} = emqtt:ConnFun(C2),

    timer:sleep(10),
    ok = emqtt:disconnect(C2),
    ?assertEqual(2, length(receive_messages(2))).

dollar_topics_test(Config) ->
    ConnFun = ?config(conn_fun, Config),
    Port = ?config(port, Config),

    ct:print("$ topics test starting"),
    {ok, C} = emqtt:start_link([{clean_start, true}, {port, Port},
                                      {keepalive, 0}]),
    {ok, _} = emqtt:ConnFun(C),

    {ok, _, [1]} = emqtt:subscribe(C, nth(6, ?WILD_TOPICS), 1),
    {ok, _} = emqtt:publish(C, << <<"$">>/binary, (nth(2, ?TOPICS))/binary>>,
                                  <<"test">>, [{qos, 1}, {retain, false}]),
    timer:sleep(10),
    ?assertEqual(0, length(receive_messages(1))),
    ok = emqtt:disconnect(C),
    ct:print("$ topics test succeeded").

basic_test_v5(Config) ->
    basic_test([{proto_ver, v5} | Config]).

retain_as_publish_test(Config) ->
    ConnFun = ?config(conn_fun, Config),
    Port = ?config(port, Config),
    Topic = nth(3, ?TOPICS),

    clean_retained(Topic),

    {ok, Pub} = emqtt:start_link([{clean_start, true}, {proto_ver, v5}, {port, Port}]),
    {ok, _} = emqtt:ConnFun(Pub),

    {ok, Sub1} = emqtt:start_link([{clean_start, true}, {proto_ver, v5}, {port, Port}]),
    {ok, _} = emqtt:ConnFun(Sub1),

    {ok, Sub2} = emqtt:start_link([{clean_start, true}, {proto_ver, v5}, {port, Port}]),
    {ok, _} = emqtt:ConnFun(Sub2),

    %% Subscribe before the PUBLISH: a retained message sent on subscription
    %% always has the RETAIN flag set, whatever Retain As Published says.
    {ok, _, [2]} = emqtt:subscribe(Sub1, Topic, 2),
    {ok, _, [2]} = emqtt:subscribe(Sub2, Topic, [{qos, 2}, {rap, true}]),

    {ok, _} = emqtt:publish(Pub, Topic, #{}, <<"retain_as_publish_test">>, [{qos, ?QOS_1}, {retain, true}]),

    Msgs = receive_messages(2),
    ?assertMatch([#{qos := 1, retain := false, topic := Topic}],
                 [M || M = #{client_pid := P} <- Msgs, P =:= Sub1]),
    ?assertMatch([#{qos := 1, retain := true, topic := Topic}],
                 [M || M = #{client_pid := P} <- Msgs, P =:= Sub2]),
    ok = emqtt:disconnect(Sub1),
    ok = emqtt:disconnect(Sub2),

    ok = emqtt:disconnect(Pub),
    clean_retained(Topic).

t_active_default_recv(Config) ->
    ConnFun = ?config(conn_fun, Config),
    Port = ?config(port, Config),
    Topic = atom_to_binary(?FUNCTION_NAME),
    {ok, Sub} = emqtt:start_link([{clean_start, true}, {port, Port}]),
    {ok, _} = emqtt:ConnFun(Sub),
    SockOpts = proplists:get_value(sock_opts, emqtt:info(Sub)),
    ?assertEqual(once, proplists:get_value(active, SockOpts, once)),
    {ok, _, _} = emqtt:subscribe(Sub, Topic, ?QOS_0),
    {ok, Pub} = emqtt:start_link([{clean_start, true}, {port, Port}]),
    {ok, _} = emqtt:ConnFun(Pub),
    N = 5,
    lists:foreach(
        fun(I) ->
            ok = emqtt:publish(Pub, Topic, integer_to_binary(I), ?QOS_0)
        end,
        lists:seq(1, N)
    ),
    ?assertEqual(N, length(receive_messages(N))),
    ok = emqtt:disconnect(Sub),
    ok = emqtt:disconnect(Pub).

t_active_n_rearm(Config) ->
    ConnFun = ?config(conn_fun, Config),
    case ConnFun of
        quic_connect ->
            ct:pal("skipped: active_n tcp test is not applicable for QUIC", []),
            ok;
        _ ->
            Port = ?config(port, Config),
            Topic = atom_to_binary(?FUNCTION_NAME),
            ActiveN = 3,
            {ok, Sub} = emqtt:start_link([{clean_start, true}, {port, Port},
                                           {tcp_opts, [{active, ActiveN}]}]),
            {ok, _} = emqtt:connect(Sub),
            SockOpts = proplists:get_value(sock_opts, emqtt:info(Sub)),
            ?assertEqual(ActiveN, proplists:get_value(active, SockOpts)),
            {ok, _, _} = emqtt:subscribe(Sub, Topic, ?QOS_1),
            NumMsgs = ActiveN * 2 + 1,
            {ok, Pub} = emqtt:start_link([{clean_start, true}, {port, Port}]),
            {ok, _} = emqtt:connect(Pub),
            lists:foreach(
                fun(I) ->
                    {ok, _} = emqtt:publish(Pub, Topic, integer_to_binary(I), [{qos, 1}])
                end,
                lists:seq(1, NumMsgs)
            ),
            %% Receiving all messages proves activate_sock re-armed the socket
            %% with ActiveN after each tcp_passive event
            ?assertEqual(NumMsgs, length(receive_messages(NumMsgs))),
            %% Socket must be set to {active, ActiveN}, not {active, once}
            Sock = proplists:get_value(socket, emqtt:info(Sub)),
            {ok, [{active, ActiveNow}]} = inet:getopts(Sock, [active]),
            ?assert((ActiveNow > 0 andalso ActiveNow =< ActiveN) orelse ActiveNow =:= false),
            ok = emqtt:disconnect(Sub),
            ok = emqtt:disconnect(Pub)
    end.

%% Verifies that {active, N} sockets re-arm correctly on TLS, so the
%% subscriber keeps receiving past the first active-N window.
t_active_n_rearm_ssl(Config) ->
    %% An earlier case can leave the ssl:default listener requiring a client
    %% cert (mTLS). Reset it to the image's certs with verify_none so the
    %% test exercises the active-N rearm path and not cert-chain validation.
    ok = emqtt_test_lib:set_ssl_options(<<"ssl:default">>, #{verify => verify_none}),
    Port = proplists:get_value(ssl_port, Config, 8883),
    Topic = atom_to_binary(?FUNCTION_NAME),
    ActiveN = 3,
    SslOpts = [{verify, verify_none}],
    {ok, Sub} = emqtt:start_link([{clean_start, true},
                                  {port, Port},
                                  {ssl, true},
                                  {ssl_opts, SslOpts},
                                  {tcp_opts, [{active, ActiveN}]}]),
    {ok, _} = emqtt:connect(Sub),
    SockOpts = proplists:get_value(sock_opts, emqtt:info(Sub)),
    ?assertEqual(ActiveN, proplists:get_value(active, SockOpts)),
    {ok, _, _} = emqtt:subscribe(Sub, Topic, ?QOS_1),

    NumMsgs = ActiveN * 2 + 1,
    {ok, Pub} = emqtt:start_link([{clean_start, true},
                                  {port, Port},
                                  {ssl, true},
                                  {ssl_opts, SslOpts}]),
    {ok, _} = emqtt:connect(Pub),
    lists:foreach(
      fun(I) ->
              {ok, _} = emqtt:publish(Pub, Topic, integer_to_binary(I),
                                      [{qos, 1}])
      end,
      lists:seq(1, NumMsgs)),

    Received = receive_messages(NumMsgs),
    ct:pal("received ~p of ~p expected messages", [length(Received), NumMsgs]),
    ?assertEqual(NumMsgs, length(Received)),

    ok = emqtt:disconnect(Sub),
    ok = emqtt:disconnect(Pub).

merge_config(Config1, Config2) ->
    lists:foldl(
      fun({K,V}, Acc) ->
              lists:keystore(K, 1, Acc, {K,V})
      end, Config1, Config2).

retry_if_errors(Errors, Fun) ->
    E = Fun(),
    case lists:member(E, Errors) of
        true ->
            timer:sleep(200),
            ?FUNCTION_NAME(Errors, Fun);
        false ->
            E
    end.

test_dir(Config) ->
    filename:dirname(filename:dirname(proplists:get_value(data_dir, Config))).

cert_dir(Config) ->
    filename:join([test_dir(Config), "certs"]).


mock_quic_send(F) ->
    case emqtt_test_lib:has_quic() of
        true ->
            meck:new(emqtt_quic, [passthrough, no_history]),
            meck:expect(emqtt_quic, send, F),
            ok;
        false ->
            ok
    end.

unmock_quic() ->
    case emqtt_test_lib:has_quic() of
        true ->
            meck:unload(emqtt_quic);
        false ->
            ok
    end.

%% Mock `ConnMod:connect/4' so every attempt fails and is reported to the
%% test process as `{connect_attempt, Host, Port}'.
mock_connect_recorder(ConnMod) ->
    Self = self(),
    meck:new(ConnMod, [passthrough, no_history]),
    meck:expect(ConnMod, connect,
                fun(Host, Port, _SockOpts, _Timeout) ->
                        Self ! {connect_attempt, Host, Port},
                        {error, {refused, Host, Port}}
                end),
    ok.

%% Return the recorded `{Host, Port}' connect attempts, oldest first.
collect_connect_attempts() ->
    receive
        {connect_attempt, Host, Port} ->
            [{Host, Port} | collect_connect_attempts()]
    after 0 ->
        []
    end.

conn_mod(quic_connect) -> emqtt_quic;
conn_mod(connect) -> emqtt_sock.

%% Mock `gun:open/3', `gun:await_up/2' and `gun:ws_upgrade/4' so that
%% `emqtt_ws:connect/4' completes without a real connection, reporting the
%% `WsOpts' passed to `ws_upgrade/4' to the test process.
mock_gun_ws_upgrade() ->
    Self = self(),
    meck:new(gun, [passthrough, no_history]),
    meck:expect(gun, open, fun(_Host, _Port, _Opts) -> {ok, self()} end),
    meck:expect(gun, await_up, fun(_ConnPid, _Timeout) -> {ok, http} end),
    meck:expect(gun, ws_upgrade,
                fun(ConnPid, _Path, _Headers, WsOpts) ->
                        StreamRef = make_ref(),
                        Self ! {ws_upgrade_opts, WsOpts},
                        ConnPid ! {gun_upgrade, ConnPid, StreamRef, [<<"websocket">>], []},
                        StreamRef
                end),
    ok.

%% Return the `WsOpts' map recorded by `mock_gun_ws_upgrade/0'.
collect_ws_upgrade_opts() ->
    receive
        {ws_upgrade_opts, WsOpts} -> WsOpts
    after 0 ->
        undefined
    end.

%% A TCP port nothing listens on.
unused_port() ->
    {ok, LSock} = gen_tcp:listen(0, [{ip, {127,0,0,1}}]),
    {ok, Port} = inet:port(LSock),
    ok = gen_tcp:close(LSock),
    Port.

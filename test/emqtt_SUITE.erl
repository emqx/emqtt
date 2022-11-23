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

-module(emqtt_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-import(lists, [nth/2]).

-include("emqtt.hrl").

-include_lib("eunit/include/eunit.hrl").

-include_lib("common_test/include/ct.hrl").

-define(TOPICS, [<<"TopicA">>, <<"TopicA/B">>, <<"Topic/C">>, <<"TopicA/C">>,
                 <<"/TopicA">>]).

-define(WILD_TOPICS, [<<"TopicA/+">>, <<"+/C">>, <<"#">>, <<"/#">>, <<"/+">>,
                      <<"+/+">>, <<"TopicA/#">>]).

-define(WAIT(Pattern, Result),
        receive
            Pattern ->
                Result
        after 5000 -> error(timeout)
        end).

all() ->
    [ {group, general}
    , {group, mqttv3}
    , {group, mqttv4}
    , {group, mqttv5}
    , {group, quic}
    ].

groups() ->
    [{general, [],
      [t_connect,
       t_connect_timeout,
       t_ws_connect,
       t_subscribe,
       t_subscribe_qoe,
       t_publish,
       t_publish_reply_error,
       t_publish_process_monitor,
       t_publish_port_error,
       t_publish_port_error_retry,
       t_publish_async,
       t_eval_callback_in_order,
       t_ack_inflight_and_shoot_cycle,
       t_unsubscribe,
       t_ping,
       t_puback,
       t_pubrec,
       t_pubrel,
       t_pubcomp,
       t_reconnect_disabled,
       t_reconnect_enabled,
       t_reconnect_stop,
       t_subscriptions,
       t_info,
       t_stop,
       t_pause_resume,
       t_init,
       t_connected]},
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
       retain_as_publish_test]},
     {quic, [], [ {group, general}
                , {group, mqttv3}
                , {group, mqttv4}
                , {group, mqttv5}
                ]
     }
    ].

suite() ->
    [{timetrap, {seconds, 60}}].

init_per_suite(Config) ->
    ok = emqtt_test_lib:start_emqx(),
    Config.

end_per_suite(_Config) ->
    emqtt_test_lib:stop_emqx().

init_per_testcase(_TC, Config) ->
    ok = emqx_common_test_helpers:ensure_quic_listener(mqtt, 14567),
    Config.

end_per_testcase(TC, _Config)
  when TC =:= t_reconnect_enabled orelse
       TC =:= t_reconnect_disabled orelse
       TC =:= t_reconnect_stop ->
    process_flag(trap_exit, false),
    ok = emqtt_test_lib:start_emqx(),
    ok;
end_per_testcase(_TC, _Config) ->
    ok.

init_per_group(quic, Config) ->
    merge_config(Config, [{port, 14567}, {conn_fun, quic_connect}]);
init_per_group(_, Config) ->
    case lists:keyfind(conn_fun, 1, Config) of
        false ->
            merge_config(Config, [{port, 1883}, {conn_fun, connect}]);
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

    meck:new(emqtt_quic, [passthrough, no_history]),
    meck:expect(emqtt_quic, send, F),

    ?assertEqual({error, connack_timeout}, emqtt:ConnFun(C)),

    meck:unload(emqtt_sock),
    meck:unload(emqtt_quic).

t_reconnect_disabled(Config) ->
    ConnFun = ?config(conn_fun, Config),
    Port = ?config(port, Config),
    process_flag(trap_exit, true),
    {ok, C} = emqtt:start_link([{port, Port}]),
    {ok, _} = emqtt:ConnFun(C),
    MRef = erlang:monitor(process, C),
    ok = emqtt_test_lib:stop_emqx(),
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

t_reconnect_enabled(Config) ->
    ConnFun = ?config(conn_fun, Config),
    Port = ?config(port, Config),
    Topic = nth(1, ?TOPICS),
    process_flag(trap_exit, true),
    {ok, C} = emqtt:start_link([{port, Port},
                                {reconnect, true},
                                {connect_timeout, 1}]), % 1 sec
    {ok, _} = emqtt:ConnFun(C),
    MRef = erlang:monitor(process, C),
    ok = emqtt_test_lib:stop_emqx(),
    false = retry_if_errors([true], fun emqx:is_running/0),
    receive
        {'DOWN', MRef, process, C, _Info} ->
            ct:fail(conn_dead)
    after 100 ->
            timer:apply_after(5000, emqtt_test_lib, start_emqx, []),
            true = retry_if_errors([false], fun emqx:is_running/0),
            ct:pal("emqx is up"),
            connected = retry_if_errors([reconnect, waiting_for_connack],
                                       fun() ->
                                               {StateName, _Data} = sys:get_state(C),
                                               StateName
                                       end),
            ct:pal("Old client is reconnected"),
            {ok, _, [0]} = emqtt:subscribe(C, Topic),
            {ok, C2} = emqtt:start_link([{port, Port}, {reconnect, true}]),
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

t_reconnect_stop(Config) ->
    ConnFun = ?config(conn_fun, Config),
    Port = ?config(port, Config),
    process_flag(trap_exit, true),
    {ok, C} = emqtt:start_link([{port, Port},
                                {reconnect, true},
                                {connect_timeout, 1}]), % 1 sec
    {ok, _} = emqtt:ConnFun(C),
    MRef = erlang:monitor(process, C),
    ok = emqtt_test_lib:stop_emqx(),
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

t_ws_connect(_) ->
    {ok, C} = emqtt:start_link([{clean_start, true}, {host,"127.0.0.1"}, {port, 8083}]),
    {ok, _} = emqtt:ws_connect(C),
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
    ?assert(is_map(proplists:get_value(qoe, emqtt:info(C)))),
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

    meck:new(emqtt_quic, [passthrough, no_history]),
    meck:expect(emqtt_quic, send, fun(_, _) -> {error, closed} end),

    ?assertEqual({error, closed}, emqtt:publish(C, Topic, <<"t_publish">>)),

    %% shutdown if an send error occured
    receive
        {'EXIT', C, _} -> ok
    after 1000 ->
              ?assert(false)
    end,

    meck:unload(emqtt_sock),
    meck:unload(emqtt_quic).

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

    meck:new(emqtt_quic, [passthrough, no_history]),
    meck:expect(emqtt_quic, send, fun(_, _) -> ok end),

    %% kill client process
    spawn(fun() -> timer:sleep(1000), exit(C, kill) end),

    ?assertException(exit, killed, emqtt:publish(C, Topic, <<"t_publish">>, ?QOS_1)),

    meck:unload(emqtt_sock),
    meck:unload(emqtt_quic).

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
                              io:format(user, "~p\n", [sys:get_state(C)]),
                              ct:fail(timeout)
                    end,
    ?assertEqual({error, {shutdown, killed}}, PublishResult),
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
    {ok, C} = emqtt:start_link([{clean_start, true},
                                {port, Port},
                                %% no timer based retry, test state transition retry
                                {retry_interval, 1},
                                {reconnect, true},
                                %% seconds
                                {connect_timeout, 2}
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
                                     io:format(user, "~p~n", [sys:get_state(C)]),
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
    emqtt:stop(C),
    %% should still get a reply, but not EXIT exception!
    Result = ?WAIT({publish_result, R}, R),
    ?assertEqual(Result, {error, normal}),
    meck:unload(emqtt_sock).

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

    CollectFun =
        fun _CollectFun(Acc) ->
                receive
                    {publish_async_result, N, Result} ->
                        _CollectFun([{N, Result} | Acc])
                after 5000 ->
                      lists:reverse(Acc)
                end
        end,
    ?assertMatch([{1, ok},
                  {2, ok},
                  {3, ok},
                  {4, {ok, _}},
                  {5, {ok, _}}], CollectFun([])),
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

    meck:new(emqtt_quic, [passthrough, no_history]),
    meck:expect(emqtt_quic, send, fun(_, _) -> ok end),

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
    meck:unload(emqtt_quic),

    meck:new(emqtt_sock, [passthrough, no_history]),
    meck:expect(emqtt_sock, send, fun(_, _) -> {error, closed} end),

    meck:new(emqtt_quic, [passthrough, no_history]),
    meck:expect(emqtt_quic, send, fun(_, _) -> {error, closed} end),

    CollectFun =
        fun _CollectFun(Acc) ->
                receive
                    {publish_async_result, N, Result} ->
                        _CollectFun([{N, Result} | Acc]);
                    {'EXIT', C, _} = Msg ->
                        _CollectFun([Msg | Acc])
                after 5000 ->
                      lists:reverse(Acc)
                end
        end,
    ?assertMatch([{1, ok}, %% qos0: treat send as successfully
                  {2, {error, closed}}, %% from inflight
                  {3, {error, closed}},
                  {4, {error, closed}}, %% from pending request queue
                  {5, {error, closed}},
                  {'EXIT', C, closed}], CollectFun([])),

    meck:unload(emqtt_sock),
    meck:unload(emqtt_quic).

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

    ok = meck:new(emqtt_quic, [passthrough, no_history]),
    ok = meck:expect(emqtt_quic, send, SendFun),

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
    ok = meck:unload(emqtt_quic),
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

    meck:new(emqtt_quic, [passthrough, no_history]),
    meck:expect(emqtt_quic, send, fun(_, _) -> counters:add(CRef, 1, 1), ok end),

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
    meck:unload(emqtt_quic),
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

    ok = emqtt:stop(C1),
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

    {ok, _} = emqtt:publish(Pub, Topic, #{}, <<"retain_as_publish_test">>, [{qos, ?QOS_1}, {retain, true}]),
    timer:sleep(10),

    {ok, _, [2]} = emqtt:subscribe(Sub1, Topic, 2),
    timer:sleep(5),
    [?assertMatch( #{qos := 1, retain := false, topic := Topic} ,Msg1) || Msg1 <- receive_messages(1)],
    ok = emqtt:disconnect(Sub1),


    {ok, _, [2]} = emqtt:subscribe(Sub2, Topic, [{qos, 2}, {rap, true}]),
    timer:sleep(5),
    [?assertMatch( #{qos := 1, retain := true, topic := Topic} ,Msg2) || Msg2 <- receive_messages(1)],
    ok = emqtt:disconnect(Sub2),

    ok = emqtt:disconnect(Pub),
    clean_retained(Topic).

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

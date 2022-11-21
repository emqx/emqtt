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
-include_lib("common_test/include/ct.hrl").


all() ->
    [
     {group, mstream},
     t_quic_sock,
     t_quic_sock_fail,
     t_0_rtt,
     t_0_rtt_fail
    ].

groups() ->
    [ {mstream, [], [{group, pub_qos0},
                     {group, pub_qos1},
                     {group, pub_qos2}
                    ]},
      {pub_qos0, [], [{group, sub_qos0},
                      {group, sub_qos1},
                      {group, sub_qos2}
                     ]},
      {pub_qos1, [], [{group, sub_qos0},
                      {group, sub_qos1},
                      {group, sub_qos2}
                     ]},
      {pub_qos2, [], [{group, sub_qos0},
                      {group, sub_qos1},
                      {group, sub_qos2}
                     ]},
      {sub_qos0, [{group, quic}]},
      {sub_qos1, [{group, quic}]},
      {sub_qos2, [{group, quic}]},
      {quic, [t_multi_streams_sub,
              t_multi_streams_pub_parallel,
              t_multi_streams_sub_pub_async,
              t_multi_streams_sub_pub_sync,
              t_multi_streams_unsub,
              t_multi_streams_corr_topic,
              t_multi_streams_unsub_via_other
             ]}
    ].

init_per_suite(Config) ->
    UdpPort = 14567,
    emqtt_test_lib:start_emqx(),
    application:ensure_all_started(quicer),
    ok = emqx_common_test_helpers:ensure_quic_listener(mqtt, UdpPort),

    dbg:tracer(process, {fun dbg:dhandler/2, group_leader()}),
    dbg:p(all, c),
    %dbg:tpl(emqtt_quic, cx),
    %dbg:tpl(emqx_quic_data_stream, cx),
    %dbg:tpl(emqtt_quic_stream, handle_stream_data, cx),
    %dbg:tpl(emqx_quic_data_stream, with_channel, cx),
    dbg:tpl(emqx_frame,parse,cx),
    dbg:tpl(emqx_quic_data_stream, do_handle_appl_msg, cx),
    [{port, UdpPort} | Config].

end_per_suite(_) ->
    emqtt_test_lib:stop_emqx(),
    ok.

init_per_group(pub_qos0, Config) ->
    [{pub_qos, 0} | Config];
init_per_group(sub_qos0, Config) ->
    [{sub_qos, 0} | Config];
init_per_group(pub_qos1, Config) ->
    [{pub_qos, 1} | Config];
init_per_group(sub_qos1, Config) ->
    [{sub_qos, 1} | Config];
init_per_group(pub_qos2, Config) ->
    [{pub_qos, 2} | Config];
init_per_group(sub_qos2, Config) ->
    [{sub_qos, 2} | Config];
init_per_group(_, Config) ->
    Config.

end_per_group(_, Config) ->
    Config.

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

t_quic_sock_fail(_Config) ->
    Port = 4567,
    Error = {error, {transport_down,#{ error => 2,
                                       status => connection_refused}}
            },
    Error = emqtt_quic:connect("localhost",
                               Port,
                               [{alpn, ["mqtt"]}, {active, false}],
                               3000).

t_0_rtt(Config) ->
    Port = 4568,
    SslOpts = [ {cert, certfile(Config)}
              , {key,  keyfile(Config)}
              , {idle_timeout_ms, 10000}
              , {server_resumption_level, 2} % QUIC_SERVER_RESUME_AND_ZERORTT
              , {peer_bidi_stream_count, 10}
              , {alpn, ["mqtt"]}
              ],
    Server = quic_server:start_link(Port, SslOpts),
    timer:sleep(500),
    {ok, {quic, Conn, _Stream} = Sock} = emqtt_quic:connect("localhost",
                                                          Port,
                                                          [ {alpn, ["mqtt"]}, {active, false}
                                                          , {quic_event_mask, 1}
                                                          ],
                                                          3000),
    send_and_recv_with(Sock),
    ok = emqtt_quic:close(Sock),
    NST = receive
              {quic, nst_received, Conn, Ticket} ->
                  Ticket
          end,
    {ok, Sock2} = emqtt_quic:connect("localhost",
                                     Port,
                                     [{alpn, ["mqtt"]}, {active, false},
                                      {nst, NST}
                                     ],
                                     3000),
    send_and_recv_with(Sock2),
    ok = emqtt_quic:close(Sock2),
    quic_server:stop(Server).

t_0_rtt_fail(Config) ->
    Port = 4569,
    SslOpts = [ {cert, certfile(Config)}
              , {key,  keyfile(Config)}
              , {idle_timeout_ms, 10000}
              , {server_resumption_level, 2} % QUIC_SERVER_RESUME_AND_ZERORTT
              , {peer_bidi_stream_count, 10}
              , {alpn, ["mqtt"]}
              ],
    Server = quic_server:start_link(Port, SslOpts),
    timer:sleep(500),
    {ok, {quic, Conn, _Stream} = Sock} = emqtt_quic:connect("localhost",
                                                          Port,
                                                          [ {alpn, ["mqtt"]}, {active, false}
                                                          , {quic_event_mask, 1}
                                                          ],
                                                          3000),
    send_and_recv_with(Sock),
    ok = emqtt_quic:close(Sock),
    << _Head:16, Left/binary>> = receive
                                    {quic, nst_received, Conn, Ticket} when is_binary(Ticket) ->
                                        Ticket
                                end,

    Error = {error, {not_found, invalid_parameter}},
    Error = emqtt_quic:connect("localhost",
                               Port,
                               [{alpn, ["mqtt"]}, {active, false},
                                {nst, Left}
                               ],
                               3000),
    quic_server:stop(Server).

t_multi_streams_sub(Config) ->
    PubQos = ?config(pub_qos, Config),
    SubQos = ?config(sub_qos, Config),
    RecQos = calc_qos(PubQos, SubQos),
    Topic = atom_to_binary(?FUNCTION_NAME),
    {ok, C} = emqtt:start_link([{proto_ver, v5} | Config]),
    {ok, _} = emqtt:quic_connect(C),
    {ok, _, [SubQos]} = emqtt:subscribe_via(C, {new_data_stream, []}, #{}, [{Topic, [{qos, SubQos}]}]),
    case emqtt:publish(C, Topic, <<"qos 2 1">>, PubQos) of
        ok when PubQos == 0 -> ok;
        {ok, _} ->
            ok
    end,
    receive
        {publish,#{ client_pid := C
                  , payload := <<"qos 2 1">>
                  , qos := RecQos
                  , topic := Topic
                  }
        } ->
            ok;
        Other ->
            ct:fail("unexpected recv ~p", [Other] )
    after 100 ->
            ct:fail("not received")
    end,
    ok = emqtt:disconnect(C).


t_multi_streams_pub_parallel(Config) ->
    PubQos = ?config(pub_qos, Config),
    SubQos = ?config(sub_qos, Config),
    RecQos = calc_qos(PubQos, SubQos),
    PktId1 = calc_pkt_id(RecQos, 1),
    PktId2 = calc_pkt_id(RecQos, 2),
    Topic = atom_to_binary(?FUNCTION_NAME),
    {ok, C} = emqtt:start_link([{proto_ver, v5} | Config]),
    {ok, _} = emqtt:quic_connect(C),
    {ok, _, [SubQos]} = emqtt:subscribe(C, #{}, [{Topic, [{qos, SubQos}]}]),
    ok = emqtt:publish_async(C, {new_data_stream, []}, Topic,  <<"stream data 1">>, [{qos, PubQos}],
                             undefined),
    ok = emqtt:publish_async(C, {new_data_stream, []}, Topic,  <<"stream data 2">>, [{qos, PubQos}],
                             undefined),
    PubRecvs = recv_pub(2),
    ?assertMatch(
       [ {publish,#{ client_pid := C
                   , packet_id := PktId1
                   , payload := <<"stream data", _/binary>>
                   , qos := RecQos
                   , topic := Topic
                   }
         }
       , {publish,#{ client_pid := C
                   , packet_id := PktId2
                   , payload := <<"stream data", _/binary>>
                   , qos := RecQos
                   , topic := Topic
                   }
         }
       ], PubRecvs),
    Payloads = [ P || {publish, #{payload := P}} <- PubRecvs ],
    ?assert([<<"stream data 1">>, <<"stream data 2">>] == Payloads orelse
            [<<"stream data 2">>, <<"stream data 1">>] == Payloads),
    ok = emqtt:disconnect(C).

t_multi_streams_sub_pub_async(Config) ->
    Topic = atom_to_binary(?FUNCTION_NAME),
    PubQos = ?config(pub_qos, Config),
    SubQos = ?config(sub_qos, Config),
    RecQos = calc_qos(PubQos, SubQos),
    PktId1 = calc_pkt_id(RecQos, 1),
    Topic2 = << Topic/binary, "_two">>,
    {ok, C} = emqtt:start_link([{proto_ver, v5} | Config]),
    {ok, _} = emqtt:quic_connect(C),
    {ok, _, [SubQos]} = emqtt:subscribe_via(C, {new_data_stream, []}, #{}, [{Topic, [{qos, SubQos}]}]),
    {ok, _, [SubQos]} = emqtt:subscribe_via(C, {new_data_stream, []}, #{}, [{Topic2, [{qos, SubQos}]}]),
    ok = emqtt:publish_async(C, {new_data_stream, []}, Topic,  <<"stream data 1">>, [{qos, PubQos}],
                             undefined),
    ok = emqtt:publish_async(C, {new_data_stream, []}, Topic2,  <<"stream data 2">>, [{qos, PubQos}],
                             undefined),
    PubRecvs = recv_pub(2),
    ?assertMatch(
       [ {publish, #{ client_pid := C
                    , packet_id := PktId1
                    , payload := <<"stream data", _/binary>>
                    , qos := RecQos
                    }
         }
       , {publish, #{ client_pid := C
                    , packet_id := PktId1
                    , payload := <<"stream data", _/binary>>
                    , qos := RecQos
                    }
         }
       ], PubRecvs),
    Payloads = [ P || {publish, #{payload := P}} <- PubRecvs ],
    ?assert( [<<"stream data 1">>, <<"stream data 2">>] == Payloads orelse
             [<<"stream data 2">>, <<"stream data 1">>] == Payloads),
    ok = emqtt:disconnect(C).

t_multi_streams_sub_pub_sync(Config) ->
    PubQos = ?config(pub_qos, Config),
    SubQos = ?config(sub_qos, Config),
    RecQos = calc_qos(PubQos, SubQos),
    PktId1 = calc_pkt_id(RecQos, 1),
    Topic = atom_to_binary(?FUNCTION_NAME),
    Topic2 = << Topic/binary, "two">>,
    {ok, C} = emqtt:start_link([{proto_ver, v5} | Config]),
    {ok, _} = emqtt:quic_connect(C),
    {ok, #{via := SVia1}, [SubQos]} = emqtt:subscribe_via(C, {new_data_stream, []}, #{}, [{Topic, [{qos, SubQos}]}]),
    {ok, #{via := SVia2}, [SubQos]} = emqtt:subscribe_via(C, {new_data_stream, []}, #{}, [{Topic2, [{qos, SubQos}]}]),

    case emqtt:publish_via(C, {new_data_stream, []}, Topic, #{},  <<"stream data 3">>, [{qos, PubQos}]) of
        ok when PubQos == 0 ->
            Via1 = undefined,
            ok;
        {ok, #{reason_code := 0, via := Via1}} -> ok
    end,
    case emqtt:publish_via(C, {new_data_stream, []}, Topic2, #{},  <<"stream data 4">>, [{qos, PubQos}]) of
        ok when PubQos == 0 -> ok;
        {ok, #{reason_code := 0, via := Via2}} ->
            ?assert(Via1 =/= Via2),
            ok
    end,
    ct:pal("SVia1: ~p, SVia2: ~p", [SVia1, SVia2]),
    PubRecvs = recv_pub(2),
    ?assertMatch(
       [ {publish, #{ client_pid := C
                    , packet_id := PktId1
                    , payload := <<"stream data 3">>
                    , qos := RecQos
                    , via := SVia1
                    }
         }
       , {publish, #{ client_pid := C
                    , packet_id := PktId1
                    , payload := <<"stream data 4">>
                    , qos := RecQos
                    , via := SVia2
                    }
         }
       ], PubRecvs),
    ok = emqtt:disconnect(C).

t_multi_streams_corr_topic(Config) ->
    PubQos = ?config(pub_qos, Config),
    SubQos = ?config(sub_qos, Config),
    RecQos = calc_qos(PubQos, SubQos),
    PktId1 = calc_pkt_id(RecQos, 1),
    PktId2 = calc_pkt_id(RecQos, 2),
    Topic = atom_to_binary(?FUNCTION_NAME),
    {ok, C} = emqtt:start_link([{proto_ver, v5} | Config]),
    {ok, _} = emqtt:quic_connect(C),
    {ok, #{via := SubVia}, [SubQos]} = emqtt:subscribe_via(C, {new_data_stream, []}, #{}, [{Topic, [{qos, SubQos}]}]),

    case emqtt:publish_via(C, {new_data_stream, []}, Topic, #{},  <<1,2,3,4,5>>, [{qos, PubQos}]) of
        ok when PubQos == 0 ->
            ok;
        {ok, #{reason_code := 0, via := _Via}} -> ok
    end,

    #{data_stream_socks := [PubVia | _]} = proplists:get_value(extra, emqtt:info(C)),
    ?assert(PubVia =/= SubVia),

    case emqtt:publish_via(C, PubVia, Topic, #{},  <<6,7,8,9>>, [{qos, PubQos}]) of
        ok when PubQos == 0 -> ok;
        {ok, #{reason_code := 0, via := PubVia}} -> ok
    end,
    PubRecvs = recv_pub(2),
    ?assertMatch(
       [ {publish, #{ client_pid := C
                    , packet_id := PktId1
                    , payload := <<1,2,3,4,5>>
                    , qos := RecQos
                    }
         }
       , {publish, #{ client_pid := C
                    , packet_id := PktId2
                    , payload := <<6,7,8,9>>
                    , qos := RecQos
                    }
         }
       ], PubRecvs),
    ok = emqtt:disconnect(C).

t_multi_streams_unsub(Config) ->
    PubQos = ?config(pub_qos, Config),
    SubQos = ?config(sub_qos, Config),
    RecQos = calc_qos(PubQos, SubQos),
    PktId1 = calc_pkt_id(RecQos, 1),

    Topic = atom_to_binary(?FUNCTION_NAME),
    {ok, C} = emqtt:start_link([{proto_ver, v5} | Config]),
    {ok, _} = emqtt:quic_connect(C),
    {ok, #{via := SubVia}, [SubQos]} = emqtt:subscribe_via(C, {new_data_stream, []}, #{}, [{Topic, [{qos, SubQos}]}]),
    case emqtt:publish_via(C, {new_data_stream, []}, Topic, #{},  <<1,2,3,4,5>>, [{qos, PubQos}]) of
        ok when PubQos == 0 ->
            ok;
        {ok, #{reason_code := 0, via := _PVia}} ->
            ok
    end,

    #{data_stream_socks := [PubVia | _]} = proplists:get_value(extra, emqtt:info(C)),
    ?assert(PubVia =/= SubVia),
    PubRecvs = recv_pub(1),
    ?assertMatch(
       [ {publish, #{ client_pid := C
                    , packet_id := PktId1
                    , payload := <<1,2,3,4,5>>
                    , qos := RecQos
                    }
         }
       ], PubRecvs),

    emqtt:unsubscribe_via(C, SubVia, Topic),

    case emqtt:publish_via(C, PubVia, Topic, #{},  <<6,7,8,9>>, [{qos, PubQos}]) of
        ok when PubQos == 0 ->
            ok;
        {ok, #{reason_code := 16, via := PubVia, reason_code_name := no_matching_subscribers }} ->
            ok
    end,

    timeout = recv_pub(1),
    ok = emqtt:disconnect(C).

t_multi_streams_unsub_via_other(Config) ->
    PubQos = ?config(pub_qos, Config),
    SubQos = ?config(sub_qos, Config),
    RecQos = calc_qos(PubQos, SubQos),
    PktId1 = calc_pkt_id(RecQos, 1),
    PktId2 = calc_pkt_id(RecQos, 2),

    Topic = atom_to_binary(?FUNCTION_NAME),
    Topic2 = << Topic/binary, "two">>,
    {ok, C} = emqtt:start_link([{proto_ver, v5} | Config]),
    {ok, _} = emqtt:quic_connect(C),
    {ok, #{via := _SVia}, [SubQos]} = emqtt:subscribe_via(C, {new_data_stream, []}, #{}, [{Topic, [{qos, SubQos}]}]),
    {ok, #{via := SVia2}, [SubQos]} = emqtt:subscribe_via(C, {new_data_stream, []}, #{}, [{Topic2, [{qos, SubQos}]}]),

    case emqtt:publish_via(C, {new_data_stream, []}, Topic, #{},  <<1,2,3,4,5>>, [{qos, PubQos}]) of
        ok when PubQos == 0 -> ok;
        {ok, #{reason_code := 0, via := _PVia}} -> ok
    end,

    PubRecvs = recv_pub(1),
    ?assertMatch(
       [ {publish, #{ client_pid := C
                    , packet_id := PktId1
                    , payload := <<1,2,3,4,5>>
                    , qos := RecQos
                    }
         }
       ], PubRecvs),

    #{data_stream_socks := [PubVia | _]} = proplists:get_value(extra, emqtt:info(C)),

    %% Unsub topic1 via stream2 should fail with error code 17: "No subscription existed"
    {ok, #{via := SVia2}, [17]} = emqtt:unsubscribe_via(C, SVia2, Topic),

    case emqtt:publish_via(C, PubVia, Topic, #{},  <<6,7,8,9>>, [{qos, PubQos}]) of
        ok when PubQos == 0 -> ok;
        {ok, #{reason_code := 0, via := PVia }} ->
            ok
    end,

    PubRecvs2 = recv_pub(1),
    ?assertMatch(
       [ {publish, #{ client_pid := C
                    , packet_id := PktId2
                    , payload := <<6,7,8,9>>
                    , qos := RecQos
                    }
         }
       ], PubRecvs2),
    ok = emqtt:disconnect(C).

%%--------------------------------------------------------------------
%% Helper functions
%%--------------------------------------------------------------------
send_and_recv_with(Sock) ->
    {ok, {IP, _}} = emqtt_quic:sockname(Sock),
    ?assert(lists:member(tuple_size(IP), [4, 8])),
    ok = emqtt_quic:send(Sock, <<"ping">>),
    {ok, <<"pong">>} = emqtt_quic:recv(Sock, 0),
    ok = emqtt_quic:setopts(Sock, [{active, 100}]),
    {ok, Stats} = emqtt_quic:getstat(Sock, [send_cnt, recv_cnt]),
    %% connection level counters, not stream level
    [{send_cnt, _}, {recv_cnt, _}] = Stats.


certfile(Config) ->
    filename:join([test_dir(Config), "certs", "test.crt"]).

keyfile(Config) ->
    filename:join([test_dir(Config), "certs", "test.key"]).

test_dir(Config) ->
    filename:dirname(filename:dirname(proplists:get_value(data_dir, Config))).


recv_pub(Count) ->
    recv_pub(Count, []).

recv_pub(0, Acc) ->
    lists:reverse(Acc);
recv_pub(Count, Acc) ->
    receive
        {publish, _Prop} = Pub ->
            recv_pub(Count-1, [Pub | Acc])
    after 100 ->
            timeout
    end.

all_tc() ->
    code:add_patha(filename:join(code:lib_dir(emqx), "ebin/")),
    emqx_common_test_helpers:all(?MODULE).

-spec calc_qos(0|1|2, 0|1|2) -> 0|1|2.
calc_qos(PubQos, SubQos)->
    if PubQos > SubQos ->
            SubQos;
       SubQos > PubQos ->
            PubQos;
       true ->
            PubQos
    end.
-spec calc_pkt_id(0|1|2, non_neg_integer()) -> undefined | non_neg_integer().
calc_pkt_id(0, _Id)->
    undefined;
calc_pkt_id(1, Id)->
    Id;
calc_pkt_id(2, Id)->
    Id.

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
-include_lib("quicer/include/quicer.hrl").


all() ->
    [
     {group, mstream},
     {group, shutdown},
     t_quic_sock,
     t_quic_sock_fail,
     t_0_rtt,
     t_0_rtt_fail
    ].

groups() ->
    [ {mstream, [], [{group, profiles}]},

      {profiles, [], [{group, profile_low_latency},
                      {group, profile_max_throughput}
                     ]},
      {profile_low_latency, [], [{group, pub_qos0},
                                 {group, pub_qos1},
                                 {group, pub_qos2}
                                ]},
      {profile_max_throughput, [], [{group, pub_qos0},
                                    {group, pub_qos1},
                                    {group, pub_qos2}]},
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
      {sub_qos0, [{group, qos}]},
      {sub_qos1, [{group, qos}]},
      {sub_qos2, [{group, qos}]},
      {qos, [ t_multi_streams_sub,
              t_multi_streams_pub_parallel,
              t_multi_streams_sub_pub_async,
              t_multi_streams_sub_pub_sync,
              t_multi_streams_unsub,
              t_multi_streams_corr_topic,
              t_multi_streams_unsub_via_other,
              t_multi_streams_shutdown_data_stream_abortive,
              t_multi_streams_dup_sub,
              t_multi_streams_packet_boundary,
              t_multi_streams_packet_malform
             ]},

      {shutdown, [{group, graceful_shutdown},
                  {group, abort_recv_shutdown},
                  {group, abort_send_shutdown},
                  {group, abort_send_recv_shutdown}
                 ]},

      {graceful_shutdown, [{group, ctrl_stream_shutdown}]},
      {abort_recv_shutdown, [{group, ctrl_stream_shutdown}]},
      {abort_send_shutdown, [{group, ctrl_stream_shutdown}]},
      {abort_send_recv_shutdown, [{group, ctrl_stream_shutdown}]},

      {ctrl_stream_shutdown, [t_multi_streams_shutdown_ctrl_stream,
                              t_multi_streams_shutdown_ctrl_stream_then_reconnect,
                              t_multi_streams_remote_shutdown,
                              t_multi_streams_remote_shutdown_with_reconnect
                             ]
      }
    ].

init_per_suite(Config) ->
    UdpPort = 14567,
    start_emqx_quic(UdpPort),
    %dbg:tracer(process, {fun dbg:dhandler/2, group_leader()}),
    dbg:tracer(),
    dbg:p(all, c),
    dbg:tpl(emqtt_quic_stream, cx),
    %% dbg:tpl(emqx_quic_stream, cx),
    %% dbg:tpl(emqx_quic_data_stream, cx),
    %% dbg:tpl(emqtt, cx),
    [{port, UdpPort}, {pub_qos, 0}, {sub_qos, 0} | Config].

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
init_per_group(abort_send_shutdown, Config) ->
    [{stream_shutdown_flag, ?QUIC_STREAM_SHUTDOWN_FLAG_ABORT_SEND} | Config];
init_per_group(abort_recv_shutdown, Config) ->
    [{stream_shutdown_flag, ?QUIC_STREAM_SHUTDOWN_FLAG_ABORT_RECEIVE} | Config];
init_per_group(abort_send_recv_shutdown, Config) ->
    [{stream_shutdown_flag, ?QUIC_STREAM_SHUTDOWN_FLAG_ABORT} | Config];
init_per_group(graceful_shutdown, Config) ->
    [{stream_shutdown_flag, ?QUIC_STREAM_SHUTDOWN_FLAG_GRACEFUL} | Config];
init_per_group(profile_max_throughput, Config) ->
    quicer:reg_open(quic_execution_profile_type_max_throughput),
    Config;
init_per_group(profile_low_latency, Config) ->
    quicer:reg_open(quic_execution_profile_low_latency),
    Config;
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

t_multi_streams_packet_boundary(Config) ->
    PubQos = ?config(pub_qos, Config),
    SubQos = ?config(sub_qos, Config),
    RecQos = calc_qos(PubQos, SubQos),
    PktId1 = calc_pkt_id(RecQos, 1),
    PktId2 = calc_pkt_id(RecQos, 2),
    PktId3 = calc_pkt_id(RecQos, 3),
    Topic = atom_to_binary(?FUNCTION_NAME),

    %% make quicer to batch job
    quicer:reg_open(quic_execution_profile_type_max_throughput),

    {ok, C} = emqtt:start_link([{proto_ver, v5} | Config]),
    {ok, _} = emqtt:quic_connect(C),
    {ok, _, [SubQos]} = emqtt:subscribe(C, #{}, [{Topic, [{qos, SubQos}]}]),

    {ok, PubVia} =emqtt:start_data_stream(C, []),
    ok = emqtt:publish_async(C, PubVia, Topic,  <<"stream data 1">>, [{qos, PubQos}],
                             undefined),
    ok = emqtt:publish_async(C, PubVia, Topic,  <<"stream data 2">>, [{qos, PubQos}],
                             undefined),
    LargePart3 = binary:copy(<<"stream data3">>, 2000),
    ok = emqtt:publish_async(C, PubVia, Topic,  LargePart3, [{qos, PubQos}],
                             undefined),
    PubRecvs = recv_pub(3),
    ?assertMatch(
       [ {publish, #{ client_pid := C
                    , packet_id := PktId1
                    , payload := <<"stream data 1">>
                    , qos := RecQos
                    , topic := Topic
                    }
         }
       , {publish, #{ client_pid := C
                    , packet_id := PktId2
                    , payload := <<"stream data 2">>
                    , qos := RecQos
                    , topic := Topic
                    }
         }
       , {publish, #{ client_pid := C
                    , packet_id := PktId3
                    , payload := LargePart3
                    , qos := RecQos
                    , topic := Topic
                    }
         }
       ], PubRecvs),
    ok = emqtt:disconnect(C).

%% @doc test that one malformed stream will not close the entire connection
t_multi_streams_packet_malform(Config) ->
    PubQos = ?config(pub_qos, Config),
    SubQos = ?config(sub_qos, Config),
    RecQos = calc_qos(PubQos, SubQos),
    PktId1 = calc_pkt_id(RecQos, 1),
    PktId2 = calc_pkt_id(RecQos, 2),
    PktId3 = calc_pkt_id(RecQos, 3),
    Topic = atom_to_binary(?FUNCTION_NAME),

    %% make quicer to batch job
    quicer:reg_open(quic_execution_profile_type_max_throughput),

    {ok, C} = emqtt:start_link([{proto_ver, v5} | Config]),
    {ok, _} = emqtt:quic_connect(C),
    {ok, _, [SubQos]} = emqtt:subscribe(C, #{}, [{Topic, [{qos, SubQos}]}]),

    {ok, PubVia} = emqtt:start_data_stream(C, []),
    ok = emqtt:publish_async(C, PubVia, Topic,  <<"stream data 1">>, [{qos, PubQos}],
                             undefined),

    {ok, {quic, _Conn, MalformStream}} = emqtt:start_data_stream(C, []),
    {ok, _} = quicer:send(MalformStream, <<0,0,0,0,0,0,0,0,0,0>>),

    ok = emqtt:publish_async(C, PubVia, Topic,  <<"stream data 2">>, [{qos, PubQos}],
                             undefined),
    LargePart3 = binary:copy(<<"stream data3">>, 2000),
    ok = emqtt:publish_async(C, PubVia, Topic,  LargePart3, [{qos, PubQos}],
                             undefined),
    PubRecvs = recv_pub(3),
    ?assertMatch(
       [ {publish, #{ client_pid := C
                    , packet_id := PktId1
                    , payload := <<"stream data 1">>
                    , qos := RecQos
                    , topic := Topic
                    }
         }
       , {publish, #{ client_pid := C
                    , packet_id := PktId2
                    , payload := <<"stream data 2">>
                    , qos := RecQos
                    , topic := Topic
                    }
         }
       , {publish, #{ client_pid := C
                    , packet_id := PktId3
                    , payload := LargePart3
                    , qos := RecQos
                    , topic := Topic
                    }
         }
       ], PubRecvs),

    case quicer:send(MalformStream, <<0,0,0,0,0,0,0,0,0,0>>) of
        {ok, 10} -> ok;
        {error, cancelled} -> ok;
        {error, stm_send_error, aborted} -> ok
    end,

    timer:sleep(200),
    ?assert(is_list(emqtt:info(C))),

    {error, stm_send_error, aborted} = quicer:send(MalformStream, <<0,0,0,0,0,0,0,0,0,0>>),
    timer:sleep(200),
    ?assert(is_list(emqtt:info(C))),

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
       ], lists:sort(PubRecvs)),
    ok = emqtt:disconnect(C).

t_multi_streams_dup_sub(Config) ->
    PubQos = ?config(pub_qos, Config),
    SubQos = ?config(sub_qos, Config),
    RecQos = calc_qos(PubQos, SubQos),
    PktId1 = calc_pkt_id(RecQos, 1),
    Topic = atom_to_binary(?FUNCTION_NAME),
    {ok, C} = emqtt:start_link([{proto_ver, v5} | Config]),
    {ok, _} = emqtt:quic_connect(C),
    {ok, #{via := SVia1}, [SubQos]} = emqtt:subscribe_via(C, {new_data_stream, []}, #{}, [{Topic, [{qos, SubQos}]}]),
    {ok, #{via := SVia2}, [SubQos]} = emqtt:subscribe_via(C, {new_data_stream, []}, #{}, [{Topic, [{qos, SubQos}]}]),

    #{data_stream_socks := [{quic, _Conn, SubStream} | _]} = proplists:get_value(extra, emqtt:info(C)),
    ?assertEqual(2, length(emqx_broker:subscribers(Topic))),

    case emqtt:publish_via(C, {new_data_stream, []}, Topic, #{},  <<"stream data 3">>, [{qos, PubQos}]) of
        ok when PubQos == 0 ->
            ok;
        {ok, #{reason_code := 0, via := _Via1}} -> ok
    end,
    PubRecvs = recv_pub(2),
    ?assertMatch(
       [ {publish, #{ client_pid := C
                    , packet_id := PktId1
                    , payload := <<"stream data 3">>
                    , qos := RecQos
                    }
         }
       , {publish, #{ client_pid := C
                    , packet_id := PktId1
                    , payload := <<"stream data 3">>
                    , qos := RecQos
                    }
         }
       ], lists:sort(PubRecvs)),

    RecvVias = [ Via || {publish, #{via := Via }} <- PubRecvs],

    ct:pal("~p, ~p, ~n recv from: ~p~n", [SVia1, SVia2, PubRecvs]),
    %% Can recv in any order
    ?assert([SVia1, SVia2] == RecvVias orelse [SVia2, SVia1] == RecvVias),

    %% Shutdown one stream
    quicer:async_shutdown_stream(SubStream, ?QUIC_STREAM_SHUTDOWN_FLAG_GRACEFUL, 500),
    timer:sleep(100),

    ?assertEqual(1, length(emqx_broker:subscribers(Topic))),

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
        {ok, #{reason_code := 0, via := _PVia2 }} ->
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

t_multi_streams_shutdown_data_stream_abortive(Config) ->
    PubQos = ?config(pub_qos, Config),
    SubQos = ?config(sub_qos, Config),
    RecQos = calc_qos(PubQos, SubQos),
    PktId1 = calc_pkt_id(RecQos, 1),

    Topic = atom_to_binary(?FUNCTION_NAME),
    Topic2 = << Topic/binary, "two">>,
    {ok, C} = emqtt:start_link([{proto_ver, v5} | Config]),
    {ok, _} = emqtt:quic_connect(C),
    {ok, #{via := SVia}, [SubQos]} = emqtt:subscribe_via(C, {new_data_stream, []}, #{}, [{Topic, [{qos, SubQos}]}]),
    {ok, #{via := SVia2}, [SubQos]} = emqtt:subscribe_via(C, {new_data_stream, []}, #{}, [{Topic2, [{qos, SubQos}]}]),

    ?assert(SVia =/= SVia2),

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
    {quic, _Conn, DataStream} = PubVia,
    quicer:shutdown_stream(DataStream, ?QUIC_STREAM_SHUTDOWN_FLAG_ABORT_SEND, 500, 100),
    timer:sleep(500),
    %% Still alive
    ?assert(is_list(emqtt:info(C))).

t_multi_streams_shutdown_ctrl_stream(Config) ->
    PubQos = ?config(pub_qos, Config),
    SubQos = ?config(sub_qos, Config),
    RecQos = calc_qos(PubQos, SubQos),
    PktId1 = calc_pkt_id(RecQos, 1),

    Topic = atom_to_binary(?FUNCTION_NAME),
    Topic2 = << Topic/binary, "two">>,
    {ok, C} = emqtt:start_link([{proto_ver, v5} | Config]),
    unlink(C),
    {ok, _} = emqtt:quic_connect(C),
    {ok, #{via := _SVia}, [SubQos]} = emqtt:subscribe_via(C, {new_data_stream, []}, #{}, [{Topic, [{qos, SubQos}]}]),
    {ok, #{via := _SVia2}, [SubQos]} = emqtt:subscribe_via(C, {new_data_stream, []}, #{}, [{Topic2, [{qos, SubQos}]}]),

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

    {quic, _Conn, Ctrlstream} = proplists:get_value(socket, emqtt:info(C)),
    quicer:shutdown_stream(Ctrlstream, ?config(stream_shutdown_flag, Config), 500, 1000),
    timer:sleep(500),
    %% Client should be closed
    ?assertMatch({'EXIT', {noproc, {gen_statem, call, [_,info,infinity] } }}, catch emqtt:info(C)).

t_multi_streams_shutdown_ctrl_stream_then_reconnect(Config) ->
    erlang:process_flag(trap_exit, true),
    PubQos = ?config(pub_qos, Config),
    SubQos = ?config(sub_qos, Config),
    RecQos = calc_qos(PubQos, SubQos),
    PktId1 = calc_pkt_id(RecQos, 1),

    Topic = atom_to_binary(?FUNCTION_NAME),
    Topic2 = << Topic/binary, "two">>,
    {ok, C} = emqtt:start_link([{proto_ver, v5}, {reconnect, true},
                                {connect_timeout, 5} %% speedup test
                               | Config]),
    {ok, _} = emqtt:quic_connect(C),
    {ok, #{via := SVia}, [SubQos]} = emqtt:subscribe_via(C, {new_data_stream, []}, #{}, [{Topic, [{qos, SubQos}]}]),
    {ok, #{via := SVia2}, [SubQos]} = emqtt:subscribe_via(C, {new_data_stream, []}, #{}, [{Topic2, [{qos, SubQos}]}]),

    ?assert(SVia2 =/= SVia),

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

    {quic, _Conn, Ctrlstream} = proplists:get_value(socket, emqtt:info(C)),
    quicer:shutdown_stream(Ctrlstream, ?config(stream_shutdown_flag, Config), 500, 100),
    timer:sleep(200),
    %% Client should be closed
    ?assert(is_list(emqtt:info(C))).


t_multi_streams_remote_shutdown(Config) ->
    erlang:process_flag(trap_exit, true),
    PubQos = ?config(pub_qos, Config),
    SubQos = ?config(sub_qos, Config),
    RecQos = calc_qos(PubQos, SubQos),
    PktId1 = calc_pkt_id(RecQos, 1),

    Topic = atom_to_binary(?FUNCTION_NAME),
    Topic2 = << Topic/binary, "two">>,
    {ok, C} = emqtt:start_link([{proto_ver, v5}, {reconnect, false},
                                {connect_timeout, 5} %% speedup test
                               | Config]),
    {ok, _} = emqtt:quic_connect(C),
    {ok, #{via := SVia}, [SubQos]} = emqtt:subscribe_via(C, {new_data_stream, []}, #{}, [{Topic, [{qos, SubQos}]}]),
    {ok, #{via := SVia2}, [SubQos]} = emqtt:subscribe_via(C, {new_data_stream, []}, #{}, [{Topic2, [{qos, SubQos}]}]),

    ?assert(SVia2 =/= SVia),

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

    {quic, _Conn, _Ctrlstream} = proplists:get_value(socket, emqtt:info(C)),

    ok = emqtt_test_lib:stop_emqx(),

    timer:sleep(200),
    start_emqx_quic(?config(port, Config)),

    %% Client should be closed
    ?assertMatch({'EXIT', {noproc, {gen_statem, call, [_,info,infinity] } }}, catch emqtt:info(C)).


t_multi_streams_remote_shutdown_with_reconnect(Config) ->
    erlang:process_flag(trap_exit, true),
    PubQos = ?config(pub_qos, Config),
    SubQos = ?config(sub_qos, Config),
    RecQos = calc_qos(PubQos, SubQos),
    PktId1 = calc_pkt_id(RecQos, 1),

    Topic = atom_to_binary(?FUNCTION_NAME),
    Topic2 = << Topic/binary, "two">>,
    {ok, C} = emqtt:start_link([{proto_ver, v5}, {reconnect, true},
                                {connect_timeout, 5} %% speedup test
                               | Config]),
    {ok, _} = emqtt:quic_connect(C),
    {ok, #{via := SVia}, [SubQos]} = emqtt:subscribe_via(C, {new_data_stream, []}, #{}, [{Topic, [{qos, SubQos}]}]),
    {ok, #{via := SVia2}, [SubQos]} = emqtt:subscribe_via(C, {new_data_stream, []}, #{}, [{Topic2, [{qos, SubQos}]}]),

    ?assert(SVia2 =/= SVia),

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

    {quic, _Conn, _Ctrlstream} = proplists:get_value(socket, emqtt:info(C)),

    ok = emqtt_test_lib:stop_emqx(),

    timer:sleep(200),

    start_emqx_quic(?config(port, Config)),
    %% Client should be closed
    ?assert(is_list(emqtt:info(C))).

%%--------------------------------------------------------------------
%% Helper functions
%%--------------------------------------------------------------------
send_and_recv_with(Sock) ->
    {ok, {IP, _}} = emqtt_quic:sockname(Sock),
    ?assert(lists:member(tuple_size(IP), [4, 8])),
    ok = emqtt_quic:send(Sock, <<"ping">>),
    emqtt_quic:setopts(Sock, [{active, false}]),
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

-spec start_emqx_quic(inet:port_number()) -> ok.
start_emqx_quic(UdpPort) ->
    emqtt_test_lib:start_emqx(),
    application:ensure_all_started(quicer),
    ok = emqx_common_test_helpers:ensure_quic_listener(mqtt, UdpPort).

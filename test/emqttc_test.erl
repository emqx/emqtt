
-module(emqttc_test).

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

qos_opt_test() ->
    ?assertEqual(0, emqttc:qos_opt(0)),
    ?assertEqual(2, emqttc:qos_opt(qos2)),
    ?assertEqual(0, emqttc:qos_opt([])),
    ?assertEqual(1, emqttc:qos_opt([qos1])),
    ?assertEqual(2, emqttc:qos_opt([{qos, 2}])),
    ?assertEqual(1, emqttc:qos_opt([qos1, {qos, 2}, {retain, 0}])),
    ?assertEqual(0, emqttc:qos_opt([{retain, 0}])).

subscribe_test() ->
    {ok, C} = start_client(),
    emqttc:subscribe(C, <<"Topic">>, 1),
    emqttc:subscribe(C, <<"Topic">>, 2).

publish_test() ->
    {ok, C} = start_client(),
    emqttc:subscribe(C, <<"Topic">>, 2),
    emqttc:publish(C, <<"Topic">>, <<"Payload(Qos0)">>),
    emqttc:publish(C, <<"Topic">>, <<"Payload(Qos1)">>, [{qos, 1}]),
    emqttc:publish(C, <<"Topic">>, <<"Payload(Qos2)">>, [{qos, 2}]).

unsubscribe_test() ->
    {ok, C} = start_client(),
    emqttc:subscribe(C, <<"Topic">>, 1),
    emqttc:unsubscribe(C, <<"Topic">>).

ping_test() ->
    {ok, C} = start_client([{client_id, <<"pingTestClient">>}]),
    timer:sleep(1000),
    pong = emqttc:ping(C).

disconnect_test() ->
    {ok, C} = start_client(),
    timer:sleep(1000),
    emqttc:disconnect(C).

subscribe_down_test() ->
    {ok, C} = start_client(),
    _SubPid = spawn(fun() ->
                        emqttc:subscribe(C, <<"Topic">>),
                        receive
                            {publish, _Topic, _Payload} -> ok
                        after
                            1000 -> exit(timeout)
                        end
                    end),
    timer:sleep(500),
    emqttc:publish(C, <<"Topic">>, <<"Payload">>),
    timer:sleep(500).

clean_sess_test() ->
    {ok, C} = start_client([{client_id, <<"testClient">>}, {clean_sess, false}]),
    emqttc:subscribe(C, <<"Topic">>, 1),
    emqttc:publish(C, <<"Topic">>, <<"Playload">>, [{qos, 1}]),
    emqttc:disconnect(C),
    timer:sleep(100),
    {ok, C2} = start_client([{client_id, <<"testClient">>}, {clean_sess, false}]),
    emqttc:subscribe(C2, <<"Topic1">>, 1),
    emqttc:publish(C2, <<"Topic1">>, <<"Playload">>, [{qos, 1}]),
    emqttc:disconnect(C2).

start_client() ->
    emqttc:start_link([{logger, {error_logger, info}}]).

start_client(Opts) ->
    emqttc:start_link([{logger, {error_logger, info}}|Opts]).

-endif.

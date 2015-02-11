-module(emqttc_test).

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

subscribe_test() ->
    {ok, C} = emqttc:start_link([{logger, {otp, info}}]),
    emqttc:subscribe(C, <<"Topic">>, 1),
    emqttc:subscribe(C, <<"Topic">>, 2).

publish_test() ->
    {ok, C} = emqttc:start_link([{logger, {otp, info}}]),
    emqttc:subscribe(C, <<"Topic">>, 2),
    emqttc:publish(C, <<"Topic">>, <<"Payload(Qos0)">>),
    emqttc:publish(C, <<"Topic">>, <<"Payload(Qos1)">>, [{qos, 1}]),
    emqttc:publish(C, <<"Topic">>, <<"Payload(Qos2)">>, [{qos, 2}]).

-endif.

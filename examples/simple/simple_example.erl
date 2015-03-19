-module(simple_example).

-export([start/0]).

start() ->
    {ok, C} = emqttc:start_link([{host, "localhost"}, {client_id, <<"simpleClient">>}]),
    emqttc:subscribe(C, <<"TopicA">>, 0),
    emqttc:publish(C, <<"TopicA">>, <<"hello">>),
    receive
        {publish, Topic, Payload} ->
            io:format("Message Received from ~s: ~p~n", [Topic, Payload])
    after
        1000 ->
            io:format("Error: receive timeout!~n")
    end,
    emqttc:disconnect(C).
    

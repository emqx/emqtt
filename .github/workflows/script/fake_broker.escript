#!/usr/bin/env escript

%% A fake MQTT broker for the package smoke test on macOS, where the CI job
%% cannot start an EMQX container.
%%
%%   fake_broker.escript <port> <ready-file>
%%
%% It accepts one client on the loopback address, answers its CONNECT with a
%% successful MQTT 5 CONNACK, and reads until the client closes the
%% connection. It creates <ready-file> once it listens, and exits with 0 only
%% when the client published the payload "hello world".

main([PortStr, ReadyFile]) ->
    {ok, LSock} = gen_tcp:listen(list_to_integer(PortStr),
                                 [binary, {ip, {127, 0, 0, 1}},
                                  {reuseaddr, true}, {active, false}]),
    ok = file:write_file(ReadyFile, <<>>),
    {ok, Sock} = gen_tcp:accept(LSock, 60000),
    %% CONNECT: packet type 1
    {ok, <<1:4, _:4, _/binary>>} = gen_tcp:recv(Sock, 0, 10000),
    %% CONNACK: no session present, reason code 0, no properties
    ok = gen_tcp:send(Sock, <<2:4, 0:4, 3, 0, 0, 0>>),
    Received = recv_all(Sock, <<>>),
    case binary:match(Received, <<"hello world">>) of
        nomatch ->
            io:format(standard_error, "fake broker: no PUBLISH received~n", []),
            halt(1);
        _ ->
            io:format("fake broker: PUBLISH received~n"),
            halt(0)
    end.

recv_all(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 10000) of
        {ok, Bin} -> recv_all(Sock, <<Acc/binary, Bin/binary>>);
        {error, _} -> Acc
    end.

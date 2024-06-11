%%-------------------------------------------------------------------------
%% Copyright (c) 2024 EMQ Technologies Co., Ltd. All Rights Reserved.
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
%%-------------------------------------------------------------------------

-module(user_default).

-export([init/0,
         help/0
        ]).

-export([set_qos/1]).

-export([con/5,
         call/2,
         call/3,
         call/4,
         call/5,
         call/6,
         call/7,
         wake/1
        ]).

-define(ETS, funr).
-define(NAME, funr).
-define(RED, "\e[31m").
-define(GREEN, "\e[32m").
-define(YELLOW, "\e[33m").
-define(RESET, "\e[39m").


call(Vin0, Func0) ->
    do_call(Vin0, Func0, []).

call(Vin0, Func0, Arg1) ->
    do_call(Vin0, Func0, [Arg1]).

call(Vin0, Func0, Arg1, Arg2) ->
    do_call(Vin0, Func0, [Arg1, Arg2]).

call(Vin0, Func0, Arg1, Arg2, Arg3) ->
    do_call(Vin0, Func0, [Arg1, Arg2, Arg3]).

call(Vin0, Func0, Arg1, Arg2, Arg3, Arg4) ->
    do_call(Vin0, Func0, [Arg1, Arg2, Arg3, Arg4]).

call(Vin0, Func0, Arg1, Arg2, Arg3, Arg4, Arg5) ->
    do_call(Vin0, Func0, [Arg1, Arg2, Arg3, Arg4, Arg5]).

do_call(Vin0, Func0, Args) ->
    Vin = bin(Vin0),
    Func = bin(Func0),
    Topic = bin(["funr/call/", Vin, "/", Func]),
    Payload = bin(io_lib:format("~0p", [Args])),
    Opts = [{qos, qos()}],
    case emqtt:publish(?NAME, Topic, Payload, Opts) of
        {error, Reason} ->
            io:format("Failed to send PUBLISH function call reason: ~p~n", [Reason]);
        _ ->
            log_g("Sent PUBLISH to Topic='~s' Payload='~s'~n", [Topic, Payload])
    end.

bin(A) when is_atom(A) ->
    atom_to_binary(A);
bin(L) when is_list(L) ->
    iolist_to_binary(L);
bin(B) when is_binary(B) ->
    B.

init() ->
    spawn_link(fun do_init/0).

help() ->
    log_y("  > help().                     :: Print this help info~n"
          "  > con(H, P, U, Pwd, Cid).     :: Connect EMQX if the -h arg is missing from start.~n"
          "  > set_qos(0|1|2).             :: Set QoS for the publishing messages~n"
          "  > wake(Vin).                  :: Emulate a wake-up signal. Signal is published to 'funr/wake/Vin'~n"
          "                                   EMQX should trigger an HTTP POST towards the wakeup-service.~n"
          "  > call(Vin, Func, Arg1, ...). :: Emulate a function call from funr to device at topic 'funr/call/Vin/FunctionName'~n"
          "                                   Expecting the device to subscribe topic 'funr/call/${client_attrs.vin}'~n"
          , []).

set_qos(QoS) ->
    ets:insert(?ETS, {qos, QoS}).

do_init() ->
    Ets = ets:new(?ETS, [named_table, public]),
    Owner = whereis(init),
    ets:give_away(Ets, Owner, Ets),
    Args = init:get_arguments(),
    Host = arg(h, Args, undefined),
    case Host of
        undefined ->
            help();
        _ ->
            do_init(Args)
    end.

do_init(Args) ->
    Owner = whereis(init),
    Host = arg(h, Args, undefined),
    Port = int(arg(p, Args, 1883)),
    Username = arg(u, Args, <<>>),
    Password = arg('P', Args, <<>>),
    ClientId = arg('C', Args, <<"funr">>),
    Opts = #{name => ?NAME,
             host => Host,
             port => Port,
             username => Username,
             password => Password,
             clientid => ClientId,
             owner => Owner
            },
    ets:insert(?ETS, {opts, Opts}),
    {ok, Pid} = emqtt:start_link(Opts),
    %% Small delay to ensure eshell is booted before print
    timer:sleep(100),
    ConnStr = io_lib:format("~s:~p with username='~s' password='~s' clientid='~s'",
                            [Host, Port, Username, Password, ClientId]),
    unlink(Pid),
    case emqtt:connect(Pid) of
        {ok, _} ->
            log_g("~nConnected to ~s~n~n", [ConnStr]);
        {error, Reason} ->
            log_r("~nFailed to connect ~s~n", [ConnStr]),
            log_r("Reason: ~p~n", [Reason]),
            halt(1)
    end,
    help(),
    ok.

arg(Key, InitArgs, Default) ->
    case proplists:get_value(Key, InitArgs) of
        [Value] ->
            Value;
        undefined ->
            Default;
        Value ->
            Value
    end.

int(I) when is_list(I) ->
    list_to_integer(I);
int(I) when is_integer(I) ->
    I.

log_r(Fmt, Args) ->
    io:format(?RED ++ Fmt ++ ?RESET, Args).

log_g(Fmt, Args) ->
    io:format(?GREEN ++ Fmt ++ ?RESET, Args).

log_y(Fmt, Args) ->
    io:format(?YELLOW ++ Fmt ++ ?RESET, Args).

wake(Vin) ->
    Opts = [{qos, qos()}],
    Topic = bin(["funr/wake/", bin(Vin)]),
    Payload = <<"Wake Up!!!">>,
    case emqtt:publish(?NAME, Topic, Payload, Opts) of
        {error, Reason} ->
            io:format("Failed to send PUBLISH wake-up signal reason: ~p~n", [Reason]);
        _ ->
            log_g("Sent PUBLISH to Topic='~s' Payload='~s'~n", [Topic, Payload])
    end.

qos() ->
    case ets:lookup(?ETS, qos) of
        [{qos, QoS}] ->
            QoS;
        [] ->
            0
    end.

con(H, P, U, Pwd, ClientId) ->
    do_init([{h, bin(H)},
             {p, P},
             {u, bin(U)},
             {'P', bin(Pwd)},
             {'C', bin(ClientId)}
            ]).
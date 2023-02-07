%%-------------------------------------------------------------------------
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
%%-------------------------------------------------------------------------

-module(emqtt_cli).

-include("emqtt.hrl").

-export([ main/1
        ]).

-import(proplists, [get_value/2]).

-define(CMD_NAME, "emqtt").

-define(HELP_OPT,
        [{help, undefined, "help", boolean,
          "Help information"}
        ]).

-define(CONN_SHORT_OPTS,
        [{host, $h, "host", {string, "localhost"},
          "mqtt server hostname or IP address"},
         {port, $p, "port", integer,
          "mqtt server port number"},
         {iface, $I, "iface", string,
          "specify the network interface or ip address to use"},
         {protocol_version, $V, "protocol-version", {atom, 'v5'},
          "mqtt protocol version: v3.1 | v3.1.1 | v5"},
         {username, $u, "username", string,
          "username for connecting to server"},
         {password, $P, "password", string,
          "password for connecting to server"},
         {clientid, $C, "clientid", string,
          "client identifier"},
         {keepalive, $k, "keepalive", {integer, 300},
          "keep alive in seconds"}
        ]).

-define(CONN_LONG_OPTS,
        [{will_topic, undefined, "will-topic", string,
          "Topic for will message"},
         {will_payload, undefined, "will-payload", string,
          "Payload in will message"},
         {will_qos, undefined, "will-qos", {integer, 0},
          "QoS for will message"},
         {will_retain, undefined, "will-retain", {boolean, false},
          "Retain in will message"},
         {enable_websocket, undefined, "enable-websocket", {boolean, false},
          "Enable websocket transport or not"},
         {enable_quic, undefined, "enable-quic", {boolean, false},
          "Enable quic transport or not"},
         {enable_ssl, undefined, "enable-ssl", {boolean, false},
          "Enable ssl/tls or not"},
         {tls_version, undefined, "tls-version", {atom, 'tlsv1.2'},
          "TLS protocol version used when the client connects to the broker"},
         {cafile, undefined, "CAfile", string,
          "Path to a file containing pem-encoded ca certificates"},
         {cert, undefined, "cert", string,
          "Path to a file containing the user certificate on pem format"},
         {key, undefined, "key", string,
          "Path to the file containing the user's private pem-encoded key"},
         {sni, undefined, "sni", string,
          "Applicable when '--enable_ssl' is in use. "
          "Use '--sni true' to apply the host name from '-h|--host' option "
          "as SNI, therwise use the host name to which the server's SSL "
          "certificate is issued"},
         {verify, undefined, "verify", {boolean, false},
          "TLS verify option, default: false "
         }
        ]).

-define(PUB_OPTS, ?CONN_SHORT_OPTS ++
        [{topic, $t, "topic", string,
          "mqtt topic on which to publish the message"},
         {qos, $q, "qos", {integer, 0},
          "qos level of assurance for delivery of an application message"},
         {retain, $r, "retain", {boolean, false},
          "retain message or not"}
        ] ++ ?HELP_OPT ++ ?CONN_LONG_OPTS ++
        [{payload, undefined, "payload", string,
          "application message that is being published"},
         {file, undefined, "file", string, "file content to publish"},
         {repeat, undefined, "repeat", {integer, 1},
          "the number of times the message will be repeatedly published"},
         {repeat_delay, undefined, "repeat-delay", {integer, 0},
          "the number of seconds to wait after the previous message was delivered before publishing the next"}
        ]).

-define(SUB_OPTS, ?CONN_SHORT_OPTS ++
        [{topic, $t, "topic", string,
          "mqtt topic to subscribe to"},
         {qos, $q, "qos", {integer, 0},
          "maximum qos level at which the server can send application messages to the client"}
        ] ++ ?HELP_OPT ++ ?CONN_LONG_OPTS ++
        [{retain_as_publish, undefined, "retain-as-publish", {boolean, false},
          "retain as publih option in subscription options"},
         {retain_handling, undefined, "retain-handling", {integer, 0},
          "retain handling option in subscription options"},
         {print, undefined, "print", string,
          "'size' to print payload size, 'as-string' to print payload as string"}
        ]).

main(["sub" | Argv]) ->
    {ok, {Opts, _Args}} = getopt:parse(?SUB_OPTS, Argv),
    ok = maybe_help(sub, Opts),
    ok = check_required_args(sub, [topic], Opts),
    main(sub, Opts);

main(["pub" | Argv]) ->
    {ok, {Opts, _Args}} = getopt:parse(?PUB_OPTS, Argv),
    ok = maybe_help(pub, Opts),
    ok = check_required_args(pub, [topic], Opts),
    Payload = get_value(payload, Opts),
    File = get_value(file, Opts),
    case {Payload, File} of
        {undefined, undefined} ->
            io:format("Error: missing --payload or --file~n"),
            halt(1);
        _ ->
            ok
    end,
    main(pub, Opts);

main(_Argv) ->
    io:format("Usage: ~s pub | sub [--help]~n", [?CMD_NAME]).

main(PubSub, Opts0) ->
    application:ensure_all_started(quicer),
    application:ensure_all_started(emqtt),
    Print = proplists:get_value(print, Opts0),
    Opts = proplists:delete(print, Opts0),
    NOpts = enrich_opts(parse_cmd_opts(Opts)),
    {ok, Client} = emqtt:start_link(NOpts),
    ConnRet = case {proplists:get_bool(enable_websocket, NOpts),
                    proplists:get_bool(enable_quic, NOpts)} of
                  {false, false} -> emqtt:connect(Client);
                  {true, false}  -> emqtt:ws_connect(Client);
                  {false, true}  -> emqtt:quic_connect(Client)
              end,
    case ConnRet of
        {ok, Properties} ->
            io:format("Client ~s sent CONNECT~n", [get_value(clientid, NOpts)]),
            case PubSub of
                pub ->
                    publish(Client, NOpts, proplists:get_value(repeat, Opts)),
                    disconnect(Client, NOpts);
                sub ->
                    subscribe(Client, NOpts),
                    KeepAlive = maps:get('Server-Keep-Alive', Properties, get_value(keepalive, NOpts)) * 1000,
                    timer:send_interval(KeepAlive, ping),
                    receive_loop(Client, Print)
            end;
        {error, Reason} ->
            io:format("Client ~s failed to sent CONNECT due to ~p~n", [get_value(clientid, NOpts), Reason])
    end.

publish(Client, Opts, 1) ->
    do_publish(Client, Opts);
publish(Client, Opts, Repeat) ->
    do_publish(Client, Opts),
    case proplists:get_value(repeat_delay, Opts) of
        0 -> ok;
        RepeatDelay -> timer:sleep(RepeatDelay * 1000)
    end,
    publish(Client, Opts, Repeat - 1).

do_publish(Client, Opts) ->
    case get_value(payload, Opts) of
        undefined ->
            File = get_value(file, Opts),
            case file:read_file(File) of
                {ok, Bin} -> do_publish(Client, Opts, Bin);
                {error, Reason} ->
                    io:format("Error: failed_to_read ~s:~nreason=~p", [File, Reason]),
                    halt(1)
            end;
        Bin ->
            do_publish(Client, Opts, Bin)
    end.

do_publish(Client, Opts, Payload) ->
    case emqtt:publish(Client, get_value(topic, Opts), Payload, Opts) of
        {error, Reason} ->
            io:format("Client ~s failed to sent PUBLISH due to ~p~n", [get_value(clientid, Opts), Reason]);
        _ ->
            io:format("Client ~s sent PUBLISH (Q~p, R~p, D0, Topic=~s, Payload=...(~p bytes))~n",
                      [get_value(clientid, Opts),
                       get_value(qos, Opts),
                       i(get_value(retain, Opts)),
                       get_value(topic, Opts),
                       iolist_size(Payload)])
    end.

subscribe(Client, Opts) ->
    case emqtt:subscribe(Client, get_value(topic, Opts), Opts) of
        {ok, _, [ReasonCode]} when 0 =< ReasonCode andalso ReasonCode =< 2 ->
            io:format("Client ~s subscribed to ~s~n", [get_value(clientid, Opts), get_value(topic, Opts)]);
        {ok, _, [ReasonCode]} ->
            io:format("Client ~s failed to subscribe to ~s due to ~s~n", [get_value(clientid, Opts),
                                                                          get_value(topic, Opts),
                                                                          emqtt:reason_code_name(ReasonCode)]);
        {error, Reason} ->
            io:format("Client ~s failed to send SUBSCRIBE due to ~p~n", [get_value(clientid, Opts), Reason])
    end.

disconnect(Client, Opts) ->
    case emqtt:disconnect(Client) of
        ok ->
            io:format("Client ~s sent DISCONNECT~n", [get_value(clientid, Opts)]);
        {error, Reason} ->
            io:format("Client ~s failed to send DISCONNECT due to ~p~n", [get_value(clientid, Opts), Reason])
    end.

maybe_help(PubSub, Opts) ->
    case proplists:get_value(help, Opts) of
        true ->
            usage(PubSub),
            halt(0);
        _ -> ok
    end.

usage(PubSub) ->
    Opts = case PubSub of
               pub -> ?PUB_OPTS;
               sub -> ?SUB_OPTS
           end,
    getopt:usage(Opts, ?CMD_NAME ++ " " ++ atom_to_list(PubSub)).

check_required_args(PubSub, Keys, Opts) ->
    lists:foreach(fun(Key) ->
        case lists:keyfind(Key, 1, Opts) of
            false ->
                io:format("Error: '~s' required~n", [Key]),
                usage(PubSub),
                halt(1);
            _ -> ok
        end
    end, Keys).

parse_cmd_opts(Opts) ->
    parse_cmd_opts(Opts, []).

parse_cmd_opts([], Acc) ->
    Acc;
parse_cmd_opts([{host, Host} | Opts], Acc) ->
    parse_cmd_opts(Opts, [{host, Host} | Acc]);
parse_cmd_opts([{port, Port} | Opts], Acc) ->
    parse_cmd_opts(Opts, [{port, Port} | Acc]);
parse_cmd_opts([{iface, Interface} | Opts], Acc) ->
    NAcc = case inet:parse_address(Interface) of
               {ok, IPAddress0} ->
                   maybe_append(tcp_opts, {ifaddr, IPAddress0}, Acc);
               _ ->
                   case inet:getifaddrs() of
                       {ok, IfAddrs} -> 
                            case lists:filter(fun({addr, {_, _, _, _}}) -> true;
                                                 (_) -> false
                                              end, proplists:get_value(Interface, IfAddrs, [])) of
                                [{addr, IPAddress0}] -> maybe_append(tcp_opts, {ifaddr, IPAddress0}, Acc);
                                _ -> Acc
                            end;
                        _ -> Acc
                    end
           end,
    parse_cmd_opts(Opts, NAcc);
parse_cmd_opts([{protocol_version, 'v3.1'} | Opts], Acc) ->
    parse_cmd_opts(Opts, [{proto_ver, v3} | Acc]);
parse_cmd_opts([{protocol_version, 'v3.1.1'} | Opts], Acc) ->
    parse_cmd_opts(Opts, [{proto_ver, v4} | Acc]);
parse_cmd_opts([{protocol_version, 'v5'} | Opts], Acc) ->
    parse_cmd_opts(Opts, [{proto_ver, v5} | Acc]);
parse_cmd_opts([{username, Username} | Opts], Acc) ->
    parse_cmd_opts(Opts, [{username, list_to_binary(Username)} | Acc]);
parse_cmd_opts([{password, Password} | Opts], Acc) ->
    parse_cmd_opts(Opts, [{password, list_to_binary(Password)} | Acc]);
parse_cmd_opts([{clientid, Clientid} | Opts], Acc) ->
    parse_cmd_opts(Opts, [{clientid, list_to_binary(Clientid)} | Acc]);
parse_cmd_opts([{will_topic, Topic} | Opts], Acc) ->
    parse_cmd_opts(Opts, [{will_topic, list_to_binary(Topic)} | Acc]);
parse_cmd_opts([{will_payload, Payload} | Opts], Acc) ->
    parse_cmd_opts(Opts, [{will_payload, list_to_binary(Payload)} | Acc]);
parse_cmd_opts([{will_qos, Qos} | Opts], Acc) ->
    parse_cmd_opts(Opts, [{will_qos, Qos} | Acc]);
parse_cmd_opts([{will_retain, Retain} | Opts], Acc) ->
    parse_cmd_opts(Opts, [{will_retain, Retain} | Acc]);
parse_cmd_opts([{keepalive, I} | Opts], Acc) ->
    parse_cmd_opts(Opts, [{keepalive, I} | Acc]);
parse_cmd_opts([{enable_websocket, Enable} | Opts], Acc) ->
    parse_cmd_opts(Opts, [{enable_websocket, Enable} | Acc]);
parse_cmd_opts([{enable_quic, Enable} | Opts], Acc) ->
    parse_cmd_opts(Opts, [{enable_quic, Enable} | Acc]);
parse_cmd_opts([{enable_ssl, Enable} | Opts], Acc) ->
    parse_cmd_opts(Opts, [{ssl, Enable} | Acc]);
parse_cmd_opts([{tls_version, Version} | Opts], Acc)
  when Version =:= 'tlsv1' orelse Version =:= 'tlsv1.1'orelse
       Version =:= 'tlsv1.2' orelse Version =:= 'tlsv1.3' ->
    parse_cmd_opts(Opts, maybe_append(ssl_opts, {versions, [Version]}, Acc));
parse_cmd_opts([{cafile, CAFile} | Opts], Acc) ->
    parse_cmd_opts(Opts, maybe_append(ssl_opts, {cacertfile, CAFile}, Acc));
parse_cmd_opts([{cert, Cert} | Opts], Acc) ->
    parse_cmd_opts(Opts, maybe_append(ssl_opts, {certfile, Cert}, Acc));
parse_cmd_opts([{key, Key} | Opts], Acc) ->
    parse_cmd_opts(Opts, maybe_append(ssl_opts, {keyfile, Key}, Acc));
parse_cmd_opts([{sni, SNI} | Opts], Acc) ->
    parse_cmd_opts(Opts, maybe_append(ssl_opts, {server_name_indication, SNI}, Acc));
parse_cmd_opts([{qos, QoS} | Opts], Acc) ->
    parse_cmd_opts(Opts, [{qos, QoS} | Acc]);
parse_cmd_opts([{retain_as_publish, RetainAsPublish} | Opts], Acc) ->
    parse_cmd_opts(Opts, [{rap, RetainAsPublish} | Acc]);
parse_cmd_opts([{retain_handling, RetainHandling} | Opts], Acc) ->
    parse_cmd_opts(Opts, [{rh, RetainHandling} | Acc]);
parse_cmd_opts([{retain, Retain} | Opts], Acc) ->
    parse_cmd_opts(Opts, [{retain, Retain} | Acc]);
parse_cmd_opts([{topic, Topic} | Opts], Acc) ->
    parse_cmd_opts(Opts, [{topic, list_to_binary(Topic)} | Acc]);
parse_cmd_opts([{payload, Payload} | Opts], Acc) ->
    parse_cmd_opts(Opts, [{payload, list_to_binary(Payload)} | Acc]);
parse_cmd_opts([{file, File} | Opts], Acc) ->
    parse_cmd_opts(Opts, [{file, File} | Acc]);
parse_cmd_opts([{repeat, Repeat} | Opts], Acc) ->
    parse_cmd_opts(Opts, [{repeat, Repeat} | Acc]);
parse_cmd_opts([{repeat_delay, RepeatDelay} | Opts], Acc) ->
    parse_cmd_opts(Opts, [{repeat_delay, RepeatDelay} | Acc]);
parse_cmd_opts([{print, WhatToPrint} | Opts], Acc) ->
    parse_cmd_opts(Opts, [{print, WhatToPrint} | Acc]);
parse_cmd_opts([{verify, IsVerify} | Opts], Acc) ->
    V = case IsVerify of
            true -> verify_peer;
            false -> verify_none
        end,
    parse_cmd_opts(Opts, maybe_append(ssl_opts, {verify, V}, Acc));
parse_cmd_opts([_ | Opts], Acc) ->
    parse_cmd_opts(Opts, Acc).

maybe_append(Key, Value, TupleList) ->
    case lists:keytake(Key, 1, TupleList) of
        {value, {Key, OldValue}, NewTupleList} ->
            [{Key, [Value | OldValue]} | NewTupleList];
        false ->
            [{Key, [Value]} | TupleList]
    end.

enrich_opts(Opts) ->
    pipeline([fun enrich_clientid_opt/1,
              fun enrich_port_opt/1], Opts).

enrich_clientid_opt(Opts) ->
    case lists:keyfind(clientid, 1, Opts) of
        false -> [{clientid, emqtt:random_client_id()} | Opts];
        _ -> Opts
    end.

enrich_port_opt(Opts) ->
    case proplists:get_value(port, Opts) of
        undefined ->
            Port = case proplists:get_value(ssl, Opts) of
                        true -> 8883;
                        false -> 1883
                    end,
            [{port, Port} | Opts];
        _ -> Opts
    end.

pipeline([], Input) ->
    Input;

pipeline([Fun|More], Input) ->
    pipeline(More, erlang:apply(Fun, [Input])).

receive_loop(Client, Print) ->
    receive
        {publish, #{payload := Payload}} ->
            case Print of
                "size" -> io:format("received ~p bytes~n", [size(Payload)]);
                _ -> io:format("~s~n", [Payload])
            end,
            receive_loop(Client, Print);
        ping ->
            emqtt:ping(Client),
            receive_loop(Client, Print);
        _Other ->
            receive_loop(Client, Print)
    end.

i(true)  -> 1;
i(false) -> 0.

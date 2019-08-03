emqtt
=====

Erlang MQTT v5.0 Client compatible with MQTT v3.0

Build
-----

    $ make

Build with websocket dependencies
---------------------------------

     $ export WITH_WS=true
     $ make

Getting started
---------------

rebar.config
```erlang
{deps, [{emqtt, {git, "https://github.com/emqx/emqtt", {tag, "v1.0.0"}}}]}.
```

Here is the simple usage of `emqtt` library.

``` erlang
{ok, ConnPid} = emqtt:start_link([{client_id, ClientId}]),
{ok, _Props} = emqtt:connect(ConnPid),
Topic = <<"guide">>,
QoS = 1,
{ok, _Props, _ReasonCodes} = emqtt:subscribe(ConnPid, {Topic, QoS}),
{ok, _PktId} = emqtt:publish(ConnPid, <<"guide">>, <<"Hello World!">>, QoS),
%% If the qos of publish packet is 0, 
%% ok = emqtt:publish(ConnPid, <<"guide">>, <<"Hello World!">>, 0)
```

Not only the `client_id` can be passed as parameter, but also a lot of other options
 can be passed as parameters.
 
Here is the paramters list which could be passed into emqtt:start_link/1.

``` erlang
{name, atom()}
{owner, pid()}
{msg_handler, msg_handler()}
{host, host()}
{hosts, [{host(), inet:port_number()}]}
{port, inet:port_number()}
{tcp_opts, [gen_tcp:option()]}
{ssl, boolean()}
{ssl_opts, [ssl:ssl_option()]}
{ws_path, string()}
{connect_timeout, pos_integer()}
{bridge_mode, boolean()}
{client_id, iodata()}
{clean_start, boolean()}
{username, iodata()}
{password, iodata()}
{proto_ver, v3 | v4 | v5}
{keepalive, non_neg_integer()}
{max_inflight, pos_integer()}
{retry_interval, timeout()}
{will_topic, iodata()}
{will_payload, iodata()}
{will_retain, boolean()}
{will_qos, qos()}
{will_props, properties()}
{auto_ack, boolean()}
{ack_timeout, pos_integer()}
{force_ping, boolean()}
{properties, properties()}).
```

## License

Apache License Version 2.0

## Author

EMQ X Team.


# emqttc

Erlang mqtt client.
Emttc provides parallel connection and auto reconnect to broker.

## Build

```
$ make
```

## Start Application

```erl-sh
1> application:start(emqttc).
```

## Subscribe and Publush

Connect to MQTT Broker.

```erl-sh
1> {ok, Pid} = emqttc:start_link([{host, "test.mosquitto.org"}]).

%% publish (QoS=0).
2> emqttc:publish(Pid, <<"temp/random">>, <<"0">>).
ok

%% publish (QoS=1).
2> emqttc:publish(Pid, <<"temp/random">>, <<"0">>, [{qos, 1}]).
{ok, 0}

%% publish (QoS=2).
2> emqttc:publish(Pid, <<"temp/random">>, <<"0">>, [{qos, 2}]).
{ok, 1}

%% publish (QoS=2 AND Retain=true).
2> emqttc:publish(Pid, <<"temp/random">>, <<"0">>, [{qos, 2}, {retain, true}]).
{ok, 1}

%% subscribe.
3> Qos = 0.
4> emqttc:subscribe(Pid, [{<<"temp/random">>, Qos}]).
ok

%% add event handler.
5> emqttc_event:add_handler().
ok
```

You can add your custom event handler.

```erl-sh
1> emqttc_event:add_handler(your_handler, []).
```

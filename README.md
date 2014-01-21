# emqttc

erlang mqtt client.

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
1> emqttc:start_link([{host, "test.mosquitto.org"}]).

%% publish (QoS=0).
2> emqttc:publish(emqttc, <<"temp/random">>, <<"0">>).
ok

%% publish (QoS=1).
2> emqttc:publish(emqttc, <<"temp/random">>, <<"0">>, 1).
{ok, 0}

%% publish (QoS=2).
2> emqttc:publish(emqttc, <<"temp/random">>, <<"0">>, 2).
{ok, 1}

%% subscribe.
3> Qos = 0.
4> emqttc:subscribe(emqttc, [{<<"temp/random">>, Qos}]).
ok

%% add event handler.
5> emqttc_event:add_handler().
ok
```

You can add your custom event handler.

```erl-sh
1> emqttc_event:add_handler(your_handler, []).
```

# emqttc   [![Build Status](https://travis-ci.org/hiroeorz/emqttc.svg?branch=master)](https://travis-ci.org/hiroeorz/emqttc)

Erlang MQTT Client.

emqttc support parallel connections and auto reconnect to broker.

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

%% add event handler.
5> emqttc:add_event_handler(Pid, my_handler).
ok

```

##Options

### Clean Session

Default Clean Session value is true, If you want to set Clean Session = false, add option <code>{clean_session, false}</code>.

```erl-sh
1> {ok, Pid} = emqttc:start_link([{host, "test.mosquitto.org"}, {clean_session. false}]).
```

### Keep Alive

Default Keep Alive value is 20(sec), If you want to set KeepAlive, add option <code>{keep_alive, 60}</code>.

```erl-sh
1> {ok, Pid} = emqttc:start_link([{host, "test.mosquitto.org"}, {keep_alive. 60}]).
```

## Contributors 

@hiroeorz

@desoulter



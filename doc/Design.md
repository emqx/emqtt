# Design Guide

## Modules

Module | Description
------ | ------------
emqttc | main api module
emqttc_protocol | mqtt protocol process
.......

## API Design

### Connect

```
{ok, C} = emqttc:start_link(MQTTOpts).

```

### Publish

### Subscribe

## Message Dispatch

```
Sub ----------
            \|/
Sub -----> Client<------Pub------Broker
            /|\
Sub ----------
```

```
Pub------>Client------->Broker
```






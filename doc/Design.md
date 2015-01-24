# Design Guide

## Modules

Module | Description
------ | ------------
emqttc | main api module
emqttc_packet | mqtt packet encode/decode
emqttc_protocol | mqtt protocol process


## API Design

### Connect

```
{ok, C} = emqttc:start_link(MQTTOpts).

```





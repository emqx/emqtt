# 1.7.0

## Enhancements

* Use bit flags instead of boolean record fields (there were 8 of them)
* Hide password in an anonymous function to prevent it from leaking into the (crash) logs [#168](https://github.com/emqx/emqtt/pull/168)
* Added `publish_async` APIs to support asynchronous publishing. [#165](https://github.com/emqx/emqtt/pull/165)
  Note that an incompatible update has been included, where the return format
  of the `publish` function has been changed to `ok | {ok, publish_reply()} | {error, Reason}`

## Bug fixes

* Fixed inflight message retry after reconnect [#166](https://github.com/emqx/emqtt/pull/166)

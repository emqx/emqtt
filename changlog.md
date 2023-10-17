# 1.9.2

- Discard session_present flag from CONNACK. This flag is not used.

# 1.9.1

- Removed 'maybe' type.
- Fix websocket transport options.
- Support OTP 26.
- Drop `reuse_sessions` and `secure_renegotiate` options when TLS 1.3 is the only version in use.

# 1.9.0

- Upgrade `quicer` lib

# 1.8.7

- Fix a race-condition caused crash when changing control process after SSL upgrade.
  The race-condition is from OTP's `ssl` lib, this fix only avoids `emqtt` process to crash.

# 1.8.6

- Sensitive data obfuscation in debug logs.

# 1.8.5

- Fix ssl error messages handeling.

# 1.8.4

- Support MacOS build for QUIC

# 1.8.3

- Support `binary()` hostname.

# 1.8.0-1.8.2

- Support QUIC Multi-stream

# 1.7.0

- Hide password in an anonymous function to prevent it from leaking into the (crash) logs [#168](https://github.com/emqx/emqtt/pull/168)
- Added `publish_async` APIs to support asynchronous publishing. [#165](https://github.com/emqx/emqtt/pull/165)
  Note that an incompatible update has been included, where the return format
  of the `publish` function has been changed to `ok | {ok, publish_reply()} | {error, Reason}`

- Fixed inflight message retry after reconnect [#166](https://github.com/emqx/emqtt/pull/166)
- Respect connect_timeout [#169](https://github.com/emqx/emqtt/pull/169)

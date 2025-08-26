# 1.14.2

- WebSocket: Correctly adopt Gun 2.x interfaces and semantics.

# 1.14.1

- QUIC: Correctly handle peer stream recv abort.
- TLS1.3: Fix crash after recv session ticket

# 1.14.0

- Switch to using `gun` 2.1.0 as WebSocket client.

# 1.13.7

- Fix a typo in MQTT v3 reason code.

# 1.13.6

- Support QoE tcp latency tracking in SSL case.

# 1.13.5

- Avoid OTP crash reports by wrapping exit reason in the format `{shutdown,Reason}`.
- Avoid `badmatch` error when `websocket` connection timeout.
- Reformat some code for readability.
- Fix `emqtt` was not trying to reconnect in certain error scenarios.
- Fix function specs for `emqtt:connect/1` and `emqtt:ws_connect/1`.
- Add missing opts to `README.md`.

# 1.13.4

- Handle CONNECT packet send error asynchronously so to allow a retry.
- Handle `tcp_error` and `ssl_error` at `waiting_for_connack` state so to allow a retry.
- Change log level for `reconnect_due_to_connection_error` from `error` to `info`.
- Fix compile warnings on OTP 27.

# 1.13.3

- Fix compile issues on OTP 27.

# 1.13.2

- Support fine-tuneing QUIC transport options.

# 1.13.1

- Support QUIC stream ID.
- Improve exception context when broker did not assign client ID as expected.
  Changed `bad_client_id` to `no_client_id_assigned_by_broker` so we know it's broker to blame but not client.

# 1.13.0

- Support Kerberos authentication callbacks.

# 1.12.0

- Add `max_inflight` option.
- Respect Receive-Maximum if advertised by server.
- Support SCRAM authentication callbacks.

# 1.11.0

- Add `connect` command which only establishes connection,
  but does not publish or subscribe.
- Add `--log-level` option to CLI.
- Add timestamp to CLI logs.
- Exit with non-zero code when CLI stops due to error.

# 1.10.0

- Export emqtt:qos/0, emqtt:topic/0 and emqtt:packet_id/0 as public types.
- Release packages on OTP 26
  - Stopped releasing on
    - EL 8
    - Ubuntu 18
    - Debian 10
  - Newly supported distros
    - EL 9
    - Debian 12
    - Ubuntu 22
    - Amazon Linux 2023

# 1.9.6

- Add `{auto_ack, never}` option fully disabling automatic QoS2 flow.

# 1.9.5

- Fix compilation warning.

# 1.9.4

- Respect reconnect option more robustly, attempting to reconnect in more cases.

# 1.9.3

- Attempt to reconnect when server sends a `DISCONNECT` packet, if reconnects are enabled.

# 1.9.2

- Allow external wrapped secrets as passwords.

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

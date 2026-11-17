#!/usr/bin/env bash

## Start or stop the EMQX broker that the Common Test suites run against.
##
##   scripts/ct-broker.sh up     start the container, wait until EMQX is started
##   scripts/ct-broker.sh down   remove the container
##
## The suites expect the broker on the loopback address of the test VM, at the
## default ports, and the broker calls back into the test VM over HTTP (see
## `emqtt_test_lib:delay_authn/1'). So the container shares a network
## namespace with the test VM instead of publishing ports:
##
## - locally: `--network host' (the default);
## - in CI: `CT_BROKER_NETWORK=container:<test container>'.
##
## Environment:
##   CT_BROKER_NAME     container name (default emqtt-ct-emqx)
##   CT_BROKER_IMAGE    image (default emqx/emqx:latest)
##   CT_BROKER_NETWORK  docker network mode (default host)

set -euo pipefail

NAME="${CT_BROKER_NAME:-emqtt-ct-emqx}"
IMAGE="${CT_BROKER_IMAGE:-emqx/emqx:latest}"
NETWORK="${CT_BROKER_NETWORK:-host}"

## TCP ports: MQTT, MQTT/TLS, WS, WSS, the REST API, IPv6 MQTT and WS.
TCP_PORTS=(1883 8883 8083 8084 18083 21883 28083)
## UDP ports: QUIC on IPv4 and IPv6.
UDP_PORTS=(14567 34567)

## Fail early, with a clear message, when another process holds a port.
check_ports() {
    if ! command -v ss >/dev/null 2>&1; then
        return 0
    fi
    local busy=()
    local p
    for p in "${TCP_PORTS[@]}"; do
        if ss -Hltn "sport = :${p}" | grep -q .; then busy+=("tcp/${p}"); fi
    done
    for p in "${UDP_PORTS[@]}"; do
        if ss -Hlun "sport = :${p}" | grep -q .; then busy+=("udp/${p}"); fi
    done
    if [ "${#busy[@]}" -gt 0 ]; then
        echo "Ports already in use: ${busy[*]}" >&2
        echo "Stop the process that holds them, then run this script again." >&2
        exit 1
    fi
}

wait_started() {
    local i
    for i in $(seq 1 120); do
        if docker exec "${NAME}" emqx ctl status 2>/dev/null | grep -q 'is started'; then
            echo "EMQX is started in container ${NAME}"
            return 0
        fi
        if [ "$(docker inspect -f '{{.State.Running}}' "${NAME}" 2>/dev/null)" != "true" ]; then
            break
        fi
        sleep 1
    done
    echo "EMQX did not start in container ${NAME}" >&2
    docker logs --tail 100 "${NAME}" >&2 || true
    exit 1
}

up() {
    down
    if [ "${NETWORK}" = "host" ]; then
        check_ports
    fi
    ## - Listeners bind the loopback address only: the REST API uses the
    ##   default dashboard login. QUIC is the exception: msquic binds the
    ##   wildcard address anyway, and the IPv6 group connects to its QUIC
    ##   listener over IPv4 too, so both QUIC listeners are dual-stack.
    ## - QUIC and the IPv6 listeners are enabled for the QUIC and IPv6 groups.
    ## - Authorization allows everything, as the broker that the suites embedded
    ##   before did. The default rules of the image deny `#' and `$SYS/#'.
    docker run -d --name "${NAME}" --memory 2g --network "${NETWORK}" \
        -e EMQX_NODE__NAME="emqx@127.0.0.1" \
        -e EMQX_DASHBOARD__LISTENERS__HTTP__BIND='"127.0.0.1:18083"' \
        -e EMQX_LISTENERS__TCP__DEFAULT__BIND='"127.0.0.1:1883"' \
        -e EMQX_LISTENERS__SSL__DEFAULT__BIND='"127.0.0.1:8883"' \
        -e EMQX_LISTENERS__WS__DEFAULT__BIND='"127.0.0.1:8083"' \
        -e EMQX_LISTENERS__WSS__DEFAULT__BIND='"127.0.0.1:8084"' \
        -e EMQX_LISTENERS__QUIC__DEFAULT__ENABLE=true \
        -e EMQX_LISTENERS__QUIC__DEFAULT__BIND='":14567"' \
        -e EMQX_LISTENERS__TCP__MQTT_IP6__BIND='"[::1]:21883"' \
        -e EMQX_LISTENERS__WS__MQTT_IP6__BIND='"[::1]:28083"' \
        -e EMQX_LISTENERS__QUIC__MQTT_IP6__ENABLE=true \
        -e EMQX_LISTENERS__QUIC__MQTT_IP6__BIND='":34567"' \
        -e EMQX_AUTHORIZATION__SOURCES='[]' \
        -e EMQX_AUTHORIZATION__NO_MATCH=allow \
        -e EMQX_AUTHORIZATION__CACHE__ENABLE=false \
        "${IMAGE}" >/dev/null
    wait_started
}

down() {
    if docker container inspect "${NAME}" >/dev/null 2>&1; then
        docker rm -f "${NAME}" >/dev/null
    fi
}

case "${1:-}" in
    up) up ;;
    down) down ;;
    *)
        echo "Usage: $0 up|down" >&2
        exit 2
        ;;
esac

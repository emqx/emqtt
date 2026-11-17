#!/bin/sh
set -ex

export PACKAGE_PATH="_packages"

## The smoke test publishes one message with the packaged CLI. For the Linux
## builds, CI starts an EMQX container and passes its host name in
## EMQTT_TEST_BROKER. The macOS runner has no docker: without
## EMQTT_TEST_BROKER, the test publishes to a fake broker, which checks that
## the PUBLISH arrives (see fake_broker.escript).
BROKER="${EMQTT_TEST_BROKER:-}"
FAKE_BROKER_PORT=18830
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

build_pkg(){
    if [ "$(uname)" = "Linux" ]; then
        make pkg
    elif [ "$(uname)" = "Darwin" ]; then
        pkg=emqtt-macos-$(git describe --tags --always).zip
        make emqtt
        mkdir -p "${PACKAGE_PATH}"

        cd _build/emqtt/rel && zip -rq "${pkg}" emqtt && cd -
        mv "_build/emqtt/rel/${pkg}" "${PACKAGE_PATH}"
    fi
}

## $1: the emqtt command to test
pub(){
    if [ -n "${BROKER}" ]; then
        "$1" pub -t 'hello' --payload 'hello world' -h "${BROKER}"
        return
    fi
    ready="$(mktemp -d)/ready"
    escript "${SCRIPT_DIR}/fake_broker.escript" "${FAKE_BROKER_PORT}" "${ready}" &
    fake=$!
    i=0
    while [ ! -f "${ready}" ]; do
        i=$((i + 1))
        if [ "$i" -gt 30 ] || ! kill -0 "${fake}" 2>/dev/null; then
            echo 'fake broker did not start' && exit 1
        fi
        sleep 1
    done
    "$1" pub -t 'hello' --payload 'hello world' -h 127.0.0.1 -p "${FAKE_BROKER_PORT}"
    wait "${fake}"
}

test_pkg(){
    for var in ${PACKAGE_PATH}/emqtt-*; do
        case ${var##*.} in
            "zip")
            unzip -q "${var}"
            pub ./emqtt/bin/emqtt
            rm -rf emqtt
            ;;
            "deb")
            dpkg -i "${var}"
            if [ "$(dpkg -l | grep emqtt | awk '{print $1}')" != "ii" ]; then
                echo 'package install error' && exit 1
            fi
            pub emqtt
            dpkg -P emqtt
            if [ -n "$(dpkg -l | grep emqtt)" ]; then
                echo 'package uninstall error' && exit 1
            fi
            ;;
            "rpm")
            rpm -ivh "${var}"
            pub emqtt
            rpm -e emqtt
            ;;
        esac
    done
}

build_pkg
test_pkg

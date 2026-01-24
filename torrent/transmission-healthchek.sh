#!/bin/sh
set -e

URL="http://localhost:9091/transmission/rpc"

# Проверяем, что Transmission RPC отвечает заголовком X-Transmission-Session-Id
curl -fs -D - -o /dev/null "$URL" | grep -q "X-Transmission-Session-Id" || exit 1

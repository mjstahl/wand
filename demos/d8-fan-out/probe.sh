#!/usr/bin/env bash
# Stands in for a real health check, so the demo runs offline: it sleeps for
# as long as the caller asks and then reports. Three hosts are unreachable,
# and say so by exiting non-zero -- which is how a check fails for real.
sleep "${D8_DELAY:-0.3}"
case "$1" in
  web-04|db-02|cache-03)
    echo "connection refused"
    exit 1
    ;;
esac
echo "ok"

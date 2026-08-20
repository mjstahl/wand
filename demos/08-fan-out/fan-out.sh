#!/usr/bin/env bash
# The same fan-out in bash: `xargs -P` for the concurrency, a trap for the
# cleanup, and a temp file to collect the results, because a subshell cannot
# hand a value back to its parent.
#
# The trap covers what this script owns -- the results file. It cannot cover
# what the workers hold, because they are separate processes with their own
# leases, and a trap here does not run there.
set -uo pipefail
cd "$(dirname "$0")/../.."
LEASES=/tmp/wand-demo-08-leases-bash
RESULTS=$(mktemp)
trap 'rm -f "$RESULTS"' EXIT INT

rm -rf "$LEASES"; mkdir -p "$LEASES"

check() {
  host=$1
  touch "$LEASES/$host"
  if out=$(demos/08-fan-out/probe.sh "$host"); then
    echo "  ok    $host  $out" >> "$RESULTS"
  else
    echo "  FAIL  $host  $out" >> "$RESULTS"
  fi
  rm -f "$LEASES/$host"
}
export -f check
export LEASES RESULTS D8_DELAY

printf '%s\n' \
  web-01 web-02 web-03 web-04 web-05 web-06 web-07 web-08 \
  db-01 db-02 db-03 db-04 \
  cache-01 cache-02 cache-03 cache-04 \
  edge-01 edge-02 edge-03 edge-04 \
  | xargs -P 8 -I{} bash -c 'check {}'

# Results arrive in the order they finished, so the input order is gone. What
# comes back is whatever the file happens to hold.
cat "$RESULTS"

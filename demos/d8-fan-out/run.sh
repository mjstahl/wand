#!/usr/bin/env bash
# Fan out over twenty hosts, three of them unreachable, and then interrupt
# the whole thing halfway through.
#
# Two claims are on trial. That a failure is a value: three hosts fail and
# the other seventeen still report, in the order they were asked. And that a
# `with` releases however the script ends: Ctrl-C during the fan-out releases
# every in-flight worker's lease.
#
# The bash version is here for the second one. It is not a strawman -- it is
# how this is written -- and its trap does run. It just cannot reach into the
# eight workers, which are separate processes holding leases of their own.
#
# Job control is on so each run gets its own process group, and the interrupt
# goes to the group. That is what Ctrl-C at a terminal does, and signalling
# only the top process would be a different test: bash defers a trap until
# the command it is waiting on returns, so the run would finish first.
set -uo pipefail -m
cd "$(dirname "$0")/../.."
WAND=_build/default/bin/wand.exe
source "$(dirname "$0")/../assert.sh"
D=demos/d8-fan-out
LEASES=/tmp/wand-demo-d8-leases
BASH_LEASES=/tmp/wand-demo-d8-leases-bash

# Every check holds a lease file while it runs, so what is in flight -- and
# what is left behind -- can be counted from outside the script.
count()       { ls "$1" 2>/dev/null | wc -l | tr -d ' '; }
held()        { echo "leases still held: $(count "$LEASES")"; }
bash_held()   { echo "leases still held: $(count "$BASH_LEASES")"; }
running()     { echo "probes still running: $(pgrep -f "$D/probe.sh" | wc -l | tr -d ' ')"; }
reset()       { rm -rf "$LEASES"; mkdir -p "$LEASES"; }
check_hosts() { reset; "$WAND" "$D/check-hosts.wand"; }
fourth()      { check_hosts | sed -n '4p'; }

# Wait for the fan-out to be underway rather than guessing with a sleep: a
# demo that races is a demo that fails on someone else's machine.
await_flight() {
  local tries=200
  until [ -n "$(ls "$1" 2>/dev/null)" ] || [ "$tries" -eq 0 ]; do
    sleep 0.05; tries=$((tries - 1))
  done
  sleep 0.4
}

# Start a run, wait for it to be busy, interrupt its process group, and
# report how it ended.
interrupt() {
  local leases=$1; shift
  local pid code
  "$@" >/dev/null 2>&1 &
  pid=$!
  await_flight "$leases"
  echo "  in flight: $(count "$leases") leases, $(pgrep -f "$D/probe.sh" | wc -l | tr -d ' ') probes"
  echo "  ^C"
  kill -INT -- "-$pid" 2>/dev/null
  wait "$pid"; code=$?
  sleep 0.3
  echo "  exit $code"
}

echo "== twenty hosts, eight at a time =="
check_hosts

echo
echo "== the same run, interrupted halfway =="
reset
D8_DELAY=17 interrupt "$LEASES" "$WAND" "$D/check-hosts.wand"
echo "  $(held)"
echo "  $(running)"

# Checked here rather than at the end, because the bash run below leaves
# leases of its own and this directory is about to be reused.
moment "leases still held: 0" held

echo
echo "== the same thing in bash: xargs -P 8, a trap, a temp file =="
D8_DELAY=17 interrupt "$BASH_LEASES" "$D/fan-out.sh"
echo "  $(bash_held)"
echo "  $(running)"

# The trap fired -- the results file is gone. The workers are not the
# parent's to release, so what they were holding stays held.
moment "leases still held: 8" bash_held

pkill -f "$D/probe.sh" >/dev/null 2>&1
rm -rf "$LEASES" "$BASH_LEASES"

# The point: a failure is a value and the order survives it; and an interrupt
# releases every lease the run was holding.
echo
moment "FAIL  web-04" fourth
moment "17 reachable, 3 not, and none of it fatal" check_hosts
rm -rf "$LEASES"

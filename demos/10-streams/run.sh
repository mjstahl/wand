#!/usr/bin/env bash
# A stream reads nothing until the fold runs it: the fold opens the
# file, reads a line at a time, and closes on the way out.
#
# Two claims are on trial. That a file folds in bounded memory -- a
# million lines counted without holding them. And that `take` stops the
# reading -- proved on a source that never ends: a fifo whose writer
# loops forever. If `take` did not stop the pulling, the second script
# would never come back.
set -uo pipefail
cd "$(dirname "$0")/../.."
WAND=_build/default/bin/wand.exe
source "$(dirname "$0")/../assert.sh"
D=demos/10-streams
LOG=/tmp/wand-demo-10.log
FIFO=/tmp/wand-demo-10.fifo

# awk generates directly: macOS seq drifts into scientific notation at a
# million and pads an extra line.
awk 'BEGIN { for (i = 1; i <= 1000000; i++)
  print (i % 7 == 0) ? "ERROR line " i : "ok line " i }' > "$LOG"

count() { "$WAND" "$D/count-errors.wand" "$LOG"; }

five() {
  rm -f "$FIFO"; mkfifo "$FIFO"
  ( i=0; while :; do i=$((i+1)); echo "tick $i"; done > "$FIFO" ) 2>/dev/null &
  local writer=$!
  "$WAND" "$D/endless.wand" "$FIFO"
  kill "$writer" 2>/dev/null
  wait "$writer" 2>/dev/null
  rm -f "$FIFO"
}

echo "== a million lines, counted without holding them =="
echo "input: $(wc -l < "$LOG" | tr -d ' ') lines"
count

echo
echo "== five lines from a source that never ends =="
five

# The points: the count is exact, and the endless read returned.
assert "142857 ERROR lines" count
assert "tick 5" five

rm -f "$LOG" "$FIFO"

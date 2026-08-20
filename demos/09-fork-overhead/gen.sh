#!/usr/bin/env bash
# Generate a synthetic log: "<ts> <LEVEL> <component> <message>"
set -euo pipefail
n="${1:-200000}"
out="${2:-/tmp/wand-demo.log}"
awk -v n="$n" 'BEGIN {
  split("ERROR WARN INFO INFO INFO", lv, " ")
  split("db cache api worker", comp, " ")
  for (i = 0; i < n; i++)
    printf "2024-01-15T%02d:%02d:%02d %s %s message number %d\n",
      i%24, i%60, (i*7)%60, lv[(i%5)+1], comp[(i%4)+1], i
}' > "$out"
wc -l < "$out" | tr -d ' ' | sed 's/$/ lines/'

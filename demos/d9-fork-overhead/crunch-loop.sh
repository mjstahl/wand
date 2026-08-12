#!/usr/bin/env bash
# The other common bash idiom: a per-line loop that shells out. This is what
# a script grows into when the work stops fitting a single pipeline.
set -uo pipefail
f="${1:-/tmp/wand-demo.log}"; e=0; w=0; i=0
while read -r line; do
  lv=$(echo "$line" | cut -d' ' -f2)
  case "$lv" in ERROR) e=$((e+1));; WARN) w=$((w+1));; INFO) i=$((i+1));; esac
done < "$f"
echo "ERROR $e"
echo "WARN $w"
echo "INFO $i"

#!/usr/bin/env bash
# Idiomatic bash: let coreutils do the work, one pipeline per question.
set -euo pipefail
f="${1:-/tmp/wand-demo.log}"
for lv in ERROR WARN INFO; do
  printf '%s %s\n' "$lv" "$(grep -c " $lv " "$f")"
done
printf 'components-with-errors %s\n' \
  "$(grep " ERROR " "$f" | cut -d' ' -f3 | sort -u | wc -l | tr -d ' ')"

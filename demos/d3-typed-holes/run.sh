#!/usr/bin/env bash
# Write the part you are sure about, leave `?` where you are not, and ask.
set -uo pipefail
cd "$(dirname "$0")/../.."
WAND=_build/default/bin/wand.exe
D=demos/d3-typed-holes

echo "== the sketch =="
sed -n '6,10p' "$D/summarize.wand"

echo
echo "== what belongs in the hole =="
"$WAND" t "$(cat "$D/summarize.wand")" 2>&1 | head -3

echo
echo "== filled in, then run =="
printf 'ERROR disk full\nINFO ok\nERROR again\n' | "$WAND" "$D/summarize-filled.wand"
exit 0

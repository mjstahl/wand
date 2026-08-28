#!/usr/bin/env bash
# Write the part you are sure about, leave `?` where you are not, and ask.
set -uo pipefail
cd "$(dirname "$0")/../.."
WAND=_build/default/bin/wand.exe
source "$(dirname "$0")/../assert.sh"
D=demos/03-typed-holes

echo "== the sketch =="
sed -n '8,12p' "$D/summarize.wand"

echo
echo "== what belongs in the hole =="
"$WAND" t "$D/summarize.wand" 2>&1 | head -3

echo
echo "== filled in, then run =="
printf 'ERROR disk full\nINFO ok\nERROR again\n' | "$WAND" "$D/summarize-filled.wand"

# The point: the hole is answered with the signature to write.
assert "Hole: Map 'a -> String -> Map 'a" \
  "$WAND" t "$D/summarize.wand"

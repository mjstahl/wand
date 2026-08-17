#!/usr/bin/env bash
# Rehearse a deploy, then run it, and compare.
set -uo pipefail
cd "$(dirname "$0")/../.."
WAND=_build/default/bin/wand.exe
source "$(dirname "$0")/../assert.sh"
D=demos/d5-rehearse
TARGET=/tmp/wand-demo-deploy

rm -rf "$TARGET"

echo "== the manifest says what it may touch =="
head -1 "$D/deploy.wand" | sed 's/^/  /'

echo
echo "== rehearsal =="
"$WAND" --dry-run "$D/deploy.wand" 2>&1 | sed 's/^/  /'

echo
echo "== and afterwards =="
if [ -e "$TARGET" ]; then echo "  $TARGET exists"; else echo "  $TARGET does not exist"; fi
echo "  DEPLOYED_VERSION=${DEPLOYED_VERSION:-<unset>}"

echo
echo "== the real thing, traced =="
"$WAND" --trace "$D/deploy.wand" 2>&1 | sed 's/^/  /'

echo
echo "== and afterwards =="
ls "$TARGET" | sed 's/^/  /'
cat "$TARGET/config.toml" | sed 's/^/  /'
rm -rf "$TARGET"

# The point: the rehearsal reports the write and performs none of it, and
# the file says up front what it may touch.
assert "uses {Shell(git, echo), FS.Write, Env}" head -1 "$D/deploy.wand"
assert "would write" "$WAND" --dry-run "$D/deploy.wand"
assert_absent "$TARGET"

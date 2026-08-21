#!/usr/bin/env bash
# Same task, same missing variable, two languages.
set -uo pipefail
cd "$(dirname "$0")/../.."
WAND=_build/default/bin/wand.exe
source "$(dirname "$0")/../assert.sh"
unset STAGING_DIR

echo "== bash =="
demos/01-unset-variable/cleanup.sh

echo
echo "== wand, written the same way =="
"$WAND" demos/01-unset-variable/unsafe.wand 2>&1 || true

echo
echo "== wand, once the missing case is answered =="
"$WAND" demos/01-unset-variable/cleanup.wand

# The point: bash expands an unset variable into `rm -rf /`, and wand will
# not run the same script until the missing case is answered.
assert "expected String, got Option String" \
  "$WAND" demos/01-unset-variable/unsafe.wand

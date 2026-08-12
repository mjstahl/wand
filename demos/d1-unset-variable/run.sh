#!/usr/bin/env bash
# Same task, same missing variable, two languages.
set -uo pipefail
cd "$(dirname "$0")/../.."
WAND=_build/default/bin/wand.exe
unset STAGING_DIR

echo "== bash =="
demos/d1-unset-variable/cleanup.sh

echo
echo "== wand, written the same way =="
"$WAND" demos/d1-unset-variable/unsafe.wand 2>&1 || true

echo
echo "== wand, once the missing case is answered =="
"$WAND" demos/d1-unset-variable/cleanup.wand

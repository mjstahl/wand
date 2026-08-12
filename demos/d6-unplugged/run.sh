#!/usr/bin/env bash
# A test suite for a script whose real execution would push to production.
set -uo pipefail
cd "$(dirname "$0")/../.."
WAND=_build/default/bin/wand.exe
D=demos/d6-unplugged

echo "== the script under test =="
sed -n '6,11p' "$D/deploy.wand" | sed 's/^/  /'

echo
printf '  deploy! : '
"$WAND" t --load "$D/deploy.wand" 'deploy!'

echo
echo "== its test suite =="
"$WAND" test "$D" 2>&1 | sed 's/^/  /'

echo
echo "== and the file it would have written =="
if [ -e /etc/app/config.toml ]; then echo "  /etc/app/config.toml exists"; else echo "  /etc/app/config.toml does not exist"; fi
exit 0

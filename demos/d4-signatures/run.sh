#!/usr/bin/env bash
# One line is added, three helpers deep. Nothing else changes.
set -uo pipefail
cd "$(dirname "$0")/../.."
WAND=_build/default/bin/wand.exe
source "$(dirname "$0")/../assert.sh"
D=demos/d4-signatures

echo "== a backup script, nothing annotated =="
sed -n '7,12p' "$D/backup.wand"
echo
printf '  backup_all! : '
"$WAND" t --load "$D/backup.wand" 'backup_all!'

echo
echo "== someone adds a line inside a helper =="
grep -n 'curl' "$D/backup-phoning-home.wand" | sed 's/^/  /'
echo
printf '  backup_all! : '
"$WAND" t --load "$D/backup-phoning-home.wand" 'backup_all!'
echo "  (Shell, and nothing was annotated to say so)"

echo
echo "== now bound the file to what it is allowed to do =="
head -1 "$D/backup-bounded.wand" | sed 's/^/  /'
echo
"$WAND" t --file "$D/backup-bounded.wand" 2>&1 | sed 's/^/  /'

# The point: the effect is inferred through three helpers, and the manifest
# turns it into a compile error.
assert "FS.Read, FS.Write" "$WAND" t --load "$D/backup-phoning-home.wand" 'backup_all!'
assert "which the manifest does not allow" "$WAND" t --file "$D/backup-bounded.wand"

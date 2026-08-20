#!/usr/bin/env bash
# Values carry their kind, so the mistakes below are type errors rather
# than malformed strings discovered at runtime.
set -uo pipefail
cd "$(dirname "$0")/../.."
WAND=_build/default/bin/wand.exe
source "$(dirname "$0")/../assert.sh"

show() {  # show <label> <expr>
  printf '  %-34s ' "$2"
  "$WAND" t "$2" 2>&1 | head -1
}

echo "== what a literal is =="
show "" '30s'
show "" '1h30m'
show "" '*.wand'
show "" '/etc/hosts'
show "" '192.168.1.1'
show "" '10.0.0.0/24'
show "" ':8080'
show "" '100MB'
show "" '1.2.3'
show "" '2024-01-15'

echo
echo "== mistakes the types catch =="
show "" 'Duration.to_ms 30'
show "" 'Duration.add 1h 3'
show "" 'FS.glob /etc/hosts'
show "" 'Path.basename *.wand'

# The point: a path is not a glob, and the type system says so.
assert "cannot unify Glob with Path" "$WAND" e 'FS.glob /etc/hosts'

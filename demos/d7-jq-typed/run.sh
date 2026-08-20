#!/usr/bin/env bash
# Which pods are restarting too often -- asked twice of the same document,
# once through jq and awk, once through a type.
#
# Then the field name is got wrong, the way it is got wrong in practice:
# first by typing it wrong, then by the cluster renaming it. Both times the
# pipeline answers "nothing is crashlooping" and exits 0, while a database
# sits in CrashLoopBackOff with twelve restarts. Both times wand refuses to
# answer, and says which field it could not find.
set -uo pipefail
cd "$(dirname "$0")"
WAND=../../_build/default/bin/wand.exe
source ../assert.sh

# The typo goes in the type only -- the pattern that reads the field still
# says `restartCount`, which is what makes it a type error rather than a
# quiet rename. Spacing around the colon is whatever `wand f` last chose.
typo_wand() { sed -E 's/restartCount( *):/restartCnt\1:/' crashlooping.wand > typo.wand; "$WAND" typo.wand 2>&1; }
drifted_json() { sed 's/"restartCount"/"restarts"/g' pods.json > drifted.json; }
drifted_wand() { drifted_json; sed 's|./pods.json|./drifted.json|' crashlooping.wand > drift.wand; "$WAND" drift.wand 2>&1; }
# Silence is the finding, so it is counted rather than shown -- along with
# the exit status, which is the other half of why nobody notices.
counted() {
  local out rc n
  out="$("$@")"; rc=$?
  if [ -z "$out" ]; then n=0; else n=$(printf '%s\n' "$out" | wc -l | tr -d ' '); fi
  echo "$n pods reported, exit $rc"
}
typo_jq()  { counted ./crashlooping.sh restartCnt; }
drift_jq() { drifted_json; counted ./crashlooping.sh restartCount drifted.json; }
trap 'rm -f typo.wand drift.wand drifted.json' EXIT

echo "== jq and awk =="
sed -n '8,9p' crashlooping.sh | sed 's/^/  /'
./crashlooping.sh

echo
echo "== the same question, of the same document, through a type =="
grep '^type' crashlooping.wand | sed 's/^/  /'
"$WAND" crashlooping.wand

echo
echo "== now get the field name wrong: restartCount -> restartCnt =="
echo "  jq: $(typo_jq)"
echo "  wand:"
typo_wand | sed 's/^/  /'

echo
echo "== or leave the code alone and let the cluster rename the field =="
echo "  jq: $(drift_jq)"
echo "  wand:"
drifted_wand | sed 's/^/  /'

echo
echo "== what was actually in the document =="
jq -r '.items[] | "  \(.metadata.name)\t\(.status.phase)"' pods.json | sed 's/\t/  /'

# The point: the same mistake is silence on one side and a named field on the
# other -- and the silence is a clean bill of health for a pod that is down.
assert "db-01" "$WAND" crashlooping.wand
assert "constructor 'Container' has no field 'restartCount'" typo_wand
assert ".items[0].status.containerStatuses[0].restartCount: no such field" drifted_wand
assert "0 pods reported, exit 0" typo_jq
assert "0 pods reported, exit 0" drift_jq

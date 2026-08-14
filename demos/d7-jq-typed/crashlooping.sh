#!/usr/bin/env bash
# Which pods are restarting too often, the way it is written today.
#
# The field name is passed as an argument so the demo can run the same
# pipeline twice: once right, once with a typo in it.
FIELD=${1:-restartCount}
DOC=${2:-pods.json}
jq -r ".items[] | [.metadata.name, ([.status.containerStatuses[].${FIELD}] | add)] | @tsv" "$DOC" \
  | awk -F'\t' '$2 > 3 { printf "  %-12s %s\n", $1, $2 }'

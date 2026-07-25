#!/usr/bin/env bash
# Wand-writing benchmark harness. See bench/README.md.
#
# For each bench/tasks/<name>/ with a solution.wand present:
#   1. Check solution.wand parses/typechecks on its own.
#   2. Run cases.wand (which `import ./solution` and assert against it),
#      categorizing any failure as parse/type/wrong-output/runtime error.
#
# Usage: bench/run.sh [--label NAME]

set -uo pipefail
cd "$(dirname "$0")/.."

label="${2:-$(date +%Y-%m-%d)}"
tasks_dir="bench/tasks"
pass=0
fail=0
skip=0
declare -a rows

categorize() {
  local msg="$1"
  if echo "$msg" | grep -qi "parse error"; then echo "parse error"
  elif echo "$msg" | grep -qi "type error"; then echo "type error"
  elif echo "$msg" | grep -q "^FAIL:"; then echo "wrong output"
  else echo "runtime error"
  fi
}

for dir in "$tasks_dir"/*/; do
  name=$(basename "$dir")
  sol="$dir/solution.wand"
  cases="$dir/cases.wand"

  if [ ! -f "$sol" ]; then
    echo "SKIP        $name (no solution.wand)"
    skip=$((skip + 1))
    continue
  fi

  sol_out=$(dune exec wand -- "$sol" 2>&1)
  sol_code=$?
  if [ $sol_code -ne 0 ]; then
    cat=$(categorize "$sol_out")
    echo "FAIL        $name ($cat, in solution)"
    rows+=("$name|fail|$cat (in solution)")
    fail=$((fail + 1))
    continue
  fi

  cases_out=$(dune exec wand -- "$cases" 2>&1)
  cases_code=$?
  if [ $cases_code -eq 0 ] && ! echo "$cases_out" | grep -q "^FAIL:"; then
    echo "PASS        $name"
    rows+=("$name|pass|-")
    pass=$((pass + 1))
  else
    cat=$(categorize "$cases_out")
    echo "FAIL        $name ($cat)"
    rows+=("$name|fail|$cat")
    fail=$((fail + 1))
  fi
done

total=$((pass + fail))
echo
echo "Passed: $pass / $total scored ($skip skipped, no solution.wand)"

mkdir -p bench/results
out_file="bench/results/${label}.md"
{
  echo "# Benchmark results: $label"
  echo
  echo "Passed: $pass / $total scored ($skip skipped)"
  echo
  echo "| task | result | category |"
  echo "|---|---|---|"
  for r in "${rows[@]}"; do
    IFS='|' read -r n res cat <<< "$r"
    echo "| $n | $res | $cat |"
  done
} > "$out_file"
echo "Report written to $out_file"

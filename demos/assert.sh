# A demo is an acceptance test: it is here to make a point, and if it stops
# making it something has regressed. Printing the point is not enough --
# every one of these scripts used to end in `exit 0`, so a demo could quietly
# stop demonstrating anything and still pass CI. That is how a manifest went
# missing from the manifest demo without a single check going red.
#
# `assert <expected> <command...>` re-runs the decisive command and requires
# its output to still contain the line the demo is built around.

assert() {
  local expected="$1"; shift
  # The output is captured rather than piped: most of these commands are
  # meant to fail -- a type error is the point being demonstrated -- and
  # under `set -o pipefail` a pipeline would inherit that failure and be
  # indistinguishable from the demo having actually regressed.
  local out
  out="$("$@" 2>&1 || true)"
  if [ "${out#*"$expected"}" = "$out" ]; then
    echo >&2
    echo "DEMO REGRESSED: $(basename "$(dirname "${BASH_SOURCE[1]:-$0}")")" >&2
    echo "  expected to see: $expected" >&2
    echo "  from: $*" >&2
    exit 1
  fi
}

# The same, for a point made by a file's absence rather than by output.
assert_absent() {
  local path="$1"
  if [ -e "$path" ]; then
    echo >&2
    echo "DEMO REGRESSED: $path exists, and the demo's point is that it does not" >&2
    exit 1
  fi
}

#!/usr/bin/env bash
# Startup benchmark.
#
# Budget: `wand -e "1 + 2"` should stay within 2-3x of `bash -c ':'`. Startup
# is the tax every script pays before doing any work, and the one-shot
# commands are what an editing loop runs most, so a regression here is felt
# everywhere even though no single run looks slow.
#
# Uses hyperfine when available (better statistics, shell-spawn correction)
# and falls back to a portable sampler otherwise.
set -euo pipefail

cd "$(dirname "$0")/.."
WAND=./_build/default/bin/wand.exe

if [ ! -x "$WAND" ]; then
  echo "building..." >&2
  dune build 2>/dev/null
fi

if command -v hyperfine >/dev/null 2>&1; then
  hyperfine --warmup 5 --shell=none \
    "bash -c :" \
    "$WAND t 1 + 2" \
    "$WAND -e 1 + 2" \
    "$WAND examples/hello.wand"
else
  echo "hyperfine not found — using the built-in sampler (install hyperfine for better numbers)" >&2
  python3 - "$WAND" <<'PY'
import subprocess, sys, time, statistics
wand = sys.argv[1]
def bench(cmd, n=40):
    for _ in range(5):  # warmup
        subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    ts = []
    for _ in range(n):
        t0 = time.perf_counter()
        subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        ts.append((time.perf_counter() - t0) * 1000)
    return statistics.median(ts)

rows = [
    ("bash -c :",          ["bash", "-c", ":"]),
    ("wand t --expr '1 + 2'", [wand, "t", "--expr", "1 + 2"]),
    ("wand -e '1 + 2'",    [wand, "-e", "1 + 2"]),
    ("wand hello.wand",    [wand, "examples/hello.wand"]),
    ("wand -e List.length", [wand, "-e", "List.length [1, 2, 3]"]),
]
base = None
print(f"{'command':24} {'median':>9}   {'vs bash':>8}")
for label, cmd in rows:
    m = bench(cmd)
    if base is None:
        base = m
    print(f"{label:24} {m:6.1f} ms   {m/base:7.2f}x")
print()
print("budget: wand -e '1 + 2' within 2-3x of bash")
PY
fi

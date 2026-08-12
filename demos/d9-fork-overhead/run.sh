#!/usr/bin/env bash
# Same task four ways: count log lines by level.
#
# The point is not that one language is fastest. It is where the time goes:
# a bash pipeline hands the whole file to coreutils and is very fast, while
# a bash loop that shells out per line spends nearly all its time forking.
# wand does the work in-process, so it sits between them -- far behind a
# tight pipeline, far ahead of the loop.
set -uo pipefail
cd "$(dirname "$0")/../.."
WAND=_build/default/bin/wand.exe
D=demos/d9-fork-overhead
N=${N:-5000}
LOG=${LOG:-/tmp/wand-demo-$N.log}

[ -f "$LOG" ] || "$D/gen.sh" "$N" "$LOG" >/dev/null
echo "input: $(wc -l < "$LOG" | tr -d ' ') lines"
echo

python3 - "$WAND" "$D" "$LOG" <<'PY'
import subprocess, sys, time, statistics
wand, d, log = sys.argv[1], sys.argv[2], sys.argv[3]

runs = [
    ("bash pipelines",      ["bash", f"{d}/crunch.sh", log]),
    ("python one pass",     ["python3", f"{d}/crunch.py", log]),
    ("wand one pass",       [wand, f"{d}/crunch.wand", log]),
    ("bash per-line loop",  ["bash", f"{d}/crunch-loop.sh", log]),
]

def levels(out):
    # the loop version reports levels only; compare the shared rows
    return [l for l in out.strip().split("\n") if l.split()[0] in ("ERROR", "WARN", "INFO")]

first = None
for label, cmd in runs:
    out = subprocess.run(cmd, capture_output=True, text=True).stdout
    if first is None:
        first = levels(out)
    elif levels(out) != first:
        print(f"{label} disagrees:\n{out}")
        sys.exit(1)
print("all four agree on: " + ", ".join(first))
print()

print(f"{'implementation':22} {'median':>10}")
base = None
for label, cmd in runs:
    ts = []
    for _ in range(3):
        t0 = time.perf_counter()
        subprocess.run(cmd, stdout=subprocess.DEVNULL)
        ts.append((time.perf_counter() - t0) * 1000)
    m = statistics.median(ts)
    if base is None:
        base = m
    print(f"{label:22} {m:8.0f} ms   {m/base:5.1f}x")
PY

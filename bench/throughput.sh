#!/usr/bin/env bash
# Throughput benchmark: how evaluation scales with input size.
#
# The shape matters more than the absolute numbers. Each workload doubles in
# size, so a healthy line roughly doubles in time; anything growing faster
# than that is an algorithmic problem, not a constant factor.
set -euo pipefail

cd "$(dirname "$0")/.."
WAND=./_build/default/bin/wand.exe
[ -x "$WAND" ] || dune build 2>/dev/null

python3 - "$WAND" <<'PY'
import subprocess, sys, time, statistics, tempfile, os
wand = sys.argv[1]

def run(src, args=()):
    with tempfile.NamedTemporaryFile("w", suffix=".wand", delete=False) as fh:
        fh.write(src); path = fh.name
    try:
        ts = []
        for _ in range(3):
            t0 = time.perf_counter()
            subprocess.run([wand, path, *args], stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL)
            ts.append((time.perf_counter() - t0) * 1000)
        return statistics.median(ts)
    finally:
        os.unlink(path)

WORKLOADS = {
    # A wand-level recursive walk: every step tests the `[]` pattern against
    # the remaining list, which is where a quadratic once hid.
    "list walk (cons pattern)": lambda n: f"""import List
let walk [] = 0
let walk [_ : t] = 1 + walk t
walk (List.range 1 {n})""",
    # Tail recursion through a stdlib higher-order function.
    "fold_left": lambda n: f"""import List
List.fold_left (fn a b -> a + b) 0 (List.range 1 {n})""",
    # Non-tail recursion with no lists, as a control.
    "plain recursion": lambda n: f"""let count 0 = 0
let count n = 1 + count (n - 1)
count {n}""",
}

sizes = [5000, 10000, 20000, 40000]
baseline = run("0")
print(f"startup baseline: {baseline:.0f} ms (subtracted below)\n")
print(f"{'workload':28} " + " ".join(f"{n:>9}" for n in sizes) + "   growth")
for label, build in WORKLOADS.items():
    times = [max(run(build(n)) - baseline, 1.0) for n in sizes]
    growth = times[-1] / times[-2] if times[-2] > 0 else 0
    cells = " ".join(f"{t:7.0f}ms" for t in times)
    print(f"{label:28} {cells}   {growth:4.1f}x per 2x")
print("\nhealthy is ~2.0x per doubling")
PY

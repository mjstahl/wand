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
            p = subprocess.run([wand, path, *args], stdout=subprocess.DEVNULL,
                               stderr=subprocess.PIPE)
            ts.append((time.perf_counter() - t0) * 1000)
            # A workload that does not run is a fast workload, and reads as a
            # healthy line rather than as a broken one. The cons pattern below
            # spent a release measuring a parse error this way.
            if p.returncode != 0:
                sys.exit("workload failed:\n" + p.stderr.decode().strip())
        return statistics.median(ts)
    finally:
        os.unlink(path)

WORKLOADS = {
    # A wand-level recursive walk: every step tests the `[]` pattern against
    # the remaining list, which is where a quadratic once hid.
    "list walk (cons pattern)": lambda n: f"""import List
let walk [] = 0
let walk [_ :: t] = 1 + walk t
walk (List.range 1 {n})""",
    # Tail recursion through a stdlib higher-order function.
    "fold_left": lambda n: f"""import List
List.fold_left (fn a b -> a + b) 0 (List.range 1 {n})""",
    # Non-tail recursion with no lists, as a control.
    "plain recursion": lambda n: f"""let count 0 = 0
let count n = 1 + count (n - 1)
count {n}""",
    # The same count with nothing waiting on the call. A tail call reuses the
    # frame, so this one holds a stack of constant depth however far it goes,
    # and the line stays flat where the one above it climbs.
    "tail recursion": lambda n: f"""let go 0 acc = acc
let go n acc = go (n - 1) (acc + 1)
go {n} 0""",
}

# How lookup scales with the number of names in scope, rather than with the
# size of the input. A name is found by walking the environment, so without
# an index this grows with everything defined before it -- which is a
# different curve from the ones above and was invisible to them.
SCOPE = """let helper x = x + 1
{padding}let go 0 acc = acc
let go n acc = go (n - 1) (acc + helper n)
go 100000 0"""

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
print("'tail recursion' holds that however deep it goes -- a tail call reuses")
print("the frame. 'plain recursion' keeps a frame per level and every minor")
print("collection rescans them all, so it climbs past 2.0x once it is deep")
print("enough for that to show: around 100k, well past the sizes above.")

print()
print(f"{'names in scope before the callee':32} {'median':>9}   growth")
prev = None
for k in (0, 200, 400, 800):
    padding = "".join(f"let pad{i} = {i}\n" for i in range(k))
    ms = max(run(SCOPE.format(padding=padding)) - baseline, 1.0)
    growth = f"{ms / prev:4.1f}x" if prev else "   --"
    prev = ms
    print(f"{k:>32} {ms:7.0f}ms   {growth}")
print("\nhealthy is flat: finding a name should not cost more because a file is longer")
PY

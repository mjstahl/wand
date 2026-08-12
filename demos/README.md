# Demos

Each demo is a script you can run, not a transcript. They double as
acceptance tests: if one stops making its point, something regressed.

```
demos/d1-unset-variable/run.sh
demos/d2-domain-types/run.sh
demos/d3-typed-holes/run.sh
demos/d9-fork-overhead/run.sh      # slower: it runs a deliberately bad bash loop
```

---

## D1 — The unset variable

The oldest bug in shell scripting. `STAGING_DIR` is not set, so
`rm -rf "${STAGING_DIR}/"` expands to `rm -rf /` and runs.

wand's `Env.get` returns `Option String`, because a variable may not be set.
Written the same way, the wand version does not get as far as running:

```
Error: type error: 9:1: cannot unify String with Option String
```

The `None` case has to go somewhere. Once it does, the script says what it
will do instead of doing something catastrophic.

## D2 — Literals that know what they are

`30s` is a `Duration`, `*.wand` is a `Glob`, `10.0.0.0/24` is a `CIDR` — all
written literally, all distinct types. So the mistakes below are type errors
rather than strings that turn out to be wrong later:

```
Duration.to_ms 30        cannot unify Duration with Int
FS.glob /etc/hosts       cannot unify Glob with Path
Path.basename *.wand     cannot unify Path with Glob
```

## D3 — Ask the type system what to write

Leave `?` where you have not decided yet, and typecheck:

```
let levels = List.fold_left ? Map.empty (String.lines (IO.read_all! ()))
```

```
$ wand t "$(cat summarize.wand)"
Hole: Map 'a -> String -> Map 'a
```

That is the signature of the function to write, derived from how the hole is
used. `summarize-filled.wand` is the same script with the hole filled in.

## D9 — Where the time goes

The same task — count log lines by level — written four ways. Measured on
5,000 lines:

| implementation | median | |
|---|---|---|
| bash pipelines | 33 ms | 1.0x |
| python, one pass | 109 ms | 3.3x |
| **wand, one pass** | **203 ms** | **6.2x** |
| bash per-line loop | 22,131 ms | 670x |

Two honest readings, and they point in opposite directions.

**Against a tight pipeline, wand loses.** Handing a whole file to `grep` and
`sort` is hard to beat, and wand is currently ~6x behind that and ~2x behind
Python. The evaluator is a tree walker and has not been optimised for
throughput; the gap holds roughly steady with input size (50,000 lines:
Python 0.32 s, wand 2.29 s).

**Against a loop that shells out per line, wand wins by two orders of
magnitude** — and that is the idiom scripts actually grow into once the work
stops fitting one pipeline. The loop spends nearly all 23 seconds forking:
two processes per line, 10,000 processes for 5,000 lines. wand spawns none.

So the case for doing the work in wand is not raw speed against coreutils.
It is that the alternative, once a script outgrows a single pipeline, is
usually the loop.

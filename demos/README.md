# Demos

Each demo is a script you can run, not a transcript. They double as
acceptance tests: if one stops making its point, something regressed.

```
demos/d1-unset-variable/run.sh
demos/d2-domain-types/run.sh
demos/d3-typed-holes/run.sh
demos/d4-signatures/run.sh
demos/d5-rehearse/run.sh
demos/d6-unplugged/run.sh
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
Hole: Map 'a -> String -> Map 'a ! 'e
```

That is the signature of the function to write, derived from how the hole is
used. `summarize-filled.wand` is the same script with the hole filled in.

## D4 — The signature that cannot lie

A backup script, nothing annotated:

```
backup_all! : String -> Unit ! {FS.Read, FS.Write, Raise}
```

Someone adds one line, three helpers deep:

```
let _ = $(curl -X POST https://metrics.example.com/backup) in
```

```
backup_all! : String -> Unit ! {Shell, FS.Read, FS.Write, Raise}
```

The signature changed on its own. Nothing was annotated, and the diff that
caused it was a single line inside a helper.

Adding one line at the top of the file turns that from something you have to
notice into something that cannot compile:

```
uses {FS.Read, FS.Write}
```

```
Error: type error: 'backup_one!' performs Shell, which the manifest does not allow.
       The manifest should be:  uses {Shell, FS.Read, FS.Write}
```

## D5 — Rehearse the deploy

A deploy that builds, writes a config, syncs and purges a cache. Run it with
`--dry-run` and it reports what it would do:

```
would run: git describe --tags --always -> ""
would create directory: /tmp/wand-demo-deploy
would write: /tmp/wand-demo-deploy/config.toml (13 bytes)
would set: DEPLOYED_VERSION ->
would run: echo rsync -a ./build/ web@host:/srv/app
would write: /tmp/wand-demo-deploy/cache.idx (6 bytes)
would delete: /tmp/wand-demo-deploy/cache.idx
```

Afterwards the directory does not exist and the variable is unset. Run it for
real with `--trace` and the same seven operations happen, in the same order.

The two differ in one visible way: the rehearsal writes 13 bytes where the
real run writes 20, because a withheld command returned `""` and that steered
the contents. A rehearsal says what it substituted rather than pretending the
values were real — it cannot rehearse a read of something it did not write.

## D6 — Unit-test a deploy with the network unplugged

```
deploy! : Unit -> String ! {Shell, FS.Write, Raise}
```

It runs `git push` and rewrites `/etc/app/config.toml`. Nothing about it is
written for testability. Its suite:

```
ok   it runs, on a plane
ok   it pushes exactly once
ok   and nothing before the push touches prod
ok   it would write exactly one file
ok   which was never written
```

The assertions are about what the script *attempted*, not only what it
returned — the commands it would run, in order, and the paths it would write.
The last line checks the file is still absent.

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

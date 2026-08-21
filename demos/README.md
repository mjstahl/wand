# Demos

Each demo is a script you can run, not a transcript. They double as
acceptance tests: if one stops making its point, something regressed.

```
demos/01-unset-variable/run.sh
demos/02-domain-types/run.sh
demos/03-typed-holes/run.sh
demos/04-signatures/run.sh
demos/05-rehearse/run.sh
demos/06-unplugged/run.sh
demos/07-jq-typed/run.sh
demos/08-fan-out/run.sh
demos/09-fork-overhead/run.sh      # ~1½ minutes: it runs a deliberately bad bash loop
                                   # N=500 demos/09-fork-overhead/run.sh takes ten seconds
demos/10-streams/run.sh
```

---

## 01 — The unset variable

The oldest bug in shell scripting. `STAGING_DIR` is not set, so
`rm -rf "${STAGING_DIR}/"` expands to `rm -rf /` and runs.

wand's `Env.get` returns `Option String`, because a variable may not be set.
Written the same way, the wand version does not get as far as running:

```
Error: type error: 9:1: expected String, got Option String
```

The `None` case has to go somewhere. Once it does, the script says what it
will do instead of doing something catastrophic.

## 02 — Literals that know what they are

`30s` is a `Duration`, `*.wand` is a `Glob`, `10.0.0.0/24` is a `CIDR` — all
written literally, all distinct types. So the mistakes below are type errors
rather than strings that turn out to be wrong later:

```
Duration.to_ms 30        expected Duration, got Int
FS.glob /etc/hosts       expected Glob, got Path
Path.basename *.wand     expected Path, got Glob
```

## 03 — Ask the type system what to write

Leave `?` where you have not decided yet, and typecheck:

```
let levels = Stream.fold_left ? Map.empty (IO.stdin_lines ())
```

```
$ wand t --file summarize.wand
Hole: Map 'a -> String -> Map 'a ! {IO, Raise | 'e}
```

That is the signature of the function to write, derived from how the hole is
used. `summarize-filled.wand` is the same script with the hole filled in.

## 04 — The signature that cannot lie

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
       The manifest should be:  "uses {Shell(curl), FS.Read, FS.Write}"
```

## 05 — Rehearse the deploy

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

## 06 — Unit-test a deploy with the network unplugged

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

## 07 — jq, typed

Which pods are restarting too often? Through jq and awk:

```
jq -r ".items[] | [.metadata.name, ([.status.containerStatuses[].restartCount] | add)] | @tsv" pods.json \
  | awk -F'\t' '$2 > 3 { printf "  %-12s %s\n", $1, $2 }'
```

Through a type — and nothing writes a decoder, because a type with named
fields already has one:

```
type Container (name : String, restartCount : Int, ready : Bool)
type Status (phase : String, containerStatuses : List Container)
type Meta (name : String, namespace : String)
type Pod (metadata : Meta, status : Status)
```

Both report the same three pods. Then the field name is got wrong — first by
typing it wrong, then by leaving the code alone and letting the cluster
rename it:

```
  jq: 0 pods reported, exit 0
  wand: constructor 'Container' has no field 'restartCount' (did you mean 'restartCnt'?)

  jq: 0 pods reported, exit 0
  wand: .items[0].status.containerStatuses[0].restartCount: no such field
```

The silence is the point. jq does not fail on a field that is not there — it
produces null, awk compares null to 3, and the pipeline reports that nothing
is crashlooping and exits 0. In the document it just read, `db-01` is in
CrashLoopBackOff with twelve restarts.

The two wand failures are two different guards. The typo never runs at all:
the field is named in a type, so the code that reads it stops compiling. The
renamed field does run, because the code is consistent with itself and only
the document disagrees — that one fails at the boundary where the document
is read, and says which field, in which container, of which pod.

## 08 — Fan out without fear

Twenty hosts, checked eight at a time, three of them unreachable. Every check
takes a lease before it starts and gives it back when it is done, so what the
run is holding can be counted from outside it.

```
Par.map 8 check! hosts
```

A host that fails does not take the run down with it, and the answers come
back in the order they were asked, not the order they arrived:

```
  ok    web-03  ok
  FAIL  web-04  command exited with code 1: demos/08-fan-out/probe.sh web-04
  ok    web-05  ok

17 reachable, 3 not, and none of it fatal
leases still held: 0
```

Then the same run, interrupted halfway through:

```
  in flight: 8 leases, 8 probes
  ^C
  exit 130
  leases still held: 0
  probes still running: 0
```

Eight workers were mid-check on their own domains. Each released what it was
holding, the commands they had started were stopped, and the script exited
130 the way a shell reports an interrupt.

The bash version is written the way this is written — `xargs -P 8` for the
concurrency, a `trap` for the cleanup, a temp file to collect results — and
its trap does run:

```
  in flight: 8 leases, 8 probes
  ^C
  exit 1
  leases still held: 8
```

The trap removed the results file, because that is what the parent owns. The
eight leases belong to eight other processes, and a trap here does not run
there. That is the difference: not that bash forgot to clean up, but that the
cleanup and the thing to be cleaned up are in different processes. A `with`
puts them in the same one.

## 09 — Where the time goes

The same task — count log lines by level — written four ways. Measured on
5,000 lines:

| implementation | median | |
|---|---|---|
| bash pipelines | 38 ms | 1.0x |
| **wand, one pass** | **41 ms** | **1.1x** |
| python, one pass | 138 ms | 3.7x |
| bash per-line loop | 25,669 ms | 679x |

**Against a tight pipeline, wand now draws.** Handing a whole file to `grep`
and `sort` is hard to beat, and for a while wand was ~6x behind it and ~2x
behind Python. What closed the gap was not the pipeline getting slower: this
workload calls a handful of stdlib functions per line, and finding each of
those names used to mean walking the whole environment. Indexing that walk
took the same run from 97 ms to 43 ms.

**Against a loop that shells out per line, wand wins by nearly three orders
of magnitude** — and that is the idiom scripts actually grow into once the
work stops fitting one pipeline. The loop spends nearly all 25 seconds
forking: two processes per line, 10,000 processes for 5,000 lines. wand
spawns none.

So the case for doing the work in wand no longer needs the second argument.
It is as fast as the pipeline, and the alternative once a script outgrows a
single pipeline is usually the loop.

## 10 — Read through, not in

A stream reads nothing until the fold runs it: the fold opens the file,
reads a line at a time, and closes on the way out. Two claims are on
trial.

**A file folds in bounded memory.** A million generated lines, counted
without holding them:

```
FS.stream_lines log
|> Stream.filter (fn l -> String.contains? "ERROR" l)
|> Stream.fold_left (fn n _ -> n + 1) 0
```

**`take` stops the reading** — proved on a source that never ends. The
second script streams a fifo whose writer loops forever, takes five
lines, and returns. If `take` did not stop the pulling, it would never
come back:

```
FS.stream_lines source |> Stream.take 5 |> Stream.each IO.println
```

Run `demos/10-streams/run.sh`.

# wand

A typed ML-style scripting language for Human-AI collaboration.

wand is for the scripts that outgrew bash — deploys, CI glue, cron jobs, log
munging — where a mistake is expensive and the person reading the diff is not
the person who wrote it.

> A script that an AI wrote is read differently from one a person wrote:
> nobody has been through it line by line. So wand puts the blast radius on
> the first line. `uses {Shell, FS.Write}` is checked against the code — a
> manifest that does not cover what the script does is a type error, and a
> script with no manifest is told the row it would need. `wand t` runs that
> check without running the script, which is a job CI already knows how to
> do, and `--dry-run` rehearses the effects first: *would write*, *would
> delete*, *would run*, before anything does.
>
> The manifest is worth reading because the language does not leak underneath
> it. Values interpolated into a shell command are quoted, so a filename from
> `Env.get` or a line from a log cannot decide what runs. Effects cross
> function boundaries in the type, so a helper five calls down cannot reach
> the network without the row at the top saying so. The claim is narrow and
> deliberate: not that a script is correct, but that it cannot do anything it
> did not admit to.

**[Language reference →](docs/reference.md)**

---

## Values that know what they are

Paths, globs, durations, sizes, URLs, dates and addresses are written
literally and typed distinctly — so mixing them up is a type error, not a
malformed string discovered at 3am.

```
let timeout  = 30s               -- Duration
let log_dir  = /var/log/app      -- Path
let sources  = *.wand            -- Glob
let limit    = 100MB             -- Size
let server   = https://api.example.com

FS.glob log_dir                  -- type error: expected Glob, got Path
```

## Failure is a value, absence is a type

Fallible operations return a `Result` carrying the reason; things that may
simply not be there return an `Option`. Every fallible operation has a `!`
sibling that raises instead, so the risk is legible at the call site.

```
match FS.read_file "config.toml" with
| Ok text -> text
| Error why -> "using defaults (${why})"

FS.read_file! "config.toml"     -- raises; the name says so
Env.get "HOME"                  -- Option String, not "" when unset
```

## Keeps the shell, without keeping its footguns

```
let branch = $(git branch --show-current)
let dirty  = $(git status --porcelain) |> String.lines |> List.length
```

`$()` raises on a non-zero exit; `$?()` hands back a `ShellResult` to inspect.
Work moved out of `$()` and into wand gets typed — and faster, since it stops
forking a process per stage.

## Sketch it and ask the type system

Write `?` where you are unsure and typecheck. wand answers with what belongs
there, instead of only complaining about what doesn't.

```
$ wand t 'List.fold_left ? 0 [1, 2, 3]'
Hole: Int -> Int -> Int ! 'e
```

## Test a deploy script without deploying anything

`handle` intercepts the effects a script performs, so the risky parts can be
exercised with the network unplugged.

```
test "deploy pushes exactly once" (fn t ->
  handle deploy () with
  | Shell!run _ k -> k "ok")
```

---

## Install and run

```
dune build
dune exec wand -- script.wand
```

```
wand script.wand        # run a script
wand i                  # interactive session
wand e "1 + 2"          # evaluate an expression
wand t "1 + 2"          # typecheck, report holes, and lint
wand d "List.map"       # show a doc string
wand fmt script.wand    # format in place
wand test               # run every test_*.wand from here down
wand h                  # help
```

Requires OCaml 5.x and opam.

---

## Demos

Runnable, in [`demos/`](demos/):

- **[The unset variable](demos/d1-unset-variable/)** — `rm -rf "${STAGING_DIR}/"` expands to `rm -rf /` in bash; the wand version does not typecheck until the missing case is answered
- **[Literals that know what they are](demos/d2-domain-types/)** — `Duration.to_ms 30` and `FS.glob /etc/hosts` are type errors
- **[Ask the type system what to write](demos/d3-typed-holes/)** — leave `?`, get back the signature that belongs there
- **[The signature that cannot lie](demos/d4-signatures/)** — one line added three helpers deep changes the signature; a manifest turns that into a compile error
- **[Rehearse the deploy](demos/d5-rehearse/)** — `--dry-run` reports what a deploy would do, touches nothing, then the real run matches
- **[Unit-test a deploy with the network unplugged](demos/d6-unplugged/)** — a script that pushes to production, fully tested, pushing nothing
- **[Where the time goes](demos/d9-fork-overhead/)** — the same task in bash, Python and wand, and what forking per line costs

---

## Status

Early. The language runs, the standard library is written in wand, and the
test suite covers the lexer, parser, typechecker, formatter, and CLI. Expect
sharp edges and breaking changes.

- **[Language reference](docs/reference.md)** — the full language
- **[Examples](examples/)** — runnable scripts, executed by CI

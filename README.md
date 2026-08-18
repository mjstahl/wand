# wand

A typed ML-style scripting language for Human-AI collaboration.

wand is for the scripts that outgrew bash — deploys, CI glue, cron jobs, log
munging — where a mistake is expensive and the person reading the diff is not
the person who wrote it.

> An AI can write a script faster than anyone will read it. So a wand script
> declares what it touches on its first line — `uses {FS.Write, Shell(git)}` — and
> the compiler checks the declaration against the code. Declare too little and
> it does not typecheck. Declare nothing and wand prints the line to add.
> `wand t` runs the check without executing the script. `--dry-run` prints
> what a run would do: *would write*, *would delete*, *would run*.
>
> The declaration cannot be worked around. A value interpolated into a shell
> command is quoted, so a filename from an environment variable cannot become
> a second command. A function that shells out five calls down still needs the
> first line to allow it. wand does not check that a script is correct, only
> that it cannot do what it did not declare.

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
| Error why -> "using defaults (%{why})"

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

**In GitHub Actions** — one step, with checksum verification and tool-cache
reuse ([mjstahl/setup-wand](https://github.com/mjstahl/setup-wand)):

```yaml
- uses: mjstahl/setup-wand@v1
- run: wand ci/deploy.wand
```

**On a laptop** — one line, no sudo. Detects the platform, verifies the
checksum, proves the binary answers, and installs to `~/.local/bin`
(`WAND_VERSION` pins a release, `WAND_INSTALL_DIR` picks the directory):

```
curl -fsSL https://raw.githubusercontent.com/mjstahl/wand/main/install.sh | sh
```

**A release binary, by hand** — every
[release](https://github.com/mjstahl/wand/releases) ships static Linux
builds (x86_64, aarch64) and macOS builds (aarch64, x86_64), each with a
`.sha256` alongside:

```
curl -fsSLO https://github.com/mjstahl/wand/releases/download/v0.10.0/wand-0.10.0-macos-aarch64.tar.gz
tar xzf wand-0.10.0-macos-aarch64.tar.gz
install wand-0.10.0-macos-aarch64/wand ~/.local/bin/
```

The binary carries its own standard library; there is nothing else to
install. Startup stays out of the way of CI glue and editing loops: the
release binary runs `wand e "1 + 2"` in ~9 ms median (~1.6× `bash -c :`,
macOS x86_64) — `bench/startup.sh` reproduces the measurement.

**From source** — the contributor path. Requires OCaml 5.x and opam:

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

---

## Demos

Runnable, in [`demos/`](demos/):

- **[The unset variable](demos/d1-unset-variable/)** — `rm -rf "%{STAGING_DIR}/"` expands to `rm -rf /` in bash; the wand version does not typecheck until the missing case is answered
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

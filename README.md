# wand

A typed, ML-style scripting language for human-AI collaboration.

Use wand for the scripts that outgrew bash: deploys, CI glue, cron jobs, log
processing. A mistake in these scripts is expensive. The person who reads the
diff is not the person who wrote it.

## The first line declares what a script touches

An AI writes a script faster than a person reads it. So a wand script declares
what it touches on its first line:

```
uses {FS.Write, Shell(git)}
```

The compiler compares the declaration with the code. If the file declares too
little, it does not typecheck. If it declares nothing, wand prints the line to
add. `wand t` makes the check and does not run the script. `--dry-run` prints
what a run does: *would write*, *would delete*, *would run*.

A script cannot get around the declaration. wand quotes each value that goes
into a shell command. A filename from the environment cannot become a second
command. A function that runs a command five calls down still needs the first
line to permit it. wand does not check that a script is correct. It checks that
a script cannot do what it did not declare.

**[Language reference →](docs/reference.md)**

---

## Values carry their type

Paths, globs, durations, sizes, URLs, dates and addresses have literals of their
own. Each one has its own type. Use one where another belongs, and you get a
type error.

```
let timeout  = 30s               -- Duration
let log_dir  = /var/log/app      -- Path
let sources  = *.wand            -- Glob
let limit    = 100MB             -- Size
let server   = https://api.example.com

FS.glob log_dir                  -- type error: cannot unify Glob with Path
```

## Failure is a value. Absence is a type

An operation that can fail returns a `Result` with the reason. An operation
whose value can be absent returns an `Option`. Each fallible operation has a `!`
sibling that raises instead. The name shows the risk at the call site.

```
match FS.read_file "config.toml" with
| Ok text -> text
| Error why -> "using defaults (%{why})"

FS.read_file! "config.toml"     -- raises; the name says so
Env.get "HOME"                  -- Option String, not "" when unset
```

## Shell commands, without the shell traps

```
let branch = $(git branch --show-current)
let dirty  = $(git status --porcelain) |> String.lines |> List.length
```

`$()` raises if the command exits non-zero. `$?()` returns a `ShellResult` to
examine. Work that moves out of `$()` and into wand gets a type. It also runs
faster, because wand does not fork a process for each stage.

## Ask the type system what fits

Write `?` where you do not know what belongs, then typecheck. wand answers with
the type of the hole.

```
$ wand t 'List.fold_left ? 0 [1, 2, 3]'
Hole: Int -> Int -> Int ! 'e
```

## Test a deploy script that deploys nothing

`handle` intercepts the effects that a script performs. You can test the risky
parts with the network disconnected.

```
test "deploy pushes exactly once" (fn t ->
  handle deploy () with
  | Shell!run _ k -> k "ok")
```

---

## Install and run

**In GitHub Actions.** One step. It verifies the checksum and reuses the tool
cache. See [mjstahl/setup-wand](https://github.com/mjstahl/setup-wand):

```yaml
- uses: mjstahl/setup-wand@v1
- run: wand ci/deploy.wand
```

**On a laptop.** One line, and no sudo. The script finds the platform, verifies
the checksum, runs the binary once, and installs it in `~/.local/bin`. Set
`WAND_VERSION` to pin a release. Set `WAND_INSTALL_DIR` to choose the
directory:

```
curl -fsSL https://raw.githubusercontent.com/mjstahl/wand/main/install.sh | sh
```

**A release binary, by hand.** Each
[release](https://github.com/mjstahl/wand/releases) has static Linux builds
(x86_64, aarch64) and macOS builds (aarch64, x86_64). Each build has a
`.sha256` file beside it:

```
curl -fsSLO https://github.com/mjstahl/wand/releases/download/v0.22.0/wand-0.22.0-macos-aarch64.tar.gz
tar xzf wand-0.22.0-macos-aarch64.tar.gz
install wand-0.22.0-macos-aarch64/wand ~/.local/bin/
```

The binary holds its own standard library. You install nothing else. Startup is
short enough for CI glue and for an editing loop. The release binary runs
`wand e "1 + 2"` in about 9 ms on macOS x86_64. That is about 2 times
`bash -c :`. `bench/startup.sh` repeats the measurement.

**From source.** This is the contributor path. It needs OCaml 5.x and opam:

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
wand f script.wand      # format in place
wand s                  # run every test_*.wand from here down
wand h                  # help
```

---

## Demos

Each demo runs. They are in [`demos/`](demos/):

- **[The unset variable](demos/01-unset-variable/)** — `rm -rf "%{STAGING_DIR}/"` becomes `rm -rf /` in bash. The wand version does not typecheck until you answer the missing case
- **[Literals carry their type](demos/02-domain-types/)** — `Duration.to_ms 30` and `FS.glob /etc/hosts` are type errors
- **[Ask the type system what to write](demos/03-typed-holes/)** — write `?`, and get back the signature that fits
- **[A signature cannot lie](demos/04-signatures/)** — one line, added three helpers deep, changes the signature. A manifest makes that a compile error
- **[Rehearse the deploy](demos/05-rehearse/)** — `--dry-run` reports what a deploy does and touches nothing. The real run then matches the report
- **[Test a deploy with the network disconnected](demos/06-unplugged/)** — a script that pushes to production, fully tested, and it pushes nothing
- **[jq, typed](demos/07-jq-typed/)** — one question asked of a JSON document two ways: through jq and awk, and through a type that reads itself
- **[Fan out safely](demos/08-fan-out/)** — twenty hosts, eight at a time, three of them unreachable. You can count what the run holds from outside it
- **[Where the time goes](demos/09-fork-overhead/)** — the same task in bash, Python and wand, and the cost of one fork per line
- **[Read through a file, not into it](demos/10-streams/)** — a million lines counted in bounded memory. `take` stops a source that does not end

---

## Status

Early. The language runs. The standard library is written in wand. The test
suite covers the lexer, parser, typechecker, formatter and CLI. Expect sharp
edges and breaking changes.

- **[Language reference](docs/reference.md)** — the full language
- **[Reading a command line](docs/examples-args.md)** — six ways to read argv, and what each one prints
- **[Examples](examples/)** — scripts that run, and that CI runs

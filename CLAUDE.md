# CLAUDE.md

**wand** — a typed ML-style scripting language built as a bash replacement,
designed for Human-AI collaboration. The implementation is OCaml, built with
Dune. `docs/reference.md` is the complete language reference; `README.md` is
the pitch.

Two kinds of work happen here. **Part A** is for changing the compiler
(OCaml). **Part B** is for writing `.wand` code — scripts, stdlib, tests,
examples. Most tasks need only one part.

---

## Part A — working on the compiler (OCaml)

### Layout

- `bin/wand.ml` — the CLI: dispatch for `e`/`t`/`i`/`d`/`v`/`f`/`s`, running a script by path, flags like `--dry-run` and `--trace`.
- `lib/` — the pipeline, one stage per module:
  - `token.ml`, `lexer.ml` — tokens and lexing, including domain literals (paths, globs, durations, sizes) and the string/command interpolation forms.
  - `parser.ml`, `ast.ml` — recursive-descent parser. Newlines end statements only at bracket depth 0; a definition ends at the end of its line.
  - `typechecker.ml`, `effect_set.ml` — Hindley-Milner inference extended with effect sets (the eight labels below); manifests are checked against inferred effects here.
  - `evaluator.ml` — tree-walking interpreter; effect handlers, `Par`, signals, shell execution.
  - `lint.ml`, `lint_rules.ml` — the `V-*`/`A-*` rules `wand t` reports.
  - `formatter.ml` — `wand f`; comments are never dropped or restyled.
  - `runner.ml` — the public API (`Runner.run_string`, `typecheck_file`, sessions); `repl.ml`; `compile_cache.ml`; `module_types.ml`; `util.ml`.
- `stdlib/*.wand` — the standard library, written in wand, embedded into the binary at build time by `tools/gen_stdlib_embed.ml`.
- `test/` — Alcotest suites (`test_*.ml`, one per area) plus `test/wand/*.wand`, which are wand-language tests run by `wand s`.
- `tools/check_fmt.wand` — CI gate that `stdlib/`, `test/wand/` and `examples/` are formatter fixed points. Run it locally as shown below.
- `.github/workflows/ci.yml` builds and tests on push/PR; `release.yml` builds release archives when a tag lands.
- `bench/startup.sh`, `bench/throughput.sh` — the numbers the startup-path rule below asks for.

### Verifying a change

Check by exit code, never by reading output. `dune build @runtest 2>&1 | grep
-c "\[FAIL\]"` reports clean when nothing ran, and `set -e` does not abort a
`cmd; echo ok` sequence under zsh.

```bash
dune build                                            # exit code
dune build @runtest --force                           # exit code
dune exec test/test_parser.exe                        # one OCaml suite
_build/default/bin/wand.exe s test/wand               # the wand-level tests
for d in demos/0[1-8]-* demos/10-*; do $d/run.sh; done # each exit code
N=500 demos/09-fork-overhead/run.sh                   # ten seconds
WAND=$PWD/_build/default/bin/wand.exe \
  $PWD/_build/default/bin/wand.exe tools/check_fmt.wand
dune build @fmt                                       # dune files
```

Changing `lib/formatter.ml` needs more: the formatter has produced source
that does not parse, so check that the corpus (stdlib + examples) is still a
fixed point *and* still runs. `wand f` writes in place, so run it on a copy.

Changing anything on the startup path gets before-and-after numbers in the
commit message, from several runs. Readings move ~15% between runs, so one
reading cannot tell an improvement from noise.

### Releasing

`VERSION` holds the number, and it is bumped in the commit that warrants it
rather than at release time — otherwise a build from `main` claims to be the
last release while behaving differently.

```bash
make release VERSION=0.6.0          # tags, pushes, builds the macOS x86_64
                                    # archive, attaches it
gh release edit v0.6.0 --draft=false
```

CI builds the other three archives when the tag lands. Both sides create the
release if it is missing, so they can finish in either order, and it stays a
draft until someone publishes it. `make release` refuses a tag that `VERSION`
disagrees with.

---

## Part B — writing wand code

### The loop

Write the script, then let the tools drive the edits:

```bash
wand t --file script.wand        # typecheck a file (wand t "expr" for a snippet)
wand t --fix --file script.wand  # apply the fixes findings carry (manifest lines, dead imports)
wand f script.wand               # format in place
wand s                           # run every test_*.wand from here down
wand --dry-run script.wand       # report what it would change, without doing it
wand script.wand                 # the real run
```

Never write effect annotations by hand. `wand t` tells you the manifest line
to add, and `wand t --fix` applies it (with any other carried fixes) in
place. `--dry-run` comes before any real run of a script that writes or
deploys.

### Manifest and effects

The first line of a file that touches the world declares what it may do:

```
uses {Env, FS.Read, FS.Write, IO, Shell(curl, git)}
```

Those are five of the eight effect labels: `Shell` (subprocesses),
`FS.Read`, `FS.Write`, `Env`, `IO` (own streams), `Proc` (exits), `Raise`,
`Clock` (waits).
`Shell` may name the binaries the file runs — written as they are in
`$()`: `Shell(./probe.sh, docker-compose, git)` — and bare `Shell` means
any. A literal command word the list omits is a type error; a word decided
at run time is checked at spawn and flagged by `V-SHELL1`. Doing more than
the manifest says is a type error; declaring more than the file does is an
`A-USES1` warning. Effects are inferred — never annotated: `wand t`
suggests the exact manifest line, narrowed when it can read every command
word.

### Syntax card

The forms below are wand's; the parenthetical is the drift to avoid.

| wand | not |
|---|---|
| `-- comment`, and a run of them above a definition is its doc | `//`, `#`, `(* block *)` |
| `fn x -> x + 1` | `fun`, `\x ->`, `lambda` |
| `h :: t` cons, `[h :: t]` in patterns | `:` for cons, `(x : xs)` |
| `"hi %{name}"` interpolation | `${x}`, `#{x}`, f-strings |
| `&&`, `\|\|`, `!` | `and`, `or`, `not` |
| `let f n = ...` (already recursive) | `let rec` |
| `{a = 1}` map; `{a, b = x}` pattern (puns) | `{a: 1}`, `[a = 1]` |
| `T(r, b = 3)` record update | `{r with b = 3}` |
| `type Shape = Circle Int \| Rect Int Int` | `Circle of Int` |
| `try e` yields a `Result` | `try ... with`, `raise` |
| no mutation — bind a new name | `ref`, `mutable`, `:=` |

Arithmetic (`+ - * /`) works on `Int` and `Float` alike — one numeric
type per expression, never mixed implicitly (`Float.of_int` /
`Float.round` convert); `%` is `Int`-only; `Num` in a signature means
"`Int` or `Float`, decided at use". `+` and `-` also add two `Size`s or
two `Duration`s (`Add` in a signature); `*` and `/` do not.

Statements: one per line at the top level, nothing else needed. Inside a
function body, sequence with `;` in parentheses:

```
let deploy! target = (
  FS.mkdir! (Path.of_string target);
  FS.write_file! (Path.of_string "%{target}/v") "1\n";
  "deployed"
)
```

`let x = e in body` names a value for `body` — use it for naming, not
sequencing. Prefer one `match` over multi-equation definitions. Pattern
matching must be exhaustive or it is a type error.

### Domain literals

Values are written directly; the shape carries the type:

| literal | type |
|---|---|
| `/etc/hosts`, `./build`, `~/x` | Path |
| `*.wand`, `./file*.txt` | Glob — a *relative* glob with a directory part needs the `./` prefix |
| `30s`, `5min`, `2h` | Duration |
| `100MB`, `4KB` | Size |
| `2024-01-15`, `14:30:00` | Date, Time |
| `https://example.com` | Url |
| `192.168.1.1`, `10.0.0.0/8` | IPv4, CIDR |
| `:8080` | Port |
| `1.2.3` | Version |
| `r/pat/i` | Regex |

### Shell

- `$(git status)` runs a command, raises on failure, yields the trimmed stdout `String`.
- `$?(cmd)` yields a `ShellResult` for inspecting exit code/stderr instead of raising.
- Inside a command, `%{x}` splices a value quoted as one argument — use it for data. `%!{x}` splices text to be read *as shell source* — only for text that is deliberately shell (a flag string, a pipeline fragment).
- `report |> $?(mail ops@example.com)` pipes the left value to the command's stdin.
- Parse captures with `Shell.lines`, `Shell.decode` — not by hand.

### Names and errors

- Fallible operations return `Result`/`Option`; every one has a raising sibling named with `!` (`FS.copy` returns a `Result`, `FS.copy!` raises). A function you write that can raise gets a `!` name too; predicates end in `?` (`failed?`).
- Handle a `Result` by matching it, or `try f x` to capture a raise as a `Result`. Discarding a `Result` silently is a `V-DROP1` warning; bind it to `_` only when the failure genuinely does not matter.
- A typed hole `?` asks the typechecker what belongs there: `List.fold_left ? Map.empty xs`, then `wand t` reports the hole's type.

### Imports and tests

```
import FS                       -- a stdlib module
let {test} = import Test        -- destructure specific names
let {helper} = import ./util    -- another file, by path
```

Stdlib modules: List, String, Regex, Map, FS, Resource, Stream, Path, IO,
Float, Proc, Env, CSV, JSON, TOML, Duration, Clock, Par, Shell, Decode,
Args, Test, Option. Every function comes from a module: printing is
`IO.println`, and a file that prints writes `import IO`.

Big files stream instead of loading: `FS.stream_lines log |>
Stream.filter p |> Stream.fold_left f init` — a stream reads nothing
until the fold runs it (folding again re-reads), and a missing file
raises at the fold, caught with `try`.

Tests are wand files named `test_*.wand`:

```
let {test, group} = import Test
test "it adds" (fn t -> t.eq 3 (1 + 2))
test "it raises" (fn t -> t.raises (fn () -> List.head! []))
group "shared" (fn () -> let n = 6 * 7 in [test "n" (fn t -> t.eq 42 n)])
```

`group` children share the body's bindings and print under the group's
label (`shared / n`); groups nest. Setup is the code above the child
list, teardown a `with` bracket around it — no other lifecycle exists.

Cleanup uses `with r as x -> body` (released however the body ends);
parallelism is `Par.map`; JSON decoding derives from type definitions
(see the reference's Decoders section).

For anything not covered here, read `docs/reference.md` — including its
"Style for scripts" section, which names the dialect `examples/` and
`demos/` are written in.

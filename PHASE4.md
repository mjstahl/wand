# Phase 4 — Reach

**Status:** not started · **Goal:** a wand binary that works where it is put,
and a script that can be handed to a machine with no wand on it.

Phases 1–3 made a script honest about what it does and pleasant to write.
None of that matters on a box that cannot run it. This phase is about the
artifact rather than the language: the binary stops depending on the
directory it is run from, and a script becomes something you can copy.

Two of the items below are not features. They are bugs with a distribution
consequence, which is why they go first.

## The gap, measured

| | |
|---|---|
| The binary is not relocatable | `cd /tmp && wand e 'List.length [1,2]'` fails. The standard library is found by walking up from the working directory looking for `stdlib/`, so wand only works inside a tree that happens to contain one. |
| Its standard library is hijackable | A directory named `stdlib/` above the working directory *is* the standard library. `mkdir stdlib && echo 'let length x = "not wand"' > stdlib/List.wand` makes `List.length [1,2]` return `"not wand"`. Arbitrary code, loaded because a folder had the right name, in the language whose pitch is that a script cannot lie about what it does. |
| A script cannot be handed over | There is no way to give someone a script that runs without installing wand first. This is the moat that killed every previous bash replacement. |
| No release artifacts | CI builds and tests; it publishes nothing. There is no way to install wand except by building it. |
| Size | The binary is **3.8 MB**, not the ~10 MB the roadmap assumed. The stdlib is 19 files and **34 KB** — under 1% of it. Nothing here needs shrinking. |
| Startup | `wand e '1 + 2'` takes **~9 ms** against bash's ~5 ms — 1.75–1.89× over three runs, inside the 2–3× budget. Quote the milliseconds, not the ratio: most of bash's 5 ms is process creation and linking rather than bash, so the number that means anything is the **~4 ms difference**, which is wand's own startup. A single noisier run gave 10.7 ms and 2.05×, which is how much these move. |
| What that 4 ms is | Building the builtin environment, then walking up from the working directory for `stdlib/` and reading whatever modules the input mentions. One stdlib module costs ~2 ms today (`wand e 'List.length'` is ~11 ms against `wand e '1 + 2'`'s ~9). That is the part embedding can take. |

## Decisions

| Question | Decision |
|---|---|
| Embed sources or precompiled ASTs? | **Sources.** A `Marshal`'d AST is tied to the compiler that wrote it and to our own type definitions, so it turns every refactor into a format migration. The stdlib is 34 KB of text; parsing it is 1–2 ms and the compile cache already covers the repeat cost. Precompiled ASTs are a later optimisation, taken only if a measurement asks for it. |
| How to embed | **A dune rule generating an OCaml module**, not a new dependency. `ocaml-crunch` does exactly this and is one `depends` line, but it is a build-time dependency for turning 19 files into string constants, which is a rule we can read in full. Keep the dependency list at five. |
| Lookup order | Embedded table first, `WAND_STDLIB` before it as an explicit override. Nothing else. `find_stdlib_dir` and its upward walk are deleted, which is what removes the hijack. |
| `WAND_STDLIB` after embedding | **Kept**, as a development override: run a built binary against a working-tree stdlib. It stops being how the stdlib is normally found and becomes how you replace it on purpose. |
| `wand compile` architecture | **Appended payload**, as the roadmap decided: a byte copy of the runtime with the script and the transitive closure of its *user* modules appended, plus a trailer holding a magic number and a length. At startup the runtime checks its own tail and runs the payload if there is one. No toolchain on the user's machine. |
| What the payload contains | Source text, keyed by module path, plus the entry script — the same table shape as the embedded stdlib, so one loader serves both. |
| Manifest stamping | `wand compile` typechecks, then stamps the inferred effect row into the payload. `./deploy --manifest` prints `uses {Shell, FS.Write}` without running anything. An artifact that states its own blast radius is the point of the whole exercise. |

## Working rules

1. Each tranche leaves the tree green: build, both suites, nine demos, `wand fmt` a fixed point.
2. The binary must keep working from inside the source tree at every step. Development is done with this binary; if it breaks, everything stops.
3. Anything that changes startup gets `bench/startup.sh` run before and after, in the same commit message — several runs, quoting milliseconds. The ratio to bash moves by 15% between runs on an idle machine, so a single reading cannot tell an improvement from noise.

## P4.1 — Stdlib embedding

Delete the filesystem search. A dune rule turns `stdlib/*.wand` into a
generated module holding `(name, source)` pairs; the loader consults it
before anything else, and `WAND_STDLIB` overrides it.

The rule must depend on the `.wand` sources so that editing the stdlib
rebuilds the table — otherwise a developer edits `List.wand`, sees no change,
and loses an hour.

*Accept:* `cd /tmp && wand e 'List.length [1,2]'` prints `2`; a directory
named `stdlib/` next to the working directory changes nothing; `WAND_STDLIB`
still replaces the library wholesale; `find_stdlib_dir` no longer exists;
`wand e '1 + 2'` no slower than ~9 ms and `wand e 'List.length'` faster than
its ~11 ms, both read from `bench/startup.sh` over several runs rather than
one.

## P4.2 — `wand compile`

```
wand compile deploy.wand -o deploy
./deploy                 # runs, with no wand installed
./deploy --manifest      # uses {Shell, FS.Write}
```

Copy the running binary, append the payload, write a trailer. At startup,
read the trailer; if the magic is there, run the payload instead of parsing
argv as usual.

Finding our own executable is the first problem: `Sys.executable_name` is not
reliable when the program was found on `PATH`, and a wrong answer here copies
the wrong file. Read `/proc/self/exe` where it exists, fall back to
`Sys.executable_name`, and fail loudly rather than copying something else.

*Accept:* a compiled script runs on a machine with no wand and no stdlib
directory; it reports its own manifest without executing; compiling a script
whose imports do not typecheck fails at compile time, not at run time.

## P4.3 — Reading arguments

`Env.args () : List String` is all a script has. That is enough for the one
positional path `demos/d9-fork-overhead/crunch.wand` takes, and it is the
whole corpus's usage today -- but `wand compile` turns scripts into
executables people invoke with flags, so the need arrives with it.

**Arguments are another untyped boundary**, which the language already has
one blessed way to read. Presented as an object, argv decodes with what
exists -- every combinator, every domain reader, derivation, and the error
that names the field:

```
deploy --port=8080 --timeout=30s --config=./app.toml

type Opts (port : Port, timeout : Duration, config : Path)
Args.parse Opts.decoder (Env.args ())
                       -- Ok (Opts (port = :8080, timeout = 30s, config = ./app.toml))
                       -- Error .port: expected Port, got "http"
```

That was tried before writing this: hand the derived decoder an object shaped
like those flags and it already works. So the only open question is how argv
becomes the object.

### The options, costed

| | What it is | Cost | What it cannot do |
|---|---|---|---|
| **A. An argv backend for `Decode`** | One builtin turning argv into an object, plus a wand wrapper. `Args.parse : Decoder 'a -> List String -> Result String 'a` | ~40 lines and one new name. Everything else already exists. | Short flags (`-v`), generated `--help`, subcommands |
| **B. An `Args` module of its own** | `flag`, `option`, `positional`, descriptions, `parse`, generated help | A combinator set the size of `Decode`'s, its own grammar, its own error messages, and either its own domain readers or a borrow of `Decode`'s | Nothing, eventually — which is the problem |
| **C. Leave it** | Scripts match on `Env.args ()` | Zero | Anything past two positional arguments |

**A, and not B.** B is a second combinator set for a problem the first one
already solves, which is the shape the budget rule exists to catch; its extra
capability is short flags and generated help, and neither has a call site.
C is what the corpus does today and stops being enough the moment a compiled
script takes options.

### The one real decision inside A

How a flag's value is recognised, given that the conversion happens before
any type is known:

- `--key=value` only. No grammar at all, unambiguous, tiny. Alien to anyone
  coming from bash.
- `--key value`, taking the next token unless it starts with `-`. Familiar,
  and wrong for `--message -5` and for a flag followed by a positional.
- `--key value`, told which names are boolean: `Args.parse ~flags:["verbose"]`.
  Unambiguous, familiar, and one argument wide.

The third is the one to take. It is the only version that is both familiar
and unambiguous, and the thing it asks for -- the list of flags that take no
value -- is the only fact the conversion genuinely cannot infer. Everything
else the type already says.

*Accept:* a compiled script reads `--port=8080` and `--port 8080` alike into
a `Port`; a bad value names the flag it came from; positional arguments are
reachable; no second set of combinators exists.

## P4.4 — Release artifacts

A static `x86_64` and `aarch64` Linux binary (musl), a macOS binary, attached
to a tagged release. This is CI work, not language work.

*Accept:* a tag produces downloadable binaries; each runs on a clean machine
with no OCaml and no wand tree.

## P4.5 — `setup-wand` action

A GitHub Action that installs a released binary. CI is the beachhead: a
controlled environment where per-repo tooling is already normal, and where a
script can be adopted one repository at a time.

*Accept:* a workflow with `uses: mjstahl/setup-wand@v1` can run `wand test`.

## P4.6 — The positioning post

Anchored on D5: *AI writes it, a human audits the manifest, CI typechecks it,
dry-run rehearses it.* Written last, because it quotes numbers and those keep
moving — D9's table changed twice in one session.

## Risks

- **Signing.** Appending bytes to a macOS binary invalidates its code
  signature, and a signed-and-notarised wand would produce compiled scripts
  that Gatekeeper refuses. This may force `wand compile` to re-sign, to
  produce an unsigned artifact with a documented `xattr` step, or to be a
  Linux-first feature. Find out early: it can invalidate P4.2's design.
- **The embedded table going stale.** If the dune rule's dependencies are
  wrong, a built binary carries yesterday's stdlib and every test still
  passes. Guard it with a test that reads a known doc string through the
  embedded path and compares it to the file on disk.
- **`--manifest` as a lie.** A stamped row that is not re-derived from the
  payload is a claim nobody checks. Stamp it from the same inference that
  typechecked the script, in the same run.

## Picking this up

**Where things stand.** Phase 3 is finished and its plan deleted -- what it
learned lives in the code that does it, not in a document. 616 wand tests,
the OCaml suite, nine demos and a `wand fmt` fixed point across 70 `.wand`
files. Nothing in this phase has been started.

**Verify by exit code, never by reading output.** Twice in one session a
check of the form `dune build @runtest 2>&1 | grep -c "\[FAIL\]"` reported
clean while the build was broken or two test files were failing to load --
grep finds nothing when nothing ran. And `set -e` does not abort a
`cmd; echo ok` sequence under zsh, which reported a demo passing that had
just failed. The sequence that actually checks everything:

```
dune build                                            # exit code
dune build @runtest --force >/dev/null 2>&1           # exit code
_build/default/bin/wand.exe test test/wand            # exit code
for d in demos/d1* … demos/d8*; do $d/run.sh; done    # each exit code
N=500 demos/d9-fork-overhead/run.sh                   # ten seconds
# then: copy every tracked .wand to a scratch tree, `wand fmt` it, diff back
```

**The formatter can produce source that does not parse.** Three separate bugs
this session: dropped parentheses that let a constructor swallow its
neighbour, stripped quotes on a map key, and a wrapped application whose
definition then ended at the first line. If you touch `lib/formatter.ml`,
checking that the corpus is a fixed point is not enough -- the corpus must
still *run*. And a `wand fmt` over a file the formatter mishandles leaves the
file broken on disk, so repair it before formatting again.

**Benchmarks move 15% between runs.** Quote milliseconds from several runs,
never a ratio from one. Current readings on an idle machine: `bash -c ':'`
~5 ms, `wand e '1 + 2'` ~8.7 ms, `wand e 'List.length'` ~10.3 ms, real
CPython ~39 ms. Beware `python3` on `PATH` -- if it is a pyenv shim it
measures 112 ms and is measuring pyenv.

**An OCaml primitive's failure escaping as its own text** was found three
times: ports, integer literals, durations, all `int_of_string` without
`_opt`. The corpus is clean of it now; the pattern is worth remembering.

## Exit criteria

1. wand runs from any directory, with no `stdlib/` anywhere on the machine.
2. A directory named `stdlib/` cannot change what a program means.
3. `wand compile` produces an executable that runs where wand is not installed.
4. That executable states its own effect row without running.
5. Released binaries exist for Linux and macOS, installable in one line.

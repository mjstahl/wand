# Phase 4 — Reach

**Status:** P4.1 and P4.4 done · **Goal:** a wand binary that works where it is put,
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
| The binary is not relocatable *(fixed, P4.1)* | `cd /tmp && wand e 'List.length [1,2]'` fails. The standard library is found by walking up from the working directory looking for `stdlib/`, so wand only works inside a tree that happens to contain one. |
| Its standard library is hijackable *(fixed, P4.1)* | A directory named `stdlib/` above the working directory *is* the standard library. `mkdir stdlib && echo 'let length x = "not wand"' > stdlib/List.wand` makes `List.length [1,2]` return `"not wand"`. Arbitrary code, loaded because a folder had the right name, in the language whose pitch is that a script cannot lie about what it does. |
| A script cannot be handed over | There is no way to give someone a script that runs without installing wand first. This is the moat that killed every previous bash replacement. |
| No release artifacts *(fixed, P4.4)* | CI builds and tests; it publishes nothing. There is no way to install wand except by building it. |
| Size | The binary is **3.8 MB**, not the ~10 MB the roadmap assumed. The stdlib is 19 files and **34 KB** — under 1% of it. Nothing here needs shrinking. |
| Startup | `wand e '1 + 2'` takes **~9 ms** against bash's ~5 ms — 1.75–1.89× over three runs, inside the 2–3× budget. Quote the milliseconds, not the ratio: most of bash's 5 ms is process creation and linking rather than bash, so the number that means anything is the **~4 ms difference**, which is wand's own startup. A single noisier run gave 10.7 ms and 2.05×, which is how much these move. |
| What that 4 ms is | Building the builtin environment, then walking up from the working directory for `stdlib/` and reading whatever modules the input mentions. One stdlib module costs ~2 ms today (`wand e 'List.length'` is ~11 ms against `wand e '1 + 2'`'s ~9). That is the part embedding can take. |

## Decisions

| Question | Decision |
|---|---|
| Embed sources or precompiled ASTs? | **Sources.** A `Marshal`'d AST is tied to the compiler that wrote it and to our own type definitions, so it turns every refactor into a format migration. The stdlib is 34 KB of text; parsing it is 1–2 ms and the compile cache already covers the repeat cost. Precompiled ASTs are a later optimisation, taken only if a measurement asks for it. |
| How to embed | **A dune rule generating an OCaml module**, not a new dependency. `ocaml-crunch` does exactly this and is one `depends` line, but it is a build-time dependency for turning 19 files into string constants, which is a rule we can read in full. Keep the dependency list at five. |
| Lookup order | `WAND_STDLIB` when it is set, the embedded table otherwise. Nothing else. `find_stdlib_dir` and its upward walk are deleted, which is what removes the hijack. |
| `WAND_STDLIB` after embedding | **Kept**, as a development override: run a built binary against a working-tree stdlib. It stops being how the stdlib is normally found and becomes how you replace it on purpose. |
| `wand compile` architecture | **Appended payload on ELF, a patched section on Mach-O.** A byte copy of the runtime carries the script and the transitive closure of its *user* modules. On Linux they go on the tail, behind a trailer holding a magic number and a length, and the runtime checks its own tail at startup. On macOS a tail is illegal (see below): the binary reserves a zero-filled `__WAND,__payload` section at link time, `wand compile` overwrites it in place -- same file size, nothing past the end -- and re-signs ad-hoc. Two ways in, one payload format, one loader once the bytes are in hand. |
| Why macOS differs | Measured, not assumed. `codesign` refuses to sign a Mach-O with data past the last load-command-covered region -- `main executable failed strict validation`, exit 1 -- so appending breaks the signature and then forbids repairing it. Truncating the appended bytes lets the same file sign again, which is what pins trailing data as the cause. A payload living in a real section signs, verifies, and runs; so does a reserved section patched in place. |
| Payload size on macOS | **Fixed, reserved at link time.** Patching in place is what keeps the file legal, so the reserve cannot grow to fit. A script whose user modules exceed it is a compile error naming the limit. The stdlib is embedded by P4.1 and is not in the payload, so this bounds user code alone. |
| What the payload contains | Source text, keyed by module path, plus the entry script — the same table shape as the embedded stdlib, so one loader serves both. |
| Manifest stamping | `wand compile` typechecks, then stamps the inferred effect row into the payload. `./deploy --manifest` prints `uses {Shell, FS.Write}` without running anything. An artifact that states its own blast radius is the point of the whole exercise. |

## Working rules

1. Each tranche leaves the tree green: build, both suites, nine demos, `wand fmt` a fixed point.
2. The binary must keep working from inside the source tree at every step. Development is done with this binary; if it breaks, everything stops.
3. Anything that changes startup gets `bench/startup.sh` run before and after, in the same commit message — several runs, quoting milliseconds. The ratio to bash moves by 15% between runs on an idle machine, so a single reading cannot tell an improvement from noise.

## P4.1 — Stdlib embedding · done

`tools/gen_stdlib_embed.ml` turns `stdlib/*.wand` into `Stdlib_embed.table`,
a list of `(name, source)` pairs compiled into the library. Resolution
returns `Embedded of name | File of path` rather than a path, which is what
lets one loader serve both: the key a module is cached and cycle-checked
under is `<stdlib>/List.wand` for an embedded module and the real path for a
user file, and nothing below `load_module` asks where the bytes came from.
`find_stdlib_dir` and its upward walk are gone.

Two call sites needed a rule that no longer had a directory to consult.
`is_stdlib_file` decides whether a file is typechecked against the raw
builtins, and now asks whether the file's own directory holds *every* module
the binary carries -- a standard library rather than a folder with a
`List.wand` in it. `lint_module_source` resolves against `<stdlib>`, which
its imports never consult because they are all stdlib imports.

**Startup did not move, and the reason is worth keeping.** Before and after,
interleaved, five runs of 25--60 samples: `wand e '1 + 2'` 9.5 ms both ways,
`wand e 'List.length'` 10.7 ms both ways, deltas between -0.22 and +0.21 ms
against a run-to-run spread of ±0.5 ms. The ~2 ms a stdlib module costs is
parse and inference, not the directory walk and the `open` that embedding
removed -- those are under a tenth of a millisecond warm. The gap table above
guessed wrong about where that 2 ms lives; taking it is a matter for the
compile cache or precompiled ASTs, and neither has a measurement asking for
it yet. The binary grew 42 KB, 3,977,848 to 4,019,440 bytes.

*Accept:* met, except that `wand e 'List.length'` is unchanged rather than
faster -- see above. `cd /tmp && wand e 'List.length [1,2]'` prints `2`; a
`stdlib/` beside or above the working directory changes nothing;
`WAND_STDLIB` still replaces the library wholesale; `find_stdlib_dir` no
longer exists; `wand e '1 + 2'` is no slower.

`test/test_stdlib_embed.ml` holds the guard the risks section asked for: it
compares every embedded source to the file on disk, so a table built from
stale dependencies fails there rather than passing everything. The canary
check -- add an exported binding to `List.wand`, `dune build`, call it --
confirmed the rule tracks edits.

## P4.2 — `wand compile`

```
wand compile deploy.wand -o deploy
./deploy                 # runs, with no wand installed
./deploy --manifest      # uses {Shell, FS.Write}
```

Copy the running binary, put the payload in it, and at startup look for the
magic before parsing argv as usual. Where the payload goes is the platform
split decided above: a tail and a trailer on ELF, the reserved
`__WAND,__payload` section overwritten in place on Mach-O, followed by
`codesign -f -s -`.

Finding our own executable is the first problem: `Sys.executable_name` is not
reliable when the program was found on `PATH`, and a wrong answer here copies
the wrong file. Read `/proc/self/exe` where it exists, fall back to
`Sys.executable_name`, and fail loudly rather than copying something else.

The macOS path needs `/usr/bin/codesign`, which is an OS binary rather than a
Command Line Tools stub and so is present on a stock machine -- but it is
still an external program, and the one place the "no toolchain" claim is
qualified. Check for it and say so plainly when it is missing, rather than
producing an executable that dies with `Killed: 9` on the user's laptop.

*Accept:* a compiled script runs on a machine with no wand and no stdlib
directory; it reports its own manifest without executing; compiling a script
whose imports do not typecheck fails at compile time, not at run time; on
macOS the product passes `codesign -v` and a payload over the reserve fails
at compile time with the limit in the message.

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

## P4.4 — Release artifacts · done

`v0.1.0` is published with four archives and their checksums: static musl
Linux on `x86_64` and `aarch64`, macOS on `aarch64` and `x86_64`. Each holds
`wand`, `LICENSE` and `README.md`.

**Building happens where the hardware is.** `ocamlopt` emits code for the
machine it was built for, so cross-compiling would mean a cross toolchain
plus every dependency rebuilt for the target. There is no `GOOS`/`GOARCH`
here. The Linux jobs build inside `ocaml/opam`'s multi-arch Alpine image and
link statically against musl; the macOS job builds natively on `macos-15`.

Three things the plan did not anticipate, all of which cost a CI round trip
to find:

| | |
|---|---|
| The Intel macOS runner never runs | `macos-13` sat queued across five dispatches without ever being assigned, while `macos-15` picked up instantly. That target left the matrix; `make release` builds it on a developer's Intel Mac and attaches it to the same release. |
| Static-PIE segfaults on x86_64 | Alpine's gcc defaults to PIE, so `-static` alone yields a static-pie binary, and OCaml's runtime does not survive musl's static-pie startup on `x86_64` -- exit 139 before printing anything. `-no-pie` fixes it. **aarch64 built and ran the same commit correctly**, so one Linux target would have shipped this. |
| `file` says `static-pie linked` | Not `statically linked`, which is what the check looked for. It rejected exactly the binary it asked for. |

**Neither side of a release waits for the other.** CI builds three archives
on a tag; `make release VERSION=x.y.z` tags, pushes, builds the fourth and
attaches it. Both create the release if it is absent and upload to it if it
is not, so they finish in either order. It is a draft until someone
publishes it, because an undrafted release is public from the moment it
exists, and a public release missing an architecture is worse than one
nobody can see yet. The notes live in `.github/release-notes.md` so the text
does not depend on which side won the race -- `v0.1.0` was created by the
local build and shipped a placeholder until that was fixed.

*Accept:* met, on all four. `shasum -c` verifies each archive next to the
download. `linux-x86_64` runs on Debian stable -- a glibc distribution, no
OCaml, no wand tree -- and `linux-aarch64` runs under emulation. The macOS
`x86_64` binary runs natively here. `macos-aarch64` ran on the `macos-15`
runner that built it, in the same smoke check every job does: from `/tmp`,
with a decoy `stdlib/` beside it, printing `3 : Int` and `2 : Int`. That is
the file the archive holds -- macOS is not stripped, so packaging copies
what was tested.

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

- **Signing.** Answered, and it did change P4.2's design. Appending to a
  Mach-O invalidates its signature *and* leaves `codesign` unable to sign it
  again, so re-signing after appending -- the obvious way out -- does not
  exist. The reserved-section patch above is what replaced it.

  What is still open is **arm64**, and it is where the risk actually bites.
  The measurements were taken on an x86_64 Mac, which tolerates a broken or
  absent signature at exec: every appended binary ran, including one carrying
  `com.apple.quarantine`, though `spctl -a` rejected it as having no usable
  signature. Apple Silicon requires at least an ad-hoc signature and kills
  what lacks one, so none of those runs generalise. Verify the section route
  end to end on an arm64 machine before P4.2 is called done.

  P4.4 supplied the machine and settled half of it. `macos-15` is an arm64
  runner; the binary it produces is `adhoc, linker-signed` -- the linker
  signs it unasked -- and the job runs what it built, so an ordinary OCaml
  arm64 binary demonstrably starts and works.

  What that does not touch is the case P4.2 creates: a binary whose reserved
  section has been overwritten and which was then re-signed. Baseline
  execution is now evidence; the patched-and-resigned variant remains
  untested on arm64, and `macos-15` is where to test it.
- **The embedded table going stale.** Guarded. `test/test_stdlib_embed.ml`
  compares every embedded source to its file on disk, so a table built from
  wrong dependencies fails there rather than passing everything. The guard
  only holds while the test can see `../stdlib`, which its dune stanza
  depends on.
- **`--manifest` as a lie.** A stamped row that is not re-derived from the
  payload is a claim nobody checks. Stamp it from the same inference that
  typechecked the script, in the same run.

## Picking this up

**Where things stand.** Phase 3 is finished and its plan deleted -- what it
learned lives in the code that does it, not in a document. 616 wand tests,
the OCaml suite, nine demos and a `wand fmt` fixed point across 70 `.wand`
files.

P4.1 and P4.4 are done, and `v0.1.0` is published. **The order changed**:
P4.5 comes next, then P4.2 and P4.3. The reasoning is the phase's own --
P4.5 calls CI the beachhead, and in CI you install the tool, so a
self-contained executable buys nothing there. Against that, P4.2 got more
expensive when the signing experiment turned it into two mechanisms with an
arm64 leg still unverified, and `wand t` already reports an inferred effect
row, so the audit story does not wait on `--manifest`. P4.3 follows P4.2
because flags arrive with compiled executables; `Env.args ()` is what the
corpus uses today.

The signing experiment was run before any of this, because it could
invalidate P4.2's design. It did, and what it found is in the decisions
table and the risks.

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

1. **Met.** wand runs from any directory, with no `stdlib/` anywhere on the
   machine.
2. **Met.** A directory named `stdlib/` cannot change what a program means.
3. `wand compile` produces an executable that runs where wand is not installed.
4. That executable states its own effect row without running.
5. **Met.** Released binaries exist for Linux and macOS, installable in one
   line -- `v0.1.0`, four archives with checksums.

3 and 4 are P4.2, which now comes after P4.5. Phase 4 does not end until
they are met; what changed is the order, not the bar.

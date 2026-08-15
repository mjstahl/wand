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
| Startup | `wand e '1 + 2'` is 2.05× `bash -c ':'`, inside the 2–3× budget. Embedding should improve it slightly (no directory walk, no file reads); it must not make it worse. |

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
3. Anything that changes startup gets `bench/startup.sh` run before and after, in the same commit message.

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
startup no worse than 2.05×.

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

## P4.3 — Release artifacts

A static `x86_64` and `aarch64` Linux binary (musl), a macOS binary, attached
to a tagged release. This is CI work, not language work.

*Accept:* a tag produces downloadable binaries; each runs on a clean machine
with no OCaml and no wand tree.

## P4.4 — `setup-wand` action

A GitHub Action that installs a released binary. CI is the beachhead: a
controlled environment where per-repo tooling is already normal, and where a
script can be adopted one repository at a time.

*Accept:* a workflow with `uses: mjstahl/setup-wand@v1` can run `wand test`.

## P4.5 — The positioning post

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

## Exit criteria

1. wand runs from any directory, with no `stdlib/` anywhere on the machine.
2. A directory named `stdlib/` cannot change what a program means.
3. `wand compile` produces an executable that runs where wand is not installed.
4. That executable states its own effect row without running.
5. Released binaries exist for Linux and macOS, installable in one line.

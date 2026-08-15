# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**wand** — a typed ML-style scripting language for Human-AI collaboration. Written in OCaml, built with Dune.

## Build & Development Commands

```bash
# Build everything
dune build

# Run all tests
dune test

# Run a single test file
dune exec <test_binary>

# Run the interpreter/REPL
dune exec wand -- <args>

# Format OCaml source
ocamlformat --inplace <file>
# or format all files tracked by dune
dune fmt

# Clean build artifacts
dune clean
```

## Architecture

As the language implementation grows, the typical structure for an OCaml compiler/interpreter is:

- `bin/` — executable entry points (REPL, batch runner)
- `lib/` — core library: lexer, parser, typechecker, evaluator/compiler
- `test/` — unit and integration tests

Key pipeline stages to expect: **Lexing → Parsing → Type inference → Evaluation/Compilation**. The ML-style type system implies Hindley-Milner inference as the likely typechecking strategy.

## OCaml / Dune Conventions

- Library modules are defined via `(library ...)` stanzas in `dune` files; executables via `(executable ...)`.
- Tests use `(test ...)` stanzas or inline `let () = ...` assertions with `OUnit2` or `Alcotest`.
- `_build/` and `_opam/` are generated — never edit them.
- The active OPAM switch is local (`_opam/`) if present.

## Verifying a change

Check by exit code, never by reading output. `dune build @runtest 2>&1 | grep
-c "\[FAIL\]"` reports clean when nothing ran, and `set -e` does not abort a
`cmd; echo ok` sequence under zsh.

```bash
dune build                                            # exit code
dune build @runtest --force                           # exit code
_build/default/bin/wand.exe test test/wand            # exit code
for d in demos/d1* … demos/d8*; do $d/run.sh; done    # each exit code
N=500 demos/d9-fork-overhead/run.sh                   # ten seconds
WAND=$PWD/_build/default/bin/wand.exe \
  $PWD/_build/default/bin/wand.exe ci/check_stdlib_fmt.wand
dune build @fmt                                       # dune files
```

Changing `lib/formatter.ml` needs more: the formatter has produced source
that does not parse, so check that the corpus is still a fixed point *and*
still runs. `wand fmt` writes in place, so run it on a copy.

Changing anything on the startup path gets before-and-after numbers in the
commit message, from several runs. Readings move ~15% between runs, so one
reading cannot tell an improvement from noise.

## Releasing

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

## Writing wand code

Read `docs/reference.md` for the wand language reference — syntax, types,
functions, pattern matching, shell execution, `try`, effect handlers,
contracts, typed holes, imports, and the standard library. `README.md` is the
project pitch, not the reference.

When you need to explore or verify wand behaviour, use `Runner.run_string` in
a test, or write a small `.wand` script and run it:

```bash
# Run a wand script
dune exec wand -- path/to/script.wand

# One-shot evaluation
dune exec wand -- e "1 + 2"

# Interactive REPL
dune exec wand -- i
```

The most reliable way to test a snippet is via `Runner.run_string` in a
throwaway test or the existing test suite.

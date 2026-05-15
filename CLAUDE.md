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

# Run the interpreter/REPL (once it exists)
dune exec bin/wand -- <args>

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

## Writing wand code

Read `README.md` for the wand language reference — syntax, types, functions,
pattern matching, imports, and the standard library.

When you need to explore or verify wand behaviour, use `Runner.run_string` in
a test, or write a small `.wand` script and run it:

```bash
# Run a wand script
dune exec bin/wand -- path/to/script.wand

# One-shot evaluation (once wand e subcommand exists)
dune exec bin/wand -- e "1 + 2"

# Interactive REPL (once wand i subcommand exists)
dune exec bin/wand -- i
```

Until the REPL exists, the most reliable way to test a snippet is via
`Runner.run_string` in a throwaway test or the existing test suite.

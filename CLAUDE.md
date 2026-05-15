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

When you need to explore or verify wand behaviour, use the REPL in
machine-readable mode:

```bash
# One-shot evaluation
dune exec bin/wand -- i --eval "1 + 2" --json

# Interactive session (send expressions over stdin, one per line)
dune exec bin/wand -- i --json
```

Every response is a JSON object: `{"ok": true, "value": "3", "type": "Int"}`.
Use `:type expr`, `:doc name`, and `:env` as inputs to query types, doc
strings, and the current environment.

This is the primary way to learn what wand can do, verify types, and test
snippets before writing them into scripts or implementation code.

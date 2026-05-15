# REPL Plan

## Invocation

```
wand i                             # start interactive session
wand i --load file.wand            # start session with file preloaded
wand e "expr"                      # evaluate a single expression and exit
wand e --load config.wand "expr"   # evaluate in context of a preloaded file
wand t "expr"                      # typecheck only, print inferred type
wand t --load file.wand "expr"     # typecheck in context of a preloaded file
wand d <name>                      # print doc string for a name
wand d --load file.wand <name>     # doc in context of a preloaded file
```

`--load` can be repeated to preload multiple files. It mirrors the `:load`
special command inside the session.

Each subcommand has a single-letter short form and a full-word alias:

| Short | Long          |
|-------|---------------|
| `i`   | `interactive` |
| `e`   | `eval`        |
| `t`   | `type`        |
| `d`   | `doc`         |
| `h`   | `help`        |

`wand e` exits with code 0 on success, 1 on error. `wand t` typechecks
only — no evaluation, no side effects. `wand d` prints the doc string for a
name; prints "no doc" until docstrings are implemented.

## Help

`h` is a subcommand, consistent with the single-letter pattern. `help` is an
alias.

- `wand h` — lists all subcommands with a one-line description each
- `wand h <sub>` — shows usage specific to that subcommand

Example:

```
$ wand h
wand — a typed scripting language

Commands:
  i    Start an interactive session
  e    Evaluate an expression and exit
  t    Typecheck an expression without evaluating
  d    Print the doc string for a name
  h    Show this help, or help for a specific command

$ wand h e
Usage: wand e [--load <file>]... <expr>

Evaluate a wand expression and print the result.
If the expression contains a hole (?), typechecks only (same output as `wand t`).

Options:
  --load <file>    Load a .wand file before evaluating (repeatable)
```

## Prompt and multi-line input

Primary prompt: `wand> `
Continuation prompt: `   .. ` (aligned with primary)

The REPL detects incomplete input and shows the continuation prompt rather
than evaluating prematurely. Incomplete conditions:
- Unclosed `(`, `[`
- Input ends with `->`, `=`, `|`, `then`, `else`, `in`, `,`
- Unclosed string literal

On a blank continuation line, the accumulated input is submitted as-is
(allows bailing out of a stuck multi-line entry).

## Evaluation and output

Each submission is run through the full pipeline: lex → parse → typecheck →
eval. Output format:

```
wand> 1 + 2
3 : Int

wand> "hello"
"hello" : String

wand> let double x = x * 2
double : Int -> Int

wand> double 5
10 : Int

wand> type Color = Red | Green | Blue
Color

wand> [1, 2, "three"]
Error: type error: cannot unify Int with String
```

For `let` bindings and `type` definitions: show the name and its type (or kind
for types). For expressions: show value and type. Errors print inline with a
clear `Error:` prefix — no stack traces.

## Persistent state

Bindings and type definitions accumulate across lines. Later `let` definitions
shadow earlier ones (same name). Imports work: `import List` loads the stdlib
module into the session environment.

## Readline

Use `linenoise` (opam package `linenoise`) for:
- Arrow key history navigation
- Line editing (ctrl-a, ctrl-e, ctrl-k, etc.)
- History persisted to `~/.wand_history` between sessions
- Tab completion (see below)

## Tab completion

- Bare identifier prefix: complete against names in the current environment
- `ModuleName.` prefix: complete against names exported by that module
- `:` prefix: complete against special commands

## Special commands

All special commands start with `:`.

| Command | Description |
|---|---|
| `:quit` / `:q` | Exit the REPL |
| `:help` / `:h` | List special commands |
| `:type <expr>` / `:t` | Show the type of an expression without evaluating |
| `:doc <name>` / `:d` | Show the doc string for a name (ties into docstrings plan) |
| `:load <path>` / `:l` | Load a `.wand` file into the current session |
| `:reload` / `:r` | Reload the last `:load`ed file |
| `:reset` | Clear all session bindings and start fresh |
| `:env` | List all names currently in scope with their types |
| `:edit [name]` | Open definition in `$EDITOR` (see below) |

## `:edit` command

`:edit` with no argument opens a temporary file containing a blank template.
`:edit double` opens a temporary file pre-populated with the current
definition of `double` (pretty-printed from the AST, or the original source
if source tracking is available).

On editor close:
1. Read the file content
2. Lex, parse, typecheck — if any step fails, print the error and **do not**
   update the environment (the old definition is preserved)
3. On success, load the new definition(s) into the session environment,
   shadowing any previous bindings with the same names
4. Print the updated type signature(s)

`$EDITOR` is used, falling back to `$VISUAL`, then `vi`.

The temp file is created in `$TMPDIR` with a `.wand` extension so editors
apply syntax highlighting. It is deleted after the session closes the editor.

## `:type` without evaluation

```
wand> :type if true then 1 else "hello"
Error: type error: cannot unify Int with String
```

Runs typecheck only — useful for exploring types without side effects.

## Error display

Type errors and runtime errors print with the `Error:` prefix and the message.
Location information (line:col) is shown when available. No exception
backtraces exposed to the user.

```
wand> x
Error: unbound variable 'x'

wand> 1 / 0
Error: division by zero
```

## Typed holes

`?` (the `Hole` token and AST node) already exists. In the REPL, holes become
a first-class discovery tool — probe what type is expected at any position
without knowing it in advance.

```
wand i> List.map ? [1, 2, 3]
Hole: expected Int -> ?

wand i> if ? then 1 else 2
Hole: expected Bool
```

Holes complement `:type`: `:type expr` tells you the type of a complete
expression; `?` inside an expression tells you the type of a missing piece.

For `wand e`, if the expression contains a hole, evaluation is skipped and
the output is identical to `wand t` — hole types are reported, no side
effects occur. A hole in `wand e` is a signal that the expression is
incomplete, so running it would be meaningless.

### Typechecker changes

`Hole` in `infer`: instead of failing, unify with a fresh type variable `'a`,
record the hole's expected type (after further constraint propagation), and
report it. Continue type-checking the rest of the expression so all holes in
a single submission are reported together.

Hole reporting accumulates into a list of `(location, typ)` pairs returned
alongside the inferred type. The REPL prints each one before the result.

### Evaluator changes

`Hole` in `eval`: raise `EvalError "hole: not implemented"`. A submission
containing a hole can be type-checked and have its hole types reported, but
will blow up if evaluation actually reaches the hole. This makes holes useful
as typed TODOs in scripts too — the script type-checks cleanly, fails loudly
at runtime only if the hole is reached.

### Outside the REPL

In scripts, holes cause a type-check warning (printed to stderr) listing each
hole's expected type, but do not prevent execution unless the hole is
evaluated. This lets you use `?` as a typed placeholder during development.

## Implementation

### Binary

New executable `bin/repl.ml`, registered in `bin/dune` as `(executable (name repl) ...)`.
The main `bin/wand.ml` dispatches to it when no subcommand or `repl` is given.

### Core loop

```
loop:
  read line(s) until complete (multi-line detection)
  if starts with ':' → handle special command
  else → run through Runner.run_string with accumulated session env
  print result
  update session env
```

The session env is a mutable record holding the current `type_env` and
`eval_env`, threaded through each iteration.

### Dependencies

- `linenoise` — readline / history
- Everything else already in `lib/`

### Pretty-printing

The REPL needs a `pp_result` function that formats `(value, typ)` as
`value : Type`. Reuse `Evaluator.show_value` and `Typechecker.string_of_typ`.

## Implementation order

1. Core loop (no readline, no special commands) — basic evaluate-and-print
2. Multi-line detection
3. `linenoise` integration (history, line editing)
4. Special commands (`:quit`, `:type`, `:doc`, `:load`, `:env`)
5. Typed holes (`?` reporting in typechecker + evaluator blowup)
6. `:edit` command
7. Tab completion

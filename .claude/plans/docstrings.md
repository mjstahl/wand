# Doc Strings with Examples Plan

## Syntax

Regular comments use `(* *)` (already implemented, nestable). Doc comments use
`(** *)` — the extra leading `*` signals a doc string.

```
(** Returns the length of a list. *)
let length xs = ...

(** Compute the area of a circle.

    $ area (Circle (radius = 5))
    = Ok 78
*)
let area c =
  let (r) = c in
  3 * r * r
```

Doc strings attach to the definition that immediately follows them. A doc
string not followed by a definition is a module-level doc (describes the file).

## Example syntax

Examples use `$` as the prompt (input line) and `=` as the result line.
Results are always tagged `Ok value` or `Err message`, mirroring the runtime's
`Result` type. This means the doctest runner can compare directly against
`Runner.run_string` output with no special-casing.

```
(** Split a string on a delimiter.

    $ String.split "," "a,b,c"
    = Ok [a, b, c]

    $ String.split "," ""
    = Ok []
*)

(** Get the head of a list.

    $ List.head [1, 2, 3]
    = Ok 1

    $ List.head []
    = Err "empty list"
*)
```

The `=` line is optional — if omitted, the example is run but its output is
not checked. This is the standard form for `let` bindings and side-effectful
calls; asserting `= Ok ()` on a `let` is allowed but discouraged as it adds
no information:

```
(**
    $ let xs = [1, 2, 3]
    $ List.length xs
    = Ok 3
*)
```

Multiple `$` lines in sequence share an environment — each line is accumulated
into a single `run_string` call, and only the last expression's result is
checked against the `=` line.

## Changes required

### Lexer

Add `DocComment of string` token. When `(*` is followed immediately by `*`,
capture the content rather than discarding it. Strip the leading `(**` and
trailing `*)`, trim leading `*` from each line (odoc convention).

Regular `(* *)` comments continue to be silently skipped.

### AST

Attach doc strings via a parallel map rather than modifying every constructor
— a `(string -> string option)` lookup threaded through `parse_program`. Less
invasive than adding an `option` field to every `top_item` variant.

### Parser

In `parse_program`, when a `DocComment` token is encountered, stash it. When
the next `TLLet` or `TLType` is parsed, attach the stashed doc. If another
`DocComment` appears before a definition, the previous one is discarded (or
kept as module-level doc).

### Doc generation tool (`wand doc`)

A CLI subcommand that:
1. Parses a `.wand` file (or directory)
2. Extracts all `(name, doc_string)` pairs
3. Renders to Markdown

Output format per definition:
```markdown
## `length`

Returns the length of a list.

**Example**
\```
$ List.length [1, 2, 3]
= Ok 3
\```
```

### Doctest runner (`wand doctest` or `dune` integration)

Extracts all example blocks from doc strings and runs them as tests:

1. Parse doc string, find `$` / `=` pairs
2. Accumulate consecutive `$` lines into a single `run_string` input
3. Run it; compare `show_value` (wrapped in `Ok`) or error string (wrapped
   in `Err`) against the `=` line
4. Report pass/fail per example with file + line location

This gives every stdlib function living documentation that is also a regression
test.

## Integration with REPL (future)

When the REPL exists, `:doc length` or `length?` prints the doc string for
`length` including formatted examples.

## Stdlib doc coverage

Every stdlib function gets a doc string as part of this effort. Each doc
string must include at least one example block. The doctest runner then
serves as the stdlib's integration test suite — if the examples pass, the
function works as documented.

Functions implemented as OCaml primitives (registered in `evaluator.ml` /
`typechecker.ml`) need their doc strings added to the corresponding `.wand`
stub file where the wand-level binding lives. If no stub exists yet, one is
created for the sole purpose of holding the doc.

## Implementation order

1. Lexer: `DocComment` token
2. Parser: stash and attach to definitions
3. AST: parallel doc map
4. Doctest runner (highest immediate value — validates stdlib examples)
5. Add doc strings to all existing stdlib functions (`String`, `List`, `FS`)
6. Add doc strings to each new stdlib module as it is implemented
7. Doc generation CLI
8. REPL integration (deferred until REPL exists)

# Token Types Plan

**Needs re-evaluation before implementation.** This plan predates the
type-annotation-syntax rework (`type_expr` gained `TEApp`/`TETuple`/`TEFun`,
constructor fields split into positional/named forms — see git history
around 2026-07-25) and hasn't been checked against that grammar. It also
overlaps with the existing `Version` lexical domain type (README's
"Lexical domain types" table) — the `SemVer` example below may already be
partially covered, or may conflict with how domain types are currently
lexed/typed. Re-read against current `lib/lexer.ml`/`lib/parser.ml` and
the domain-types design before starting.

User-defined lexical types backed by a `Parser` grammar. A `token`
declaration introduces a new nominal type whose values are validated
at lex time and carry the original matched string.

## Syntax

```
token SemVer = <parser expression>
token IPv4   = <parser expression>
token URL    = <parser expression>
```

`show` is always the original matched string — no user-defined formatter
needed. The type is opaque everywhere else.

## Placement constraint

`token` declarations must appear at the top of the file, immediately
after the shebang line (if present) and before any other declarations.
Any `token` declaration found after other code is a parse error:

```
Error: token declarations must appear at the top of the file
```

This constraint enables the two-pass approach below without ambiguity.

## Two-pass lexing

Because token types extend the lexer's vocabulary (e.g. `1.2.3` is a
valid `SemVer` but not valid base-language syntax), the interpreter
processes files in two passes:

1. **Token pass** — scan only the leading `token` declarations, compile
   each grammar, and register the token types for the current file scope.
2. **Lex pass** — lex the rest of the file with those token types in
   vocabulary. When the lexer encounters input that matches a registered
   token grammar, it emits a typed token literal rather than falling back
   to base-language tokenisation.

## Type system integration

- Each `token` declaration introduces a new nominal type (like a `type`
  alias but opaque and distinct from `String`).
- The typechecker treats token types as first-class: they can appear in
  annotations, function signatures, and pattern matches.
- A string literal `"1.2.3"` in a position expecting `SemVer` is
  validated against the grammar at typecheck time and promoted if valid.
- An unquoted literal `1.2.3` in a `SemVer` context is accepted by the
  lexer (pass 2 above) and typed as `SemVer` directly.
- Passing a plain `String` where a `SemVer` is expected is a type error —
  explicit parsing is required: `SemVer.parse "1.2.3"`.

## Per-token generated API

For each `token T` declaration, the following are generated automatically:

```
T.parse  s    -- String -> Result T    validate and wrap
T.show   t    -- T -> String           return original matched string
```

## Example

```
token SemVer =
  let digits = Parser.many1 (Parser.range "0" "9")
  Parser.seq digits (Parser.seq (Parser.lit ".") 
    (Parser.seq digits (Parser.seq (Parser.lit ".") digits)))

let v : SemVer = 1.2.3          -- lexed as SemVer directly
let s = SemVer.show v           -- "1.2.3"
let r = SemVer.parse "1.2.3"    -- Ok <SemVer>
let r = SemVer.parse "bad"      -- Error "..."
```

## Implementation

### Interpreter changes
1. Add `token` to the lexer as a keyword
2. Implement the token pre-pass: extract leading `token` declarations,
   compile their grammars, register in a token table for the file
3. Extend the main lexer to consult the token table when encountering
   otherwise-invalid input sequences
4. Add `TToken of string` (or reuse `TName`) to the type system

### Parser changes
5. Add `token` declaration to the AST (`DToken of string * parser_expr`)
6. Parse `token` declarations before other top-level forms

### Typechecker changes
7. Register token types in the type environment on declaration
8. Validate string literals against token grammars at typecheck time
9. Generate `T.parse` and `T.show` schemes automatically

## Sequencing

Depends on the Parser module being complete first. Then:

1. Token pre-pass in the lexer
2. AST and parser changes
3. Type system: nominal token type, string literal promotion
4. Generated `parse` / `show` API
5. Tests: declaration placement error, unquoted literals, type errors

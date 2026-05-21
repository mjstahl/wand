# Regex Plan

Add regex literals and a `Regex` stdlib module for pattern matching against
strings. The primary use case is text processing of process output and file
contents.

## Syntax

Regex literals use the `r/pattern/` form with optional flags:

```
r/\d+\.\d+/       -- basic pattern
r/foo/i            -- case-insensitive
r/^\s+|\s+$/       -- alternation
```

Regex literals are checked at parse time — a bad pattern is a compile error,
not a runtime error.

## `String` module additions

Common operations live on `String` since that is what they operate on:

```
String.match?    r/pattern/ s   -- Bool    does s contain a match?
String.captures  r/pattern/ s   -- List String   full match at [0], groups at [1..]
String.replace   r/pattern/ repl s  -- String   replace first match
String.replace_all r/pattern/ repl s -- String  replace all matches
String.split_re  r/pattern/ s   -- List String   split on pattern
```

`String.captures` returns an empty list when there is no match, so callers can
pattern match:

```
match String.captures r/^(\S+)\s+(\d+)/ line with
| []              -> Error "no match"
| [_, name, ver]  -> Ok (name, ver)
```

## `Regex` module

For cases where you want to compile a pattern once and reuse it (e.g. inside a
loop), a `Regex` module holds the opaque compiled type:

```
Regex.compile  pattern        -- String -> Result Regex
Regex.match?   re s           -- Regex -> String -> Bool
Regex.captures re s           -- Regex -> String -> List String
Regex.replace  re repl s      -- Regex -> String -> String -> String
Regex.replace_all re repl s   -- Regex -> String -> String -> String
Regex.split    re s           -- Regex -> String -> List String
```

`r/pattern/` literals desugar to a pre-compiled `Regex` at load time, so the
`String.*` functions accept both literals and `Regex` values.

## Flags

| Flag | Meaning            |
|------|--------------------|
| `i`  | Case-insensitive   |
| `m`  | Multiline (`^`/`$` match line boundaries) |
| `s`  | Dotall (`.` matches newline) |

## Implementation

Use the `re` opam library (pure OCaml, no C deps, already widely used). PCRE
syntax via `re.pcre` sub-library.

### Lexer changes

- Lex `r/` as start of regex literal token
- Read until unescaped `/`, then consume optional flag chars (`i`, `m`, `s`)
- Emit `Token.Regex of string * string` (pattern, flags)
- Disambiguate from division: `r/` is only a regex when `r` is not a bound
  identifier — use same context the lexer already tracks for `/`

### Parser changes

- `Regex (pat, flags)` AST node in `expr`
- Parses as a primary expression, same precedence as literals

### Typechecker changes

- Add `TRegex` to `typ`
- `Regex` literal → `TRegex`
- `String.match?` etc. accept `TRegex` as first argument

### Evaluator changes

- Add `VRegex of Re.re` to value (holds compiled regex)
- Evaluate `Regex (pat, flags)` node: compile with `re.pcre`, raise
  descriptive error on bad pattern
- Implement `String.match?`, `String.captures`, etc. as builtins using `Re`

### `wand.opam` changes

- Add `re` to `depends`

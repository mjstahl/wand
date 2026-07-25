# Parser Module Plan

A PEG-based parser stdlib that replaces the `Regex` module. PEGs handle
recursive/nested structures, produce structured captures, and have no
ambiguity — strictly more powerful than regexes for scripting tasks.

## Remove Regex

- Delete `lib/regex.ml` and remove `Regex` from the stdlib prelude
- Remove `re` and `re.pcre` from `lib/dune` dependencies
- Audit tests and update any Regex usage to Parser equivalents

## Parser module API

Grammars are first-class values of type `Parser` (opaque). Combinators
build grammars; `Parser.run` applies them.

### Primitives

```
Parser.lit    s          -- String -> Parser        match literal string
Parser.any               -- Parser                  match any single character
Parser.range  lo hi      -- String -> String -> Parser  match char in range
Parser.set    chars      -- String -> Parser        match any char in set
Parser.eof               -- Parser                  match end of input
```

### Combinators

```
Parser.seq    p q        -- Parser -> Parser -> Parser   p then q
Parser.choice p q        -- Parser -> Parser -> Parser   p or else q
Parser.many   p          -- Parser -> Parser             zero or more
Parser.many1  p          -- Parser -> Parser             one or more
Parser.opt    p          -- Parser -> Parser             zero or one
Parser.not    p          -- Parser -> Parser             negative lookahead
Parser.ahead  p          -- Parser -> Parser             positive lookahead
```

### Captures

```
Parser.capture p         -- Parser -> Parser   capture matched span as String
Parser.group   p         -- Parser -> Parser   capture into List String
```

### Running

```
Parser.run    p src      -- Parser -> String -> Result String
Parser.match? p src      -- Parser -> String -> Bool
Parser.find   p src      -- Parser -> String -> Option String
Parser.find_all p src    -- Parser -> String -> List String
Parser.split  p src      -- Parser -> String -> List String
```

## Named grammars

Grammars can be bound like any value and composed:

```
let digit  = Parser.range "0" "9"
let digits = Parser.many1 digit
let alpha  = Parser.choice (Parser.range "a" "z") (Parser.range "A" "Z")
```

## Implementation

Back the `Parser` type with an OCaml variant (the PEG combinator tree).
`Parser.run` is a recursive descent interpreter over that tree.
No external dependencies needed — pure OCaml implementation.

## Sequencing

1. Implement core PEG interpreter in `lib/parser.ml`
2. Add combinators and captures
3. Add `Parser` to stdlib prelude
4. Remove `Regex` module and clean up deps
5. Update tests

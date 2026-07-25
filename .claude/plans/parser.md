# Parser Module Plan

A PEG-based parser stdlib. PEGs handle recursive/nested structures,
produce structured captures, and have no ambiguity.

**Reviewed 2026-07-25** — tested the combinator design directly (a
standalone OCaml prototype matching this API 1:1, three real grammars:
INI, a nested-block config, a length-prefixed binary TLV format) before
committing to this plan. Two real gaps found, both addressed below. See
the two "found via testing" notes for what broke and why.

## Prerequisite: mutual recursion — DONE (2026-07-25)

Implemented via `and`: `let f ... = ... and g ... = ...` (top-level and
local, with `in`), producing a new `LetRec`/`TLLetRec` AST node backed by
a `VFixGroup` at the evaluator level (generalizes the existing single-
function `VFix` self-recursion trick to a whole mutually-visible group).
See `lib/parser.ml`'s `parse_fn_binding`/`parse_top_fn_binding`,
`lib/typechecker.ml`'s `LetRec`/`TLLetRec` cases, `lib/evaluator.ml`'s
`VFixGroup`. Tested directly — even/odd, multi-equation-clause-plus-and-
group, and local `let ... and ... in` all work. See `test/test_script.ml`
(`test_mutual_recursion`) and the README's "Functions" section.

**Important limitation, confirmed empirically, not just theoretically**:
this only supports **function** bindings (`and`-bound members must take
at least one parameter — enforced with a clear parse error otherwise).
Plain mutually-recursive *values* (e.g. two circular list literals) are
NOT supported and can't be, in a strict/eager language — confirmed by
testing that even OCaml itself rejects the equivalent (`let rec x = 1 ::
y and y = 2 :: x` fails in OCaml too). Self-reference only works through
a function's body being deferred until called; a plain value's right-hand
side is evaluated immediately, so a forward reference inside it fails
before the recursive binding could ever help.

**What this means for Parser grammars specifically**: a recursive grammar
rule must be written as a thunked function (`let block () = ... body ()
...`, called as `block ()` wherever referenced), not a bare value
(`let block = ...`) — confirmed this pattern works end-to-end. This is
the normal idiom in any strict language (OCaml/F#'s own recursive value
restriction has the identical shape), not a wand-specific workaround.
Grammar rules in this plan's "Named grammars" section below should be
written this way, not as bare circular values.

This isn't Parser-specific speculation: `lib/token.ml:49` already lexes
an `and` keyword (`"and — keyword, not &&"`) and `lib/parser.ml`'s
`keywords` list already reserves it, but grep confirms it's never consumed
by any grammar rule — dead syntax, clearly anticipated and never finished.
Wiring up `let rec f = ... and g = ...`-style mutual recursion (or
equivalent) is a prerequisite for this plan, not a nice-to-have, and
should be scoped/landed as its own piece of work first.

## API design: needs `bind`, not just fixed combinators

**Found via testing**: `seq`/`choice`/`many`/etc. as originally sketched
only let you wire together parsers that are already fully built *before*
you see any input — nothing downstream can react to a value an earlier
step actually matched. This breaks on any data-dependent format. Concrete
repro: a tag-length-value binary format (1-byte tag, 2-byte length, then
exactly that many payload bytes) — with only `seq`/`many`, the best you
can do is capture the length bytes and then `many any` to consume
"whatever's left," which accepts *any* input regardless of whether the
length field matches reality. It's not really parsing a TLV format, just
ignoring the one thing that makes it one.

The fix is a `bind` combinator:
```
Parser.bind : Parser 'a -> ('a -> Parser 'b) -> Parser 'b
```
`bind p f` runs `p`, then calls `f` with what `p` actually captured, and
`f` **builds the next parser from that value** — e.g. decode 2 captured
length-bytes into the integer 3, then construct "read exactly 3 more
bytes" for *this specific input*. Verified this actually enforces the
length correctly (accepts when the declared length matches the payload,
rejects when it's short, rejects when there's trailing unconsumed data) —
see `## Combinators` below for the added primitive.

This isn't only a binary-format concern — anything shaped "read a count,
then read that many things" (length-prefixed strings, `Content-Length`-
style headers, repeat-N-times structures generally) needs the same fix.

## Remove Regex — bigger than it looks, reconsider before doing it

**Correction**: `lib/regex.ml` doesn't exist. Regex isn't a removable
stdlib module — it's wired into the language at the syntax level:
- `r/pattern/flags` is a **lexer token** (`token.ml`, `lexer.ml:410-431`)
  and an **AST literal** (`ast.ml:76`), not a library call.
- `String.match?`/`capture`/`replace_re`/`replace_all_re`/`split_re` are
  documented core `String` functions (README), not optional add-ons.
- ~30 references across `evaluator.ml`/`typechecker.ml`, 9 existing tests,
  plus the `re`/`re.pcre` opam deps.

So "remove Regex" really means deleting first-class lexer/AST syntax and
rewriting 5 documented `String` functions — a much bigger, more
disruptive change than a module swap. Worth reconsidering whether removal
is right at all: regex is a strong fit for the common case (validate/
extract/simple text munging) precisely because it's compact, standard
syntax — `r/\d+/` vs. the combinator equivalent is a real ergonomics
regression for that case. Recommend: **add `Parser` alongside `Regex`**
for the cases regex genuinely can't do (recursive/nested grammars,
data-dependent formats), not as a wholesale replacement.

## Parser module API

Grammars are first-class values of type `Parser 'a` (opaque, parameterized
over what a successful parse produces — generics now exist in wand, so
this can be properly typed rather than always flattening to `String`).
Combinators build grammars; `Parser.run` applies them.

### Primitives

```
Parser.lit    s          -- String -> Parser Unit        match literal string
Parser.any               -- Parser Unit                  match any single character
Parser.range  lo hi      -- String -> String -> Parser Unit  match char in range
Parser.set    chars      -- String -> Parser Unit        match any char in set
Parser.eof               -- Parser Unit                  match end of input
```

### Combinators

```
Parser.seq    p q        -- Parser 'a -> Parser 'b -> Parser 'b      p then q
Parser.choice p q        -- Parser 'a -> Parser 'a -> Parser 'a      p or else q
Parser.many   p          -- Parser 'a -> Parser Unit                 zero or more
Parser.many1  p          -- Parser 'a -> Parser Unit                 one or more
Parser.opt    p          -- Parser 'a -> Parser Unit                 zero or one
Parser.not    p          -- Parser 'a -> Parser Unit                 negative lookahead
Parser.ahead  p          -- Parser 'a -> Parser Unit                 positive lookahead
Parser.bind   p f        -- Parser 'a -> ('a -> Parser 'b) -> Parser 'b   data-dependent parsing (see above)
```

Note: needs a real design pass on exactly how `bind`'s captured value `'a`
is shaped for each combinator above (this plan sketches the *need*,
verified by testing; the precise capture-value representation per
primitive/combinator still needs work — don't take `Parser 'a` above as
final, fully worked out signatures).

### Captures

```
Parser.capture p         -- Parser 'a -> Parser String   capture matched span as String
Parser.group   p         -- Parser 'a -> Parser (List String)   capture into List String
```

Note: `capture` vs `group`'s exact semantic difference (does `group`
collapse nested captures within `p`, or just re-wrap `capture`'s single
string as a one-element list?) is still underspecified — needs deciding
before implementation, not just at this sketch level.

### Running

```
Parser.run    p src      -- Parser 'a -> String -> Result String 'a
Parser.match? p src      -- Parser 'a -> String -> Bool
Parser.find   p src      -- Parser 'a -> String -> Option 'a
Parser.find_all p src    -- Parser 'a -> String -> List 'a
Parser.split  p src      -- Parser 'a -> String -> List String
```

(Updated to `Result String 'a` / `Option 'a` now that both are real,
generic types — `find`/`find_all` return `Option Option.wand`-shaped
values instead of always flattening to `String`.)

## Named grammars

Grammars can be bound like any value and composed:

```
let digit  = Parser.range "0" "9"
let digits = Parser.many1 digit
let alpha  = Parser.choice (Parser.range "a" "z") (Parser.range "A" "Z")
```

Recursive grammars (the common case for anything non-flat) now have
`and` to lean on (prerequisite above, done). Since `and`-bound members
must be functions, recursive grammar rules need a dummy `()` parameter and
an explicit call at each reference point — confirmed this works:
```
let block () = Parser.seq ident (Parser.seq ws (... (body ()) ...))
and body () = Parser.many (Parser.choice (block ()) (attr ()))
and attr () = ...
```
Non-recursive grammar rules stay plain values as originally sketched
(`let digit = Parser.range "0" "9"` etc.) — only genuinely
self-referential rules need the `()` treatment.

## Implementation

Back the `Parser` type with a closure (`string -> int -> ... option`),
**not a data tree/variant as originally sketched.** Tested both shapes
directly: a closure-based representation supports self-referential
recursive definitions naturally (mirrors how wand's existing single-
function recursion already works); an eagerly-built OCaml variant/tree
value does not support mutual self-reference without extra machinery
(explicit laziness/knot-tying), which would reintroduce the exact
recursion problem this plan needs solved. `Parser.run` is then just
"call the closure at position 0."

**Naming**: `lib/parser.ml` already exists and is wand's own language
parser (`parse_type_expr`, `parse_ctor_fields`, etc. — actively
maintained, touched repeatedly this session). The new PEG interpreter
needs a different module name — e.g. `lib/peg.ml` — with a thin
`stdlib/Parser.wand` wrapper exposing it, matching how `JSON`/`TOML`/`CSV`
each pair a native `.ml` implementation with a stdlib `.wand` file.

No external dependencies needed — pure OCaml implementation either way.

## Sequencing

1. Land mutual recursion in wand (prerequisite, blocks everything below).
2. Implement the core PEG interpreter in `lib/peg.ml` (closure-based, not
   a tree) with `bind`.
3. Add combinators and captures; resolve the `capture`/`group` semantic
   question above.
4. Add `stdlib/Parser.wand` wrapper.
5. Decide Regex's fate (add `Parser` alongside it, most likely, rather
   than removing it) — if removal is still wanted after reconsidering,
   scope it as its own separate plan given the real blast radius above.
6. Tests: the three grammars tested here (INI, nested/recursive config,
   length-prefixed binary) are a reasonable starting test suite — port
   them from the throwaway OCaml prototype into real wand code once
   mutual recursion lands.

# Parsing helpers (not a combinator library)

## Context

`.claude/plans/parser.md` (a full PEG combinator library — `Parser` type,
`seq`/`choice`/`many`/`bind`, etc.) was rejected after testing it directly:
a standalone OCaml prototype matching that API, plus a real hand-written
recursive-descent grammar (`block`/`attr`/`body_item`/`body`, 4-way
mutually recursive) written directly in wand using ordinary pattern
matching and `and` (see `.claude/plans` git history and
`test/test_script.ml`'s `test_mutual_recursion`) — the hand-rolled version
worked cleanly on the first real test. A combinator library duplicates
that capability behind a brand-new bespoke API, which is a real cost for
an LLM writing wand: broad prior exposure to regex and to hand-written
recursive descent doesn't transfer to a wand-specific combinator naming
scheme. Regex already covers the flat/non-recursive case well; mutual
recursion (implemented) now covers the recursive case via plain functions.
So: no `Parser` type, no `bind`, no new opaque type.

What hand-writing that grammar actually surfaced as missing were two
small, targeted gaps — not a missing capability class, just missing
utility functions. Both below.

## 1. `String.match_all` — the real gap for tokenizing

Worked around the lack of a real tokenizer using `String.words`
(whitespace-only splitting), which only works if every token in the input
happens to be surrounded by spaces — unrealistic for real input like
`block{x="1"}`. wand already has full regex support (`r/pattern/`,
`replace_all_re`, `split_re`), which implies the underlying `Re` library
already finds all matches internally for replacement — there's just no
function that hands that list back to the caller:

```
String.match_all : Regex -> String -> List String
```

```
import String
String.match_all r/[a-zA-Z_]\w*|[{}=,]|"[^"]*"|\d+/ "block{x=\"1\"}"
-- ["block", "{", "x", "=", "\"1\"", "}"]
```

With this one function, tokenizing is just picking a good regex pattern —
no new API surface beyond regex, which is already well understood.

## 2. `List.take_while` / `List.drop_while`

`List.take`/`List.drop` (count-based) already exist in the stdlib. The
predicate-based versions are the natural extension, not parsing-specific,
useful for any "keep going while a condition holds" list operation:

```
List.take_while : ('a -> Bool) -> List 'a -> List 'a
List.drop_while : ('a -> Bool) -> List 'a -> List 'a
```

Combined with `String.chars` (already exists), these cover character-
classification-style scanning (skip whitespace, read an identifier) —
`List.take_while (fn c -> c >= "a" && c <= "z") (String.chars s)` — with
no bespoke `is_alpha`-style predicates needed as new stdlib surface.

## Implementation

Both are small, additive, no new types:

- `String.match_all`: native builtin in `lib/evaluator.ml` (mirror
  `replace_all_re`'s existing match-finding logic, return the matches
  instead of substituting them), typed in `lib/typechecker.ml`'s
  `stdlib_type_env` as `TFun (TRegex, TFun (TString, TList TString))`,
  thin `stdlib/String.wand` wrapper alongside the existing regex
  functions.
- `List.take_while`/`List.drop_while`: pure `stdlib/List.wand` functions,
  no native code needed — ordinary recursive pattern-matching functions
  exactly like `List.filter`/`List.take` already are.

## Sequencing

1. `String.match_all` (native builtin + stdlib wrapper).
2. `List.take_while` / `List.drop_while` (pure stdlib, independent of #1).
3. Tests: `String.match_all` against a tokenizing-style regex (the
   `block{x="1"}` example above is a good direct test); `take_while`/
   `drop_while` against basic list cases (empty list, no matches, all
   match, partial match).
4. README: add `match_all` to the `String`/`Regex` stdlib listing; add
   `take_while`/`drop_while` to the `List` stdlib listing.

## Verification

- `dune build && dune test` green.
- `dune exec wand -- e 'import String; String.match_all r/\d+/ "a1b22c333"'`
  → `["1", "22", "333"]`.
- `dune exec wand -- e 'import List; List.take_while (fn x -> x < 3) [1, 2, 3, 4, 1]'`
  → `[1, 2]`.
- Re-run the `block`/`attr`/`body_item`/`body` grammar from the mutual-
  recursion work, replacing its `String.words` tokenizer with
  `String.match_all` on a real (unpadded) input string like
  `block{x="1" nested{y="2"}}`, to confirm this actually closes the gap
  it was scoped to close.

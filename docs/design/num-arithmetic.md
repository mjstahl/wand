# Design: polymorphic arithmetic over `Num`

**Status: proposal — not implemented.** Review before code; the doc
retires once the reference documents the shipped behavior.

## The problem

`+ - * / %` are typed `Int -> Int -> Int`, and `Float` is a literal you
can compare, print, and decode but not compute with. The cold-model run
made this concrete: the shapes task (`3.14 * r * r`) was unwinnable in
every arm, because no spelling of float arithmetic exists. The drift
errors already tell people what *isn't* the answer ("operators are not
spelled differently for Float"); the language owes them the answer.

## The position

Arithmetic operators become polymorphic over `Int` and `Float` through a
**numeric-constrained type variable** — a third variable kind beside
ordinary and effect-row variables, permitted to resolve only to `Int` or
`Float`.

Why not the neighbors' answers: OCaml's `+.` split exists for unboxed
native-code floats, a constraint wand does not have — the evaluator's
values already carry tags, so dispatch is what it does all day. Haskell's
type classes buy open-world generality at a machinery price (constraint
schemes, dictionaries) that would dominate the typechecker for one
feature. SML's overloading is the right size — minus its worst part,
which wand gets to skip (next section).

## No defaulting

SML resolves an unconstrained `fn x => x + x` by defaulting to int at
generalization, which makes `double 1.5` fail far from the definition.
wand keeps the variable: `let double x = x + x` stays `Num -> Num`, and
the evaluator dispatches on the value's tag at each call — `double 2`
and `double 1.5` both work, `double "a"` is a static error. The
interpreter pays for polymorphism with the tag test it was already
doing; there are no dictionaries and no distant errors.

Literals stay monomorphic: `1` is `Int`, `1.5` is `Float`, so `x * 2`
pins `x` to `Int` through ordinary unification. Nothing about existing
code moves.

## The rules

- **No implicit mixing.** `1.5 + 1` stays a type error; conversion is
  explicit and named (below). The message can now say where to go:
  `cannot unify Float with Int -- Int.to_float and Float.round convert
  explicitly`.
- **`%` stays Int-only.** Float modulo is a niche with sharp edges;
  restricting it costs one line of the card.
- **Comparisons are already polymorphic** (`'a -> 'a -> Bool`) and do
  not move.
- **Unary minus** joins the constraint (`- 1.5` works).
- **Int overflow keeps raising; Float keeps IEEE semantics** (infinity
  and NaN are values, not raises) — each type keeps the behavior it has.

## The spelling: `Num`

The constraint prints and annotates as `Num`, an ordinary capitalized
type name — the type grammar gains nothing, only the resolution of one
name changes (to a fresh numeric-constrained variable). `double : Num ->
Num` reads next to `Int` and `Float` as "either, consistently". The one
prior association the word carries — Haskell's `Num` — is a constraint
there too, so the borrowed intuition is the correct one.

Annotation semantics: each written `Num` is a fresh numeric variable,
and use-sites link them — `let f x y : Num = x + y` infers the linkage
from `+` itself. Known edge, accepted and documented: a signature with
two *independent* numeric variables (`fn x y -> (x + x, y * y)`) prints
both as `Num`, losing the independence in display; pasting it back
reconstructs the common case, not that one. Scripts do not write that
function.

## Companion surface: conversions

Polymorphic arithmetic makes the missing conversions load-bearing:

- `Int.to_float : Int -> Float`
- `Float.round / Float.floor / Float.ceil : Float -> Int`
- `Float.abs`, and `Int.abs` if absent

Where they live follows the stdlib's shape (a small `Float` module, and
`Int` gaining members if `Int` exists as a namespace; otherwise both
join the module list). `String.to_float` already exists for parsing.

## What is touched

- `typechecker.ml`: the new variable kind — unification (`Num ~ Int` ok,
  `Num ~ Float` ok, `Num ~ Num` ok, anything else fails with a message
  naming the two members), constraint-preserving generalization and
  instantiation, `Num` in type display and in annotation resolution.
- `evaluator.ml`: `VFloat` arms for `+ - * /` and unary minus.
- Stdlib: the conversion functions; reference signatures test extended.
- Docs: Primitives (Float becomes computable), Type annotations (`Num`),
  the syntax card's one new line.
- The float-operator drift messages are already worded for this future
  ("operators are not spelled differently for Float") and do not change.

## Test plan

- Inference: `fn x -> x + x` is `Num -> Num`; applying it at both types;
  `x * 2` pins Int; `1.5 + 1` errors with the conversion hint;
  `"a" + "b"` errors naming `++`; `%` rejects Float; annotations with
  `Num` round-trip through `:t` output.
- Evaluation: Int and Float paths per operator; Int overflow still
  raises; Float infinity/NaN are values; unary minus both types.
- Generalization: a `Num`-polymorphic helper used at both types in one
  program; a helper pinned by a literal stays pinned.
- Conversions: round-trips, `Float.round` behavior on negatives stated
  and tested.
- The cold-model shapes task (task06), replayed: converges.

# `Int`, `Ord`, and the missing aggregates

`Float.abs` exists. `Int.abs` does not, because there is no `Int` module.
`List.sum`, `List.max` and `List.min` do not exist either, and two shipped
examples fold them by hand. This document is the design record for closing
that, and its first finding is that "add an `Int` module" is the wrong
description of the work. It is a record of decisions and their reasons,
written before the code. It is not a specification.

- [One item, three homes](#one-item-three-homes)
- [max and min are already writable](#max-and-min-are-already-writable)
- [Where the Ord operations live](#where-the-ord-operations-live)
- [The name Ord](#the-name-ord)
- [The List aggregates](#the-list-aggregates)
- [What is left for Int](#what-is-left-for-int)
- [Conversions stay where they are](#conversions-stay-where-they-are)
- [Path is not ordered, and could be](#path-is-not-ordered-and-could-be)
- [Left out on purpose](#left-out-on-purpose)
- [Order](#order)

## One item, three homes

The functions people reach for when they notice `Int` is missing do not all
belong to `Int`:

- `max`, `min`, `clamp`, `between?` are **`Ord`-polymorphic**. They work on
  ten types, and putting them on `Int` would either lose nine or invite nine
  copies.
- `sum`, `max`, `min` **over a list** belong to `List`, and they are
  writable in wand today.
- `abs`, `pow`, `divmod`, `max_value`, `min_value` are the genuine `Int`
  remainder.

Only the first needs a decision. The second is free. The third is a small
module that finishes a symmetry.

## `max` and `min` are already writable

```console
$ wand t -e 'let max a b = if a > b then a else b'
max : Ord -> Ord -> Ord
```

Nothing in the compiler has to change for that, and the constraint is real:
one definition serves `max 30s 2min`, `max 1.2.3 1.10.0` and `max "a" "b"`
in the same file. `Ord` covers ten types — `Int`, `Float`, `String`,
`Duration`, `DateTime`, `Size`, `Version`, `Port`, `IPv4` and `CIDR`.

The reference already writes this function out as the illustration of the
constraint:

```ocaml
let later a b = if a < b then b else a     -- later : Ord -> Ord -> Ord
```

So the gap is not capability. It is that everyone writing a script has to
write `later` again, under a name of their own choosing, and no two files
agree on it.

## Where the `Ord` operations live

Three options, and one of them is right.

**A copy per type module** — `Int.max`, `Float.max`, `Duration.max` and
seven more — is nine functions that must stay identical, in a language whose
constraint system exists precisely so they need not be written nine times.
It also answers badly the moment an eleventh type becomes ordered.

**Bare names in scope** breaks a rule the reference states plainly: every
function comes from a module. Only `Ok`, `Error`, `Some` and `None` live
without one, and they are constructors rather than functions.

**An `Ord` module** is the answer:

```ocaml
Ord.max     : Ord -> Ord -> Ord
Ord.min     : Ord -> Ord -> Ord
Ord.clamp   : Ord -> Ord -> Ord -> Ord      -- low, high, value
Ord.between?: Ord -> Ord -> Ord -> Bool
```

The precedent is exact. `Option` and `Result` are each both a module and a
name that appears in types — `Option.map` beside `Option String`. A reader
who sees `Ord -> Ord -> Ord` in a signature and reaches for `Ord.max` finds
it where they looked, which is the whole value of matching the two names.

`clamp` goes here rather than on `Int` for the same reason as `max`: it is
two comparisons, and clamping a `Duration` or a `Size` is as ordinary as
clamping an `Int`.

## The name `Ord`

`Ord` is short for ordered, and it is inherited from ML and Haskell rather
than coined here. The reference now says so in as many words, which it did
not before this document.

It is fair to ask whether the abbreviation belongs, because the project has
refused type-theory vocabulary once already:

> (The representation is an open record of labels, which type theory calls a
> row. The word is not used here or anywhere else: it names the encoding
> rather than the idea, and a reader of this compiler does not need it.)

`Ord` passes the test that `row` failed. `row` names the encoding; `Ord`
names the idea, and the idea is one a reader of a shell script already has.
What it fails is a smaller test: it is an abbreviation, and the error
message next to it uses the whole word — *Regex is not ordered*.

The name stays, for two reasons. It appears in every printed signature,
where `Ord -> Ord -> Ord` scans and `Ordered -> Ordered -> Ordered` does
not. And it sits in a trio with `Num` and `Add`; renaming one leaves the set
less consistent than it is, and renaming all three lands on `Number`, `Add`
and `Ordered`, which is a noun, a verb and an adjective.

Expanding it once in the reference costs nothing and removes the shibboleth.
That is the fix, and it is already made.

## The `List` aggregates

`List.sum`, `List.max` and `List.min` are missing, and two examples that
ship with wand fold them by hand:

```ocaml
-- examples/ports/dir-budget.wand:32
|> List.fold_left (fn total size -> total + size) 0B

-- examples/ports/pod-restarts.wand:38
|> List.fold_left (fn total (c: Container) -> total + c.restartCount) 0
```

**`sum` is `Add`-polymorphic, and getting that right decides its type.** A
literal zero pins the result:

```console
$ wand t -e 'let f (x: Num) = x + 0'
f : Int -> Int
```

Folding from the head instead of from a literal keeps the constraint:

```console
$ wand t -e 'let sum xs = match xs with
| [] -> None
| [h :: t] -> Some (List.fold_left (fn a x -> a + x) h t)'
sum : List Add -> Option Add
```

`Add` is `Int`, `Float`, `Size` and `Duration`, so one function totals a list
of file sizes — which is exactly what `dir-budget.wand` is doing above, and
what an `Int`-only `sum` would have left it doing.

```ocaml
List.sum : List Add -> Option Add
List.max : List Ord -> Option Ord
List.min : List Ord -> Option Ord
```

**The `Option` is the price of the polymorphism, and it is honest.** A sum
of nothing has no unit to answer with: `0` would be an `Int` and would pin
the type, which is the whole problem. `List.head` already returns an
`Option` for the empty case, so the shape is not new.

**Whether `sum` gets a `!` sibling is open.** The naming rule implies one,
and raising because a list was empty is a poor trade. `List.sum xs |>
Option.default 0B` says what it means. The recommendation is to ship without
`sum!` and add it if the call sites ask.

## What is left for `Int`

```ocaml
Int.abs       : Int -> Int
Int.pow       : Int -> Int -> Int
Int.divmod    : Int -> Int -> (Int, Int)
Int.max_value : Int
Int.min_value : Int
```

Five, against `Float`'s six. The module is proportionate, and it exists
mainly to end an asymmetry: a script that wants the absolute value of a
`Float` has `Float.abs`, and one that wants it for an `Int` has to write the
conditional.

`abs` is `Int`-specific rather than `Num`-polymorphic for the reason above —
`if n < 0 then 0 - n else n` pins to `Int` at the literal, and `Float.abs`
already exists on the other side.

`max_value` and `min_value` are worth naming because the runtime already
knows them and says so:

```
integer overflow in '+': Int holds -4611686018427387904 to 4611686018427387903
```

An `Int` is 63 bits and overflow raises rather than wrapping. That is already
documented at `reference.md:84`, including why `+` does not carry `Raise`, so
these two constants are a convenience rather than a new fact.

## Conversions stay where they are

`Int` gets no `to_string` and no `to_float`. wand already puts a conversion
on the type it produces:

```ocaml
String.of_int : Int -> String
String.to_int : String -> Option Int
Float.of_int  : Int -> Float
```

The target owns the conversion. Adding `Int.to_string` would give one
conversion two names, and the rule would stop being a rule.

## `Path` is not ordered, and could be

`Path`, `Glob`, `URL` and `Regex` are outside the ordered set. A path can
obviously be alphabetized, so this looks like an omission. It is not one,
and the reason is stated in the compiler:

> Ordering compares normalized values, never the stored string. A `DateTime`
> carries an offset, so two spellings of one instant must compare equal.

A path has several spellings for one file — `/a/b`, `/a//b`, `/a/./b`,
`/a/c/../b` — and `Path.normalize` exists but is not applied on the way in.
Ordering the stored text would therefore sort two names of one file apart,
which is the thing the rule above exists to prevent.

Two honest qualifications belong with that.

**Sorting paths already works.** `<` is not the only route:

```console
$ wand t -e 'List.sort [/b, /a]'
List Path
```

`List.sort` takes a list of any type, so alphabetizing paths is available
today. It is the operator that is withheld, not the capability.

**The inconsistency the rule prevents already exists at `==`.**

```console
$ wand -e 'import IO
IO.println (/a/b == /a//b)'
false
```

Equality compares the stored text too, so two spellings of one file are
already unequal. Withholding `<` is a decision not to *extend* text
comparison, rather than a guarantee that text comparison never happens.

**And the set is designed to grow.** The compiler says so where it builds
the error:

> The ordered set grows as types gain a normalizer, so the message names the
> type that is not in it rather than listing the set.

So `Path` is a candidate rather than a refusal. Admitting it means applying
`Path.normalize` on the way in, which changes what `==` answers as well —
a breaking change worth making on its own terms, not as a rider on this
document.

## Left out on purpose

**A `Num` module.** `Num` has no operations of its own that are not already
operators. `+`, `-`, `*` and `/` are the interface, and a module holding
nothing but conversions would duplicate `String` and `Float`.

**`Int.of_string`.** `String.to_int` is the same function under the rule
above.

**`Ord.compare` returning an ordering.** The reference refuses one twice,
for `Version` and for `IPv4`, on the same ground both times — *there is no
`compare` here for that reason*, the reason being that the language already
orders the type. `<` and `List.sort` are the interface, and a three-valued
result would be a second one.

**`Int.random`.** `Random.int lo hi` exists and carries the `Random` effect,
which is where that belongs.

## Order

`List.sum`, `List.max` and `List.min` first. They are free, they are written
in wand, and they delete a fold from two shipped examples.

`Ord` next — it is the only decision in this document, and the module is
four functions once it is made.

`Int` last. It is the smallest gain of the three, and nothing depends on it.

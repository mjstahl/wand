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
- [Admitting Path to the ordered set](#admitting-path-to-the-ordered-set)
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

So `Path` is a candidate rather than a refusal. The next section is what
admitting it takes.

## Admitting Path to the ordered set

The work is not "apply `Path.normalize`". It is smaller than that in one
place and larger in another.

### The comparison form is weaker than `Path.normalize`

```console
$ wand d Path.normalize
Path.normalize : Path -> Path
Resolve . and .. components in a path.

Text only: nothing is asked of the file system, so a `..` is dropped
whether or not the directory above it exists.
```

That function resolves `..`, and `..` cannot be resolved without the file
system:

```
/a/c/../b       -- /a/b, unless c is a symlink to /x/y, in which case /x/b
```

Every lexical normalizer has this bug, and wand's is honest that it is text
only. But a comparison must not have it: saying two paths are equal when
they may be different files is worse than saying nothing. So the form used
for `==` and `<` applies only the rewrites that hold whatever the disk
contains:

| rewrite | example | safe |
|---|---|---|
| collapse repeated separators | `/a//b` → `/a/b` | yes |
| drop `.` segments | `/a/./b` → `/a/b` | yes |
| strip a trailing separator | `/a/b/` → `/a/b` | yes |
| resolve `..` | `/a/c/../b` → `/a/b` | **no** — symlinks |
| fold case | `/A/b` → `/a/b` | **no** — per filesystem |
| make relative absolute | `./b` → `/cwd/b` | **no** — needs an effect |

The last row is worth its own sentence. Resolving a relative path needs the
working directory, so it would make comparing two paths perform `FS.Read`
or `Env`. A comparison operator that carries an effect is not one wand
should have, so `./b` and `/cwd/b` stay unequal and that is correct.

`Path.normalize` keeps its behaviour and its name. It answers a different
question — *what is this path with the dots taken out* — and a caller who
wants `..` resolved against the real disk wants something else again, which
wand does not have and which would carry `FS.Read` when it arrives.

### Normalize at the comparison, not at construction

`DateTime` is the precedent, and it says which end to do this at. It stores
an offset and compares instants, so two spellings of one moment are equal
while the source keeps whichever spelling was written.

Paths follow. `Path.to_string` returns the text the script wrote, and the
comparison operators compute the form above. Nothing is lost, no literal is
rewritten behind the author's back, and the compiler's own rule is
satisfied literally: *ordering compares normalized values, never the stored
string.* It never said values are stored normalized.

### What this breaks

One thing, and it is a fix:

```console
$ wand -e 'import IO
IO.println (/a/b == /a//b)'
false                              -- today
true                               -- after
```

Two names for one file stop being unequal. Every script that compares a path
it built against a path it read back — from `FS.list_dir`, from a glob, from
a command's output — is a script that can be wrong about this today.

The reference lists **ten** ordered types. It becomes eleven, and the
`Comparison and Ord` table needs `Path` added.

### Glob, URL and Regex stay out

They are not the same problem wearing different names.

A `Glob` has no normal form worth the word: `*.wand` and `./*.wand` mean
different things by wand's own rule that a relative glob with a directory
part needs the `./` prefix, and `a*b*` against `a*b*c*` is a question about
languages rather than strings.

A `URL` has a normal form and it is a specification of its own — default
ports, percent-encoding case, trailing slash on an empty path, host case
against path case. `URL` already carries accessors for every part, so a
script that wants to compare origins can compare origins.

A `Regex` orders on nothing. Two patterns that match the same strings can be
written a dozen ways, and text order across them means nothing at all.

### Whether it is worth doing

The honest accounting: the valuable half is `==`, not `<`.

Sorting paths already works through `List.sort`, so admitting `Path` to the
ordered set buys the operators and little else — a path range check is not a
thing anyone wants. What it really buys is equality that answers about files
instead of about text.

That suggests a cheaper option worth naming before the breaking one is
taken: `Path.same?`, comparing the two paths in the form above, added
without touching `==` or the ordered set. It is honest, it is not a breaking
change, and it leaves `==` quietly wrong for anyone who does not know to
reach for it.

**Recommend the breaking change rather than `Path.same?`.** A predicate that
exists because the operator is wrong is a worse outcome than fixing the
operator, and wand has no outside users, so `==` changing its answer costs
nothing now and costs everything later.

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

# Interfaces

wand has three constraints — `Num`, `Add` and `Ord` — and they are built into
the typechecker as a variant of four cases. A type is ordered because
`is_ordered` in `typechecker.ml` names it, not because it implements
anything. Nothing a user writes can join that set.

The seam already shows. `List.sort` orders a type you declare, by its
declaration order, while `<` on that same type is a type error:

```
type S = Zulu | Alpha
List.sort [Alpha, Zulu]     -- [Zulu, Alpha]
Zulu < Alpha                -- type error: S is not ordered, so it cannot
                            -- be compared with < > <= >=
```

And 0.79.0 wrote out by hand what a rule would have produced: `max`, `min`,
`clamp` and `between?` on each of the eleven ordered types, forty-four
members, each one a line over the same comparison. An interface is that rule.

This document records what is settled and states the rest as questions to be
answered rather than discovered. It is written before the code and is not a
specification.

- [What the three constraints are today](#what-the-three-constraints-are-today)
- [What 0.79.0 already put in place](#what-0790-already-put-in-place)
- [The syntax](#the-syntax)
- [Where the names land](#where-the-names-land)
- [Dispatch, and the line it draws](#dispatch-and-the-line-it-draws)
- [What is settled](#what-is-settled)
- [Questions](#questions)
- [Order](#order)

## What the three constraints are today

```ocaml
and constrained = Free | Ord | Add | Num
```

A chain, not a set: every `Num` is an `Add`, and every `Add` is an `Ord`.
Unifying two constrained variables takes the narrower of the two, which a
variant expresses and a flag per constraint could not. `constrained` is not
mutable — a variable is created at its constraint and narrowed by
unification.

There are no implementations anywhere. Comparison is a builtin, the
typechecker admits eleven types to it by name, and the evaluator dispatches
on the value's tag. That is why a constrained variable stays generalised and
why `let double x = x + x` works at both numeric types with no defaulting.

Interfaces are not a chain. A type may implement two that have nothing to do
with each other, so a variable carries a *set* of constraints and unification
takes the union where it now takes a minimum.

## What 0.79.0 already put in place

`'a: Ord` is a type wand reads and writes. It parses, typechecks, prints,
formats, round-trips through `wand d` into an annotation, brackets itself in
an argument position (`List ('a: Ord)`), binds wherever it is written rather
than only where the variable is first created, and rejects a name that is not
a constraint:

```
Error: type error: 'Nope' is not a constraint; the constraints are Num, Add and Ord
```

That is the whole surface an interface bound needs, and only two things in it
assume the set is closed: the `match` on the constraint name, and the variant
above. One gap remains — a qualified name does not parse:

```
let f : 'a: Foo.Ord -> 'a = fn x -> x
-- parse error: expected =, got .
```

The constraint position takes a bare `Upper`. Reaching an interface declared
in another file needs one more branch there.

## The syntax

An interface is declared the way a type is, because wand already has this
shape and it means the same thing — a name, a type parameter, and a list of
named things with their types:

```
type Box 'a(value: 'a, label: String)     -- this is valid wand today

interface Ord 'a(
  max: 'a -> 'a -> 'a,
  min: 'a -> 'a -> 'a
)
```

The parenthesised, comma-separated field list is what the formatter already
breaks one-per-line when it is wide, with the closing bracket on its own
line. So the declaration needs no new separator, no new layout rule and no
formatter work. The keyword in front says whether the members are a value's
fields or a type's operations.

An implementation is a run of bindings, which wand writes with `;` and the
formatter produces unprompted:

```
implement Foo.Ord Int =
  let max a b = if a > b then a else b;
  let min a b = if a < b then a else b
```

`let` is the vocabulary inside because an implementation defines values, not
a type. `implement Foo.Ord Int` puts the interface before the type, matching
how a parameterised name is written everywhere else.

## Where the names land

On the implementing type's module. `implement Foo.Ord Int` declares `Int.max`
and `Int.min`.

The alternative is the interface's own module — `Foo.max 3 7`. That is
`Ord.max`, which this same release deleted, and for the reason that decides
this: holding two Ints, `Int` is where a reader looks, and nothing about an
Int points at `Ord`.

It also means the standard library's own comparisons are the first
implementations. The forty-four members 0.79.0 added by hand are what
`implement Ord <type>` produces for eleven types, so the rule can replace the
hand-written copies rather than sit beside them.

## Dispatch, and the line it draws

The evaluator dispatches on the value's tag. That is enough for any member
whose type variable appears in an argument position — `max`, `min`, `show`,
`encode` — because the value at the call site says which implementation to
use. It is not enough where the variable appears only in the result:

```
zero  : 'a
empty : 'a
parse : String -> 'a
```

There is no value to read the type from, so the implementation has to be
passed in, and that is dictionary passing: a second calling convention, a
representation for a dictionary, and a story for where one comes from at
every call. It is a larger project than everything else in this document put
together.

The line to draw is a rule on the declaration, checkable where it is written:
**an interface member must take its own type as an argument.** With that
rule, dispatch is a lookup keyed by the tag wand already reads, and no
dictionary exists. Without it, dispatch is the feature and the syntax is a
detail.

## What is settled

1. **Names land on the implementing type's module.** `implement Foo.Ord Int`
   declares `Int.max`, not `Foo.max`.
2. **An interface is declared like a type** — a parenthesised,
   comma-separated list of `name: Type`, parameterised by the type variable.
3. **An implementation is a run of `let` bindings**, separated the way the
   formatter already separates bindings.

## Questions

**Do `Num`, `Add` and `Ord` become interfaces?** Leaving them built in gives
wand two constraint systems side by side, one closed and one open, and a user
who writes `interface Ord 'a(...)` collides with a name the checker already
owns. Making them stdlib interfaces gives one system and closes the
`List.sort` seam above. It also puts the eleven `is_ordered` types behind
eleven implementations, and makes `<` a member, which raises whether an
operator can be an interface member at all.

**May a member have its type variable only in the result?** The section above
recommends no. It is the hinge: the answer decides whether this is a contained
feature or a new calling convention.

**What does a variable carrying several constraints print as?** `'a: Ord` has
one name after it. Two need a spelling — `'a: Ord + Show`, or something else
— and the answer has to be writable, because every type wand prints can be
pasted back as an annotation.

**Who sees an implementation?** A user file writing `implement Foo.Ord Int`
adds a name to a module it does not own. Is that name visible to every file
in the run, only to files that import the implementing one, or only inside
the file itself? Each answer is a different language.

**What happens when two files implement the same pair?** Both may be imported
by a third. Refusing the second is simplest; refusing at the point of import
is friendlier; choosing one silently is not an option.

**What happens when an implementation collides with a name already on that
module?** `Int.max` exists today. wand's rule is that a name declares one
thing, so this should be an error naming which to rename — unless the stdlib
comparisons are themselves reimplemented as interface implementations, in
which case the collision is the migration.

**Can an interface be implemented for a type in another module?** `Int` is a
stdlib module, so the first implementation anyone writes is already this
case, and answering no outright is not open.

Answering it narrowly is what makes the two questions above go away. Allow an
implementation only where the type is declared, and there is one place each
pair can be written: two files cannot both implement `Ord` for `Int`, and who
sees one is whoever can see the type. Allow it anywhere, and both questions
come back, and between them they are the whole of stopping one program from
seeing two implementations of one pair.

**What does `wand d Int` show?** An implemented member is on `Int` and
declared in an interface. The doc, the signature and `wand d --index` all
have to say something, and whether it names the interface it came from is a
decision about how a reader learns that `Int.max` is not hand-written.

## Order

1. Answer the dispatch question. Nothing below is worth designing until the
   answer to "only in the result" is settled, because a no keeps this
   contained and a yes makes dictionary passing the project.
2. Decide whether `Num`, `Add` and `Ord` become interfaces. That decides
   whether this is a new system or a replacement for one, and the name
   collision makes it unavoidable rather than optional.
3. Turn the constraint from a chain into a set, with the printed spelling for
   several constraints. This is the contained part and it is testable on its
   own, against the three constraints that exist now.
4. The declarations: `interface` and `implement`, the qualified constraint
   name in the parser, and the formatter cases.
5. Dispatch and the visibility rules, which are one piece of work because
   neither can be tested without the other.

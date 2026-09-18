# Interfaces

wand can already pass a module around as a value. This runs:

```
let m = import Int

IO.println (m.max 3 7)     -- 7
```

And a record of functions works end to end:

```
type Ordering(max: (Int -> Int -> Int), min: (Int -> Int -> Int))

let biggest (o: Ordering) a b = o.max a b
```

What fails is the step between them:

```
let biggest m a b = m.max a b
-- 'm' needs its type before '.max' can be read, and no type declares a
-- field 'max'
```

There is no type you can write for a parameter that is a module. That is the
whole of what is missing, and an interface is that type.

This document records what is settled and states the rest as questions to be
answered rather than discovered. It is written before the code and is not a
specification.

- [What an interface is here](#what-an-interface-is-here)
- [The syntax](#the-syntax)
- [What this is not](#what-this-is-not)
- [What is settled](#what-is-settled)
- [Questions](#questions)
- [Order](#order)

## What an interface is here

An interface is a contract on a **module**: the functions that module must
provide. It is not attached to a type, and it makes no claim about one.

The type parameter is there so the member signatures come out concrete. In
`implement Foo.Ord Int`, the `Int` is what `'a` is bound to, so `max` in that
implementation has to be `Int -> Int -> Int`. It is instantiation, not
dispatch.

That reading answers the questions an interface usually drags with it, by
removing them:

- **Nothing is registered anywhere**, so there is no table of implementations
  to keep consistent, and no orphan.
- **Nothing is hoisted.** The names land in the implementing module because
  that is the file they are written in. `Int.max` is one of `Int`'s bindings,
  like the rest.
- **A module owning several types is fine.** The implementation names which
  type `'a` is, so `Digest`, which declares both `Algorithm` and `Digest`,
  has nothing to be ambiguous about.
- **Generic code needs no new runtime.** The caller passes the module, and a
  module is already a value.

```
let biggest (m: Foo.Ord 'a) (a: 'a) (b: 'a) = m.max a b
```

## The syntax

An interface is declared the way a type is, because wand already has this
shape and it means the same thing -- a name, a type parameter, and a list of
named things with their types:

```
-- in foo.wand
interface Ord 'a(
  max: 'a -> 'a -> 'a,
  min: 'a -> 'a -> 'a
)
```

`type Box 'a(value: 'a, label: String)` is valid wand today, so the
parenthesised, comma-separated list is what the formatter already breaks one
member to a line when it is wide, with the closing bracket on its own line.
The declaration needs no new separator and no new layout rule.

An implementation is a run of bindings, which wand writes with `;` and the
formatter produces unprompted:

```
-- in Int.wand
import ./foo

implement Foo.Ord Int =
  let max a b = if a > b then a else b;
  let min a b = if a < b then a else b
```

`let` is the vocabulary inside, because an implementation defines values.
`implement Foo.Ord Int` puts the interface before its argument, matching how
a parameterised name is written everywhere else.

`Foo.Ord Int` is then a type -- the type of a module providing `max` and
`min` at `Int` -- and a parameter can be given it.

## What this is not

**It is not the constraint system.** `Num`, `Add` and `Ord` cannot become
interfaces, because a binary operator has nowhere to pass a module. `a < b`
takes two arguments and both are operands. `List.max` could take one --
`List.max Int [3, 1, 2]` -- but the operators are why the three constraints
exist at all, and they are enforced in one place: unification checks a
variable's constraint against `is_ordered`.

Resolving an operator would mean finding the implementation from the type of
its operands, which is a lookup keyed by interface and type. That registry is
the thing this design does without, and with it come the orphan, the
duplicate and the visibility rule.

So the two mechanisms are the two answers to where an implementation comes
from. The caller passes it: open, nothing registered, no use to an operator.
The compiler finds it from the type: works for operators, needs the registry.
`Num`, `Add` and `Ord` are the second, kept closed so the registry is a fixed
list of eleven types rather than a question.

The price is worth stating plainly: under this design a user will never make
their own type work with `<`. `List.sort` will keep ordering it while the
operator refuses it.

```
type S = Zulu | Alpha
List.sort [Alpha, Zulu]     -- [Zulu, Alpha]
Zulu < Alpha                -- type error: S is not ordered, so it cannot
                            -- be compared with < > <= >=
```

**It is not dispatch.** No implementation is looked up from a value's type.
The module arrives as an argument, so there is no dictionary, no table of
instances, and no call that has to work out where to go.

## What is settled

1. **An interface is a contract on a module**, not on a type. The type
   parameter is instantiation, so the member signatures come out concrete.
2. **An interface is declared like a type** -- a parenthesised,
   comma-separated list of `name: Type`, parameterised.
3. **An implementation is a run of `let` bindings** in the module it is
   about, separated the way the formatter already separates bindings.
4. **The names are the module's own.** Nothing is hoisted or registered;
   `implement` is a claim over bindings, checked against the interface.
5. **Generic code passes the module.** `let biggest (m: Foo.Ord 'a) ...`,
   with no new runtime mechanism.

## Questions

**Is conformance nominal or structural?** A module value's type is not unique
-- `Int` provides `max` and `min` at `Int`, so it fits `Foo.Ord Int`, and it
provides a great deal else besides. Does a module have to declare
`implement Foo.Ord Int` before it can be passed where that type is wanted, or
does any module with the right members fit? Nominal makes the claim
load-bearing. Structural makes `implement` a checked comment. Everything
below depends on the answer.

**May an implementation claim bindings that already exist?** `Int.wand`
already has `max : Int -> Int -> Int` and `min : Int -> Int -> Int`, written
by hand in 0.79.0. A block that declares them again collides with them, so
either the block is where they now live, or there is a bodyless form:

```
implement Foo.Ord Int
```

which asserts what the module already provides. It reads as what it is, and
it is the difference between claiming forty-four members and rewriting them.

**May `implement` be written outside the module it is about?** The block form
cannot be -- it declares bindings, and they land where they are written. A
bodyless claim could be, and then it is an orphan again, with every question
that comes back with it. Refusing it keeps the design's main simplification.

**May a module implement one interface twice?** `implement Foo.Ord Int` and
`implement Foo.Ord Float` in one module both need a `max`, and a module has
one namespace. So at most one instantiation per interface per module, and the
second is an error naming the first.

**Do interface members relax the bracket rule on an arrow?** A named field's
type may be an application written bare, but an arrow takes its brackets
either way -- `type Ordering(max: Int -> Int -> Int)` is a parse error today.
An interface member is always a function, so the arrow is expected rather
than a surprise, and `max: 'a -> 'a -> 'a` reads better than
`max: ('a -> 'a -> 'a)`. Relaxing it for members is defensible; it should be
done on purpose.

**What does a member's signature say about effects?** `max` performs nothing,
but a member that reads a file or runs a command has an effect set, and the
interface must be able to write it. A member's grammar is a type, so it
carries one already. What needs deciding is whether an implementation may
perform less than the interface allows, which is the question a manifest
answers with `A-USES1`.

**Does an interface name collide with a constraint name?** `Ord` is a name
the checker owns. An interface reached as `Foo.Ord` is qualified and does not
collide, but a bare `Ord` would be ambiguous between the two mechanisms.
Either an interface is always qualified, or the bare name is refused.

**What does `wand d Int` show?** A module's bindings are already listed. Does
the listing say which interfaces the module implements, and does `--index`
carry it? That is how a reader learns `Int.max` answers to a contract.

## Order

1. **Answer nominal or structural.** Nothing else is worth building first: it
   decides whether `implement` is a declaration the checker enforces or a
   comment it verifies, and the two produce different type rules.
2. **Answer the bodyless form**, because it decides whether this work moves
   the forty-four comparison members or leaves them where they are.
3. **A type for a module value.** This is the only real compiler work and the
   whole of the value: a parameter that can be annotated `Foo.Ord Int`, and a
   module value that satisfies it. Everything above is syntax over this.
4. **The declarations** -- `interface` and `implement`, their formatter cases,
   and the arrow rule for members.
5. **`wand d`**, once there is something to report.

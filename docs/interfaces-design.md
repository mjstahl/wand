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

implement Foo Int =
  let max a b = if a > b then a else b;
  let min a b = if a < b then a else b
```

`foo.wand` declares one interface, so `Foo` names it. `Foo.Ord Int` is the
same type written out, and a module declaring two interfaces has only the
long spelling. In the standard library the module is named for its interface,
so it reads `implement Ord Int`.

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
6. **Conformance is nominal.** `implement` is what makes a module fit. A
   module with the right members by accident does not, so being an `Ord` is
   something a module says rather than something a reader works out.
7. **There is no bodyless form.** A module conforms by having the
   implementation written in it. So the eleven ordered types in the standard
   library are rewritten to conform, and their comparisons move into
   `implement` blocks rather than being claimed where they sit.

   This closes the orphan for good. A block declares bindings, and bindings
   land in the file they are written in, so an implementation cannot be
   written anywhere but the module it is about. There is nothing to refuse
   and no rule to state -- the shape of the thing prevents it.
8. **A module implements an interface once, and wand already refuses the
   second.** Two `let`s of one name are clauses of one function, so
   `implement Ord Int` and `implement Ord Float` in one module declare `max`
   twice and the two equations will not unify:

   ```
   let f (x: Int) = x
   let f (x: String) = x
   -- type error: expected Int, got String
   ```

   No new rule is needed. What is left is the message: a reader gets
   `expected Int, got Float` pointing at `max`, which names the symptom. The
   cause is that a module implements an interface once, and `implement`
   should say so in those words.
9. **A named field's type may be written bare, arrow included.** So a member
   is `max: 'a -> 'a -> 'a`, and this is a change to `type` as much as to
   `interface` -- it is a relaxation of the parser, not a rule interfaces
   need for themselves.

   The line is the one wand already draws for an application. A named field
   is ended by the comma or the closing bracket, so nothing is ambiguous;
   a positional field is ended by nothing, which is why `type P = P List Int`
   reads as two fields today and keeps its brackets.

   The standard library already pays for this. `Test.wand` writes six fields
   with brackets they would not need:

   ```
   ok: (Bool -> TestOutcome),
   eq: ('a -> 'a -> TestOutcome),
   raises: ((Unit -> 'b ! 'e) -> TestOutcome ! 'e),
   ```

   `raises` keeps its inner pair, because an arrow that is the *argument* of
   an arrow needs them wherever it appears. The formatter must print a named
   field bare once the parser accepts it, or a writer puts one thing in and
   `wand f` gives another back.
10. **An implementation must perform no more than the interface declares.**
    A member's grammar is a type, so it carries an effect set already, and
    the implementation is held to it the way a file is held to its manifest:
    performing more than was declared is an error.

    Performing *less* is ordinary and says nothing, which is where this
    parts from `A-USES1`. A manifest and its file are one thing, so a
    manifest wider than the file is imprecise and worth a warning. An
    interface is shared by every module that implements it, so a member
    declared `! {FS.Read}` and implemented over memory is the interface
    doing its job, not a mistake.
11. **`wand d <Module>` lists what the module implements, above its
    members.** A heading, the interfaces indented under it one to a line,
    then a blank line, then the listing as it is today:

    ```
    $ wand d Int
    implements
      Bounded Int
      Ord Int

    Int.abs : Int -> Int
    Int.between? : Int -> Int -> Int -> Bool
    Int.clamp : Int -> Int -> Int -> Int
    Int.divmod : Int -> Int -> (Int, Int)
    Int.max : Int -> Int -> Int
    Int.max_value : Int
    Int.min : Int -> Int -> Int
    Int.min_value : Int
    Int.pow : Int -> Int -> Int ! 'e
    ```

    A module implementing nothing prints no heading and no blank line, so
    the other thirty-nine modules are unchanged.

    `Bounded` there is `max_value: 'a` and `min_value: 'a`, where the type
    variable is only in the result. That is the case the first draft of this
    design had to ban. Here it is unremarkable, because nothing is
    dispatched: `let limits (m: Bounded 'a) = (m.max_value, m.min_value)`.
12. **A member names the interfaces it answers to**, on its own line between
    the signature and the doc -- the slot `performs` already uses for a fact
    the type does not carry:

    ```
    $ wand d Int.max_value
    Int.max_value : Int
    implements Bounded
    The largest Int.

    >> Int.max_value
    4611686018427387903 : Int
    ```

    The interface names alone, comma-separated as `performs` writes its list,
    and each the name a reader would write. The member's own name is in the
    signature above, and so is the type, so `implements Bounded.max_value Int`
    would repeat two things the reader is already looking at. One binding answering to two
    interfaces needs no second shape:

    ```
    Int.max : Int -> Int -> Int
    implements Comparable, Ord
    ```

    Where a member has both lines, `implements` comes first: what it answers
    to, then what it does.
13. **`wand d --index` carries the interfaces.** Leaving it alone was the
    first answer and it was wrong. The index is what a model reads: with the
    language guide alone a model cleared 7 of 20 tasks, and with the guide
    and the index, 18. An interface absent from it is a feature a model never
    learns exists, and the fallback -- `wand d <Module>` per module -- is the
    loop measured at 5.4x the index's cost.

    Three things, and the first needs no new shape at all.

    **An interface's members list like any module's.** They are members.

    ```
    Ord.max : 'a -> 'a -> 'a
    Ord.min : 'a -> 'a -> 'a
    ```

    That alone puts the contract in front of a reader who has to write
    `implement Ord Int` or `(m: Ord 'a)`, and every line is still one name
    and one type.

    **A member names its interfaces after its type, in square brackets.**

    ```
    Int.abs       : Int -> Int
    Int.between?  : Int -> Int -> Int -> Bool [Ord]
    Int.clamp     : Int -> Int -> Int -> Int [Ord]
    Int.divmod    : Int -> Int -> (Int, Int)
    Int.max       : Int -> Int -> Int [Ord]
    Int.max_value : Int [Bounded]
    Int.min       : Int -> Int -> Int [Ord]
    Int.min_value : Int [Bounded]
    Int.pow       : Int -> Int -> Int ! 'e
    ```

    Square brackets because round ones are type application: `Int (Ord)`
    is how `List Int` is written, so a reader and a model copying the type
    into an annotation could both take the interface for a last argument.
    A `[` never appears in a wand type. Two interfaces are `[Comparable, Ord]`.

    The name in the brackets is the one a reader would **write** -- `Foo`
    where `foo.wand` declares the interface, not the interface's declared
    name -- because the point of the line is that it can be acted on.

    **Names are aligned within a module.** The column is set by the longest
    name in that module and resets at the next, which is what
    `docs/reference.md` already does. Not across the file: names run from 8
    to 23 characters, so one column would pad every short line by fifteen
    spaces. And not a third column after the type: the longest type in the
    library is 83 characters, which would start the interfaces past column
    130.
14. **`--index --json` carries it as a field.** The flag exists; each entry
    gains `implements` beside `name` and `type`, null where there is none.
    Tools read that and never the aligned text.
15. **A module that declares one interface resolves to it.** `Ord.wand`
   declaring `interface Ord 'a(...)` is reached as `Ord`, so the first thing
   anyone writes is `implement Ord Int` rather than `implement Ord.Ord Int`.
   The qualified spelling still works, and a module declaring two interfaces
   has no name to lend, so both are reached through it.

   wand forwards a name this way already, and across a name change: an alias
   to a single-constructor type builds one, so `type MyConf = Conf` gives
   `MyConf(port = :80)`. A module lending its name to its one interface is
   that rule a level up. Note it is the alias that does this and not a
   declaration -- `type Box = MkBox Int` leaves `Box 5` an error naming
   `MkBox` -- so the forwarding is something a second name does, which is
   what a module reaching its interface is.

## Questions

None open. What is left is the work in the order below.

## Order

1. **A type for a module value.** This is the only real compiler work and the
   whole of the value: a parameter that can be annotated `Foo.Ord Int`, and a
   module value that satisfies it. Everything above is syntax over this.
2. **The bare arrow in a named field.** A parser change and a formatter
   change, standing on its own: it is worth doing whether or not interfaces
   are, and `Test.wand` is the corpus case that shows it.
3. **The declarations** -- `interface` and `implement`, and their formatter
   cases.
4. **The standard library's own.** The eleven ordered types conform, which
   moves the forty-four comparison members into `implement` blocks and is the
   first real use of the feature.
5. **`wand d`**, once there is something to report.

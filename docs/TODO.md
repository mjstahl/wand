# Open work

What is known to be worth doing and is not done. An item leaves this file
when it ships, in the release that ships it. Nothing here is a commitment to
an order.

## Compiler and CLI

### `--fix` does not carry the naming corrections

`V-BANG2` and `V-PRED3` each name one correction to one name:

```
warning: 5:1: V-BANG2: 'safe!' cannot raise, so the `!` promises a risk that
  is not there; it is 'safe'
warning: 7:1: V-PRED3: 'big' returns Bool but is not named as a predicate
```

Both are determined, so `--fix` could apply them, and it does not. The other
two rules in the family cannot be applied and should stay reports.
`V-BANG1` asks for two functions rather than a new name -- "call it `boom!`
and give the plain name to a version that returns a Result". `V-PRED1` is a
name and a type that disagree, and nothing in the file says which of them is
the mistake.

What blocks the two that are determined is that all four fire on top-level
names only -- a local `let inner y = y > 0` is not flagged -- so every one
of them is on a module's public surface. Renaming there changes call sites
in files the command never opened, and `Fix.fix_file` takes one path. The
tree would stop building until every importer was edited by hand.

`wand t` takes a directory now, so the command can see the tree. What is
left is for a rename to reach the call sites in it.

### `wand t` reports one error per run

Every failing typecheck answers with a single error, so a file with six
unknown names takes six runs to clear. A person rereads the file each time;
a tool driving `wand t` in a loop pays a round trip per error.

Reporting the independent errors together would cut that to one pass.
Measured on 2026-09-10: repairing generated scripts against `wand t` took a
mean of 1.95 attempts with `--fix` applied first, and the attempts that
needed three or more were files with several unknown names and nothing else
wrong.

## Designed, not built

### Interfaces

A contract on a module: the functions it must provide. `docs/interfaces-design.md`
is the scope, and it is settled -- fifteen decisions, nothing open.

The shape of it:

```
interface Ord 'a(
  max: 'a -> 'a -> 'a,
  min: 'a -> 'a -> 'a
)

implement Ord Int =
  let max a b = if a > b then a else b;
  let min a b = if a < b then a else b
```

The record's order is a type for a module value, the two declarations, the
standard library's own conformance, and `wand d`. The bare arrow in a named
field was the fifth, and it shipped on its own. Only the first is real
compiler work: wand already passes a module as a value, and the one thing
missing is a type to give a parameter that is one.

## Beyond the compiler

Getting wand in front of the people who would use it is a distribution
question rather than a language one: a server that offers wand as an action
to the agents people already run, a plugin that bundles it, and a check that
gates a repository's scripts against a policy. That work is not listed here
as tasks because none of it is decided.

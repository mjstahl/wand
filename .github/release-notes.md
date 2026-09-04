## 0.58.0 - 2026-09-04

`:d` is the one way to ask the REPL what a name is. `:v` is retired.

### One question, three forms

```
:d              list the session: modules by name, bindings with their types
:d List         the module's members and their signatures
:d List.map     that function's doc string
```

Only the last of those worked before. `:d List` answered

```
List : <namespace>
List: no doc
```

which is two lines telling a reader nothing they can act on. A module is the
one name whose documentation *is* the list of what it holds, so that is what
it answers with now. It is the same output as `wand d List`, so the REPL and
the command agree.

### `:v` is retired

`:v` listed the session, and `:v List` listed a module's members. `:d`
answers both, so `:v` had nothing left of its own. It also shared a letter
with `wand v`, which means `version` and always did.

Typing `:v`, `:v List` or `:env` still answers:

```
:v is retired — :d lists the session, :d List lists a module
```

A pointer, rather than "Unknown command", because it was the way to ask for
a long time. Completion no longer offers either spelling: completing to a
command whose whole reply is "use the other one" wastes the keystroke.

### What this breaks

One thing, and only in the REPL. `:v` and `:env` no longer list anything.
Use `:d`, which takes the same argument and takes none the same way.

Nothing about the language, the standard library or a script's behaviour
changed in this release.

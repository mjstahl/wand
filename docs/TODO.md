# Open work

What is known to be worth doing and is not done. An item leaves this file
when it ships, in the release that ships it. Nothing here is a commitment to
an order.

## Standard library

### `String.lines` keeps the empty piece after a trailing newline

Nearly every file ends in a newline, so `String.lines` almost always hands
back one more element than there are lines, and the last one is `""`:

```
>> String.lines "a\nb\n"
["a", "b", ""]
```

Found by writing a log reader: asking for the last two lines gave one line
and a blank. `Shell.lines` documents the same rule and says so; this one
does not, and the caller has to filter. Either drop the trailing empty piece
or say in the doc that it is there.

### `String.to_*` has no raising sibling

Thirteen functions read text into a domain type, every one returns a
`Result`, and none has a `!` form:

```
>> String.to_url! "https://x/"
namespace 'String' has no member 'to_url!' (did you mean 'to_url'?)
```

The naming rule says a fallible function has a raising sibling, and
`String.word` / `String.word!` in the same module follows it. So the rule
has thirteen exceptions in one family. Either add the siblings or write the
exception down.

## Compiler and CLI

### `wand t` takes one file

There is no way to check a directory in one command:

```
$ wand t tools/*.wand
Error: too many arguments
```

`wand s` walks a directory looking for tests; `wand t` does not. That is the
gap between a file a model wrote and a file anyone should run, so it is the
command a deploy gate would be built from, and it has to be a shell loop
today.

### `wand f` costs more than the square of nesting depth

Formatting a deeply nested literal is slow enough to matter:

```
depth  500    0.6s
depth 1000    4.6s
depth 2000     48s
```

Measured, not guessed: the layout cache works and the emitter is called once
per node. The cost is that each level builds its own text by copying what
its children built, and the output of a deeply nested literal is genuinely
large, so the copying is the square of the depth and the whole is worse.
Fixing it means an emitter that tracks how wide a thing is rather than
measuring the text it already built.

It needs input no one writes by hand, which is why it is here rather than
fixed.

### A signature does not show that a constraint is one type

`Ord.max` takes two of the same type and answers with that type. The
signature does not say so:

```
Ord.max : Ord -> Ord -> Ord
```

Read cold, `Ord` looks like a type, and the three uses of it look
independent. They are one type, decided per call: `Ord.max 1 "a"` is a type
error. `Add` and `Num` print the same way.

The short form is worth a lot and a longer one would say more. This is a
decision about which, not a defect to fix.

### `wand t` reports one error per run

Every failing typecheck answers with a single error, so a file with six
unknown names takes six runs to clear. A person rereads the file each time;
a tool driving `wand t` in a loop pays a round trip per error.

Reporting the independent errors together would cut that to one pass.
Measured on 2026-09-10: repairing generated scripts against `wand t` took a
mean of 1.95 attempts with `--fix` applied first, and the attempts that
needed three or more were files with several unknown names and nothing else
wrong.

### `wand d --index`

Print every stdlib function with its type, for every module, in one
command. It exists today only as a shell loop:

```
for m in $(wand d); do wand d "$m"; done
```

This is also the answer to a second problem: you cannot find a function
from the value in your hand. Holding two `Int`s, `Int` is where you look,
and the function is `Ord.max`, because it serves all eleven ordered types
from one definition. Nothing about an `Int` points there.

That is 534 lines, and it is what a model needs in front of it to write
wand at all: given the language guide alone a model cleared 7 of 20 tasks,
and given the guide plus this index it cleared 18. A build artefact rather
than a loop, so the tools that need it can depend on it.

### `wand t --effects`

Print a file's inferred effect set as data, so a check can compare it with
a policy by exit code. `wand t --json` reports lint findings, and a clean
file reports `[]`, so there is no way to ask what a file reaches.

The set has to be the inferred one, never the `uses` line: a file with no
manifest is unbounded rather than sealed.

## Decisions, not changes

### Whether `Mod.X(...)` should read the module's names for its fields

`HTTP.Request(method = POST)` typechecks, because a qualified construction
reads that module's names for the whole expression, fields included. So
after 0.72.0 a method is written `HTTP.POST` everywhere except inside a
construction that already names `HTTP`.

This is the rule for every module, not something HTTP added, and it reads
the way a local open reads. Narrowing it to the constructor name alone
would make the spelling uniform and would touch every qualified
construction in the language. It is a decision about which reading is
right, and it should be made once rather than per module.

## Beyond the compiler

Getting wand in front of the people who would use it is a distribution
question rather than a language one: a server that offers wand as an action
to the agents people already run, a plugin that bundles it, and a check that
gates a repository's scripts against a policy. That work is not listed here
as tasks because none of it is decided.

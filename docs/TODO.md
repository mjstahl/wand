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
tree would stop building until every importer was edited by hand. So this
waits on `wand t` taking a directory, above.

### `wand t` reports one error per run

Every failing typecheck answers with a single error, so a file with six
unknown names takes six runs to clear. A person rereads the file each time;
a tool driving `wand t` in a loop pays a round trip per error.

Reporting the independent errors together would cut that to one pass.
Measured on 2026-09-10: repairing generated scripts against `wand t` took a
mean of 1.95 attempts with `--fix` applied first, and the attempts that
needed three or more were files with several unknown names and nothing else
wrong.

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

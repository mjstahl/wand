# Open work

What is known to be worth doing and is not done. An item leaves this file
when it ships, in the release that ships it. Nothing here is a commitment to
an order.

## Bugs

### A lexer error names one byte of a character, and is not valid UTF-8

The lexer reports an unexpected character by byte, so a non-ASCII character
produces a diagnostic that is not valid UTF-8 and does not say what it saw:

```
$ printf 'let x = 1 \u2014 2\n' > emdash.wand      # an em dash
$ wand t emdash.wand
Error: lex error: 1:11: unexpected character '\342'
```

`\342` is the first byte of the em dash. Two things are wrong. A caller that
decodes the output strictly dies rather than reporting -- which is how this
was found, on 2026-09-10, by a harness reading diagnostics as text. And the
message names a byte nobody can act on: it should print the character and
name the fix, which for an em dash, a curly quote or a non-breaking space is
the ASCII one that was meant.

Those three are what a document pasted into a script actually carries, so
this is the first thing a file from outside hits.

## Compiler and CLI

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

## Editors

### The VS Code extension says "effect rows"

`editors/vscode/package.json` describes hover as showing "effect rows".
That phrasing was removed from the documentation on purpose -- the word is
effects. It is public text on the marketplace, so correcting it means an
extension version rather than a compiler one.

## Beyond the compiler

Getting wand in front of the people who would use it is a distribution
question rather than a language one: a server that offers wand as an action
to the agents people already run, a plugin that bundles it, and a check that
gates a repository's scripts against a policy. That work is not listed here
as tasks because none of it is decided.

# Stream

Log processing is one of the four jobs wand names for itself. `List` has
thirty-one functions. `Stream` has seven, and the streaming path is the one
the big files use. This document is the design record for closing that gap:
what to add, what each addition costs, and the two things missing that are
not functions at all. It is a record of decisions and their reasons, written
before the code. It is not a specification.

- [Stream is not written in wand](#stream-is-not-written-in-wand)
- [Four tiers of cost](#four-tiers-of-cost)
- [What to build](#what-to-build)
- [Concatenation is a source, not a combinator](#concatenation-is-a-source-not-a-combinator)
- [count, not length](#count-not-length)
- [The missing sink is in FS](#the-missing-sink-is-in-fs)
- [Streaming a command, and commands that never end](#streaming-a-command-and-commands-that-never-end)
- [Why the command forms are not functions](#why-the-command-forms-are-not-functions)
- [Shell.exec, if a function is wanted](#shellexec-if-a-function-is-wanted)
- [Left out on purpose](#left-out-on-purpose)
- [Order](#order)

## Stream is not written in wand

Every other item on the standard library list is a stdlib edit. This one is
not, and that decides how it should be approached.

```ocaml
and stream_desc = { s_source : stream_source; s_stages : stream_stage list }

and stream_source =
  | SFile  of string
  | SStdin
  | SVals  of value list
  | SPull  of (unit -> value option)

and stream_stage =
  | StMap    of value
  | StFilter of value
  | StTake   of int
```

A stream is a first-order description — a source and a closed list of
stages — not a general lazy sequence. `run_stream_terminal` walks it one
item at a time, carrying a `value option`: one item in, at most one out.

So a new `Stream` function is not a line of wand. It is a constructor, a
case in the driver, and a question about whether the representation can
express the thing at all. That is worth knowing before promising fifteen
functions, and it is why the list below is sorted by what it costs rather
than by what it does.

The design is a good one and this is not an argument against it. Being
first-order is what lets a stream be named, passed and folded twice, and
what lets `Test.with_lines` mock a source that a general closure could not.

## Four tiers of cost

**Tier 0 — free.** Every terminal operation is a fold, and `fold_left` is
already there. Nothing in the evaluator changes:

```console
$ wand t -e 'let any? p s =
    !(List.empty? (s |> Stream.filter p |> Stream.take 1 |> Stream.to_list))'
any? : ('a -> Bool ! 'e) -> Stream {..} 'a -> Bool ! 'e
```

That signature is the whole argument. The stream's effect row flows through
to the caller, and it early-exits for real: the driver stops pulling once a
`take` is exhausted, which is the same reason `take 100` of a 10GB file
reads a hundred lines.

`count`, `last`, `any?`, `all?`, `find`, `empty?`, `sum`, `max` and `min`
are all tier 0.

**Tier 1 — one stage variant each.** `filter_map`, `take_while`, `drop`,
`drop_while`, `indexed`, `scan`, `chunks`, `unique`. Each fits one item in,
at most one out, so each is a constructor, a case, and a wand wrapper. The
driver's shape does not change.

**Tier 2 — the driver emits many per item.** `flat_map` alone. The `value
option` the loop carries becomes a list. Contained, and it touches the hot
path, so it is worth doing once and deliberately rather than as a rider on
something else.

**Tier 3 — a second source.** `zip` and `concat` need `stream_source` to
hold streams rather than a file or a list, and they need the driver to pull
from two places in step. This is the real structural change.

## What to build

Tiers 0, 1 and 2. Not tier 3.

Tier 0 is the largest gain in the set and carries no risk to the runtime, so
it goes first regardless of what follows. Tier 1 is where the log-processing
verbs actually live. Tier 2 is one function, and `flat_map` earns it: a line
that yields several records is ordinary in a log.

Tier 3 buys `zip`, and log processing does not want `zip`. Two streams
advanced in lockstep is a shape that comes up in array code, not in reading
a file. It can be argued for on its own if something ever asks.

`unique` is in tier 1 and keeps every distinct value it has seen, which is
unbounded memory on an unbounded source. It is still worth having, and its
doc does what `to_list`'s already does — says the cost out loud, because
"the memory cost is the point of saying it explicitly" is already the house
answer to this question.

## Concatenation is a source, not a combinator

The half of tier 3 that is genuinely wanted is not general concatenation. It
is several log files read as one:

```ocaml
FS.stream_lines_all : List Path -> Stream {FS.Read, Raise | ..} String
```

`FS.glob *.log |> FS.stream_lines_all` is the case people have. An `SFiles
of string list` source covers it with one constructor and no change to the
driver's shape, because the source is still a single puller — it just moves
to the next file when one runs out.

General `Stream.concat` of two arbitrary streams costs the tier 3 rework and
serves a rarer case. Solve the common one where it is cheap, at the source.

## `count`, not `length`

`List.length` sounds free. Counting a stream reads the whole source, and
counting twice reads it twice.

This is the one place to break naming parity with `List` on purpose. The
different word is the warning, and a reader who sees `Stream.count` has been
told something that `Stream.length` would have hidden. Every other name that
matches a `List` function keeps the `List` spelling, including `any?`,
`all?`, `find`, `indexed`, `take_while` and `drop_while`, because there the
semantics really are the same.

## The missing sink is in FS

`FS.stream_lines` reads. Nothing writes.

```
FS.write_file : Path -> String -> ...     -- a whole String, in memory
FS.append     : Path -> String -> ...     -- one line, one open, one close
```

So the honest way to write a filtered log today is `Stream.each (fn l ->
FS.append! out l)`, which opens and closes the file once per line. The
read-transform-write loop that "log processing" implies has no ending.

```ocaml
FS.write_lines  : Path -> Stream 'e String -> Result String Unit ! {FS.Write}
FS.append_lines : Path -> Stream 'e String -> Result String Unit ! {FS.Write}
```

These are terminal operations that happen to live in `FS`, which is the
right place: they are about a file, and `FS` is where a file is opened once.
The effect rows compose without new rules — the sink carries `FS.Write` and
picks up the source's row by folding it, exactly as the tier 0 `any?`
signature shows.

## Streaming a command, and commands that never end

`FS.stream_lines` and `IO.stdin_lines` are the only two sources. For deploys,
CI glue and log processing the conspicuous third is a subprocess:

```ocaml
$*(tail -f app.log)    -- Stream {Shell, Raise | ..} String
```

**This closes a hole that has no other answer today.** `$()` must read to
EOF to return a `String`, so `$(tail -f /var/log/app.log)` accumulates
forever and returns never. The same is true of `kubectl logs -f`, of
`journalctl -f`, and of any command that is watching rather than reporting.
The only bound available now is `Shell.timeout`, which kills the command and
hands back an `Error` — it stops the hang, and it does not give you the
lines.

A stream inverts that. The driver pulls one line at a time, so the memory is
one line, and `take` stops pulling:

```ocaml
$*(tail -f /var/log/app.log)
|> Stream.filter (fn l -> String.contains? "ERROR" l)
|> Stream.take 10
|> Stream.to_list
```

**It needs a command form of its own, and that is a decision.** `$()` runs
the command to completion and answers a `String`, so it cannot be the
argument to anything streaming — by the time a function saw the value, the
whole log would already be in memory. A streaming command has to be
syntax, not a function over a command's result.

`$*(...)` is the spelling, and the reason is a rule the existing two forms
already follow: each modifier borrows the bash `$X` whose meaning is
nearest.

| wand | bash `$X` | means |
|---|---|---|
| `$(cmd)` | `$(...)` | command substitution |
| `$?(cmd)` | `$?` | exit status |
| `$*(cmd)` | `$*` | the arguments as one string |

`$?()` is a pun — bash's `$?` *is* the exit code, and wand's `$?()` is the
form that hands you one. `$*` and `$@` differ in exactly the way that
matters here: `"$@"` expands to separate words, an argument vector, while
`"$*"` joins them into a single string. A wand command is one quoted command
line rather than a list of arguments, so `$*` is the form it rhymes with.

Two alternatives were weighed. `$|(...)` is the most immediately legible,
since `|` is the streaming symbol for anyone coming from a shell and it
rhymes with the `|>` that always follows it — but `|` is already the most
loaded character in wand, carrying type alternation, `||` and `|>`, and it
borrows no bash meaning. `$<(...)` has the best semantics of any option,
because bash's `<(cmd)` means exactly "this command's output, as something
you read from" — but the mnemonic only lands for people who use process
substitution, and `$<` is not a bash form.

`$!(...)` is rejected despite the lexer already half-knowing it: `!` means
"raises" everywhere else in wand, and a streaming command is no more raising
than `$()`.

One implementation note whichever spelling wins. `lexer.ml:101` scans `$?(`
and `$!(` when finding the extent of an interpolated expression. A new
modifier has to be added there too, or a streaming command written inside a
string will mis-scan.

Four things have to be right for that to be true, and they are decisions
rather than details.

**Closing must kill the child.** `SFile` closes with `close_in_noerr`. A
subprocess needs SIGTERM, then SIGKILL after the fixed five-second grace —
the pattern `Shell.timeout` already uses, over machinery `runner.ml` already
has in `remember`, `forget`, `reap` and `signal_name`. A stream that stops
early must not leave the child running.

The existing caveat carries over unchanged and should be repeated in the
doc: wand signals the command it started, so `sh -c "tail -f x"` leaves the
`tail` behind. wand stops waiting on a process it did not start.

**An early stop is not a failure.** `$()` raises on a non-zero exit. A
command wand killed because a `take` was satisfied did not fail — wand
ended it. There is already a precedent for exactly this distinction:

```ocaml
(* A command that died because wand is stopping is not the script's failure
   to report -- wand killed it on the way out. *)
let died_from_our_own_stop () = ...
```

The rule generalises. A stream read to exhaustion applies the ordinary
non-zero rule. A stream that stopped early ignores the exit status, because
the status is wand's own signal coming back.

**Block buffering will surprise people.** `tail -f` line-buffers, but many
commands switch to 4KB block buffering when stdout is a pipe rather than a
terminal. `grep` is the one everybody hits. Lines then arrive in gulps, or
appear not to arrive at all, and nothing in wand is wrong. This is a
documentation obligation, and the doc should name `--line-buffered` and
`stdbuf` rather than leaving people to find out.

**Folding twice runs the command twice.** A stream is a description, so this
is the existing rule and not a new one. It is worth restating here because
re-reading a file is cheap and idempotent while re-running a command is
neither.

The rules come free even though the syntax does not. `$()` and `$?()` are
`RunCmd` and `RunQuery` in the AST, and `shell_sites` already collects both;
a third constructor joins that enumeration and every existing check follows
it. `shell_scan` finds the command words, so `Shell(tail)` narrows a stream
exactly as it narrows a capture, `V-SHELL1` reports a word the run decides,
and `--dry-run` holds it back because it is the same effect. The work is in
the lexer, the parser and the formatter, not in the rules.

One thing the type system cannot help with: an unbounded stream with no
`take` never terminates. `$*(tail -f x) |> Stream.fold_left f init` hangs,
and it should — it is `while true` written in another shape.

### What `$*(...)` answers is still open

The spelling is settled. What it evaluates to is not, and there are two
designs. This is recorded here so it is chosen deliberately rather than by
drift, because the second one *replaces* the streaming work rather than
extending it.

**The narrow design, assumed everywhere above:** `$*(cmd)` is a `Stream`.

**The structural design:** `$*(cmd)` is a `Command` — a value that denotes a
command without running it — and the three things you can do with one are
ordinary functions.

```ocaml
Shell.run    : Command -> String                        ! {Shell, Raise}
Shell.query  : Command -> ShellResult                   ! {Shell}
Shell.stream : Command -> Stream {Shell, Raise | ..} String
```

It can be named, passed and mapped over, which is what nothing today can do:

```ocaml
let db     = "orders"
let backup = $*(pg_dump -Fc %{db})     -- assigned. Nothing has run.

let out = Shell.run!   backup
let s   = Shell.stream backup

List.map Shell.query [$*(git fsck), $*(git gc --dry-run)]
```

**The safety property survives.** `%{db}` still splices as one argument,
because the literal is still syntax. A `Command` cannot be built from a
`String`, so there is no path from user data to a command word — which is
exactly the objection that sinks `Shell.run! "some string"` in the next
section. Functions over a `Command` are safe for the reason functions over a
`String` are not.

**It closes three open questions at once:** how a command streams, what
`Shell.exec` should be and how stdin pipes into it, and how a command is
passed to a higher-order function.

The costs are real.

**`$(...)` and `$?(...)` become sugar,** defined as `Shell.run!` and
`Shell.query` over a literal. That is what keeps the common case one token
and stops there being two ways to write the same thing — but it does mean
the two forms every script uses are no longer primitive.

**A new type appears in signatures,** which is more machinery than a
language this size may want.

**One genuine wrinkle.** Constructing a `Command` performs nothing, so a
file that builds one and never runs it needs no `Shell` label — yet
`shell_scan` finds the command words at the literal, so a narrowed manifest
would still demand `git` be listed. The word check and the effect check
would key off different sites. `$()` does not have this problem, because
there the two sites are one site. It is answerable, and it is the part of
this design that needs the most care.

**An open question inside the open question:** does a `Command` print?
Showing the resolved command line is useful for logging and for `--dry-run`
output, and it also puts the quoted form in front of people as a `String`,
which invites them to try to build one.

On the sigil: `@` is the only genuinely free character —

```console
let x = #(a)  -> lex error: a comment is '-- ...', not '# ...'
let x = ^(a)  -> lex error: string concatenation is '++', not '^'
let x = @(a)  -> lex error: unexpected character '@'
let cmd = 1   -> cmd : Int
```

— and it is still the wrong choice. A bare `@(` would hide from the `$(`
grep that someone reviewing a script reaches for, and reviewability is the
whole pitch. A `cmd(...)` keyword is out for a different reason: `cmd` is a
valid variable name and is the one a shell script reaches for. So the form
stays in the `$` family under either design, and `$*` is right under both.

## Why the command forms are not functions

An obvious tidy-up suggests itself once there are three command forms: give
each one a function, so `$()` is `Shell.run!`, `$?()` is `Shell.run`, and
`$*()` is `Shell.stream!`. The names would be those — `run_command!` says
`command` twice in a module already called `Shell`, and nothing else in the
standard library repeats its module in a member name.

The functions should not exist, and the reason is not style. Note the scope:
this rejects functions over a `String`. Functions over the `Command` value
above are a different proposal and survive every objection here.

**`%{}` means two different things.** Inside a command it splices a value as
one argument. Inside a string it splices text.

```console
$ cat q.wand
uses {IO, Shell(echo)}
import IO
let name = "a b; whoami"
IO.println $(echo %{name})
IO.println "echo %{name}"

$ wand q.wand
a b; whoami
echo a b; whoami
```

The first arrived at `echo` as a single argument: the `;` is data and
nothing after it ran. The second is a `String` holding that text. Give that
String to a shell and `whoami` runs.

So `Shell.run! "echo %{name}"` is an injection where `$(echo %{name})` is
safe, and on the page the two are a bracket apart. That inverts the claim
the README leads with — *a filename from the environment cannot become a
second command*. The quoting lives in the syntax, and a function taking a
`String` cannot have it, because by the time it is called the argument is
one flat string with every boundary already lost.

**Narrowing degrades as well.** `shell_sites` collects `RunCmd` and
`RunQuery`; a function call is neither, so nothing is checked statically.
The spawn check still fires —

```console
$ wand t d.wand
warning: 4:11: V-SHELL1: this command's first word is decided at run time, so
the Shell(...) list is checked when it spawns rather than here

$ wand d.wand
Error: eval error: this command runs 'whoami', which the manifest's
Shell(echo) does not allow
```

— so this is a weakening rather than a hole. But every call site becomes the
case `V-SHELL1` exists to warn about, and `Shell(git)` stops being readable
from the text.

**The operation table already says this.** It records what a script writes
to reach each operation, and two of them are deliberately unreachable:

```ocaml
{ op_name = "Shell!run";     op_performers = ["$(...)"] };
{ op_name = "Shell!capture"; op_performers = ["$?(...)"] };
(* nothing a script can write reaches them: the builtins are not bound in
   a script's scope and no module exports them. *)
{ op_name = "Shell!run_quiet"; op_performers = [] };
{ op_name = "Shell!exit_code"; op_performers = [] };
```

`$*(...)` joins the first two as a performer. Under the narrow design it
gets no function either, for the same reason they do not. Under the
structural design the table changes shape rather than gaining a row: the
performer becomes the `Command` literal, and `Shell.run`, `Shell.query` and
`Shell.stream` are the functions that consume it — safe because their
argument was built by syntax, which is the distinction this whole section
turns on.

**What higher-order use looks like instead.** The one thing a function
would genuinely buy is passing a command around — mapping over a list of
them. Write the lambda:

```ocaml
List.map (fn c -> $(%!{c})) cmds
```

That is the function form. It makes the dynamism visible where it happens,
and it carries the `V-SHELL1` it has earned, instead of hiding both behind
a name that reads as safely as `$()`.

## `Shell.exec`, if a function is wanted

There is a function worth having here, and it is not a copy of the syntax.
It takes argv rather than a command line:

```ocaml
Shell.exec! : List String -> String       ! {Shell, Raise}
Shell.exec  : List String -> ShellResult  ! {Shell}

Shell.exec! ["git", "checkout", branch]
```

No shell is involved. Each element is one argument by construction, so
there is no quoting to get wrong, no word splitting, and `;` in a value is
a semicolon. This is `execve`, not `sh -c`, which makes it *stronger* than
`$()` rather than a weaker copy of it — `$()` runs a shell and relies on
wand's quoting to keep the arguments apart; `exec` never gives a shell the
chance.

It stays checkable. When the head of the list is a literal, the manifest
word check applies exactly as it does to a command's first word. When it is
not, `V-SHELL1` reports it honestly, and the spawn check bounds it.

Three things it does not settle, and they belong to `Shell` rather than to
this document:

- **Piping stdin.** `report |> $?(mail ops@example.com)` has no `exec`
  spelling yet. A second function, or a field, or nothing.
- **A streaming variant.** `Shell.exec_lines` is the same question one level
  along. If `$*(...)` answers a `Command`, `Shell.exec` is unnecessary —
  that design already gives a safe function over a syntactically built
  command, which is all `exec` was for.
- **Whether it ships at all in a first version.** `$()` covers what scripts
  write today. `exec` earns its place when a command has to be built from
  values rather than written down, which is exactly when the shell is most
  dangerous and least wanted.

## Left out on purpose

**`zip`.** Tier 3, and the case for it is array code rather than logs.

**Result-aware combinators.** A line that fails to parse is handled by
`filter_map` returning `None`, or by mapping to a `Result` and folding over
it. A parallel family of `Stream.map_ok`-style functions doubles the module
to save a line.

**Parallel streams.** `Par.map` over a `List` is the existing answer, and a
stream that fans out is a different subject with ordering questions of its
own.

**A general `unfold` or `iterate`.** Both want a closure as the source,
which is the thing the first-order representation deliberately does not
have. `SPull` exists for the tests and is reachable only from OCaml, and it
should stay that way.

## Order

Tier 0 first: it is free, it is the largest single gain, and it needs no
decision from anyone.

The streaming command form next, because it removes a hole with no
workaround — `$(tail -f)` has no answer today — and because its four rules
above are the only genuinely new semantics in this document.

Then tier 1, then the `FS` sinks, then `flat_map`. Tier 3 is not scheduled.

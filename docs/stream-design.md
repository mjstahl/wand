# Stream

Log processing is one of the four jobs wand names for itself, and the
streaming path is the one the big files use. `Stream` has its terminal
operations; what it lacks are the stages between the source and them. This
document is the design record for the rest: what to add, what each addition
costs, and the two things missing that are not `Stream` functions at all — a
sink in `FS`, and a `Command` value. It is a record of decisions and their
reasons, written before the code. It is not a specification.

- [Stream is not written in wand](#stream-is-not-written-in-wand)
- [Three tiers of cost](#three-tiers-of-cost)
- [What to build](#what-to-build)
- [Concatenation is a source, not a combinator](#concatenation-is-a-source-not-a-combinator)
- [The missing sink is in FS](#the-missing-sink-is-in-fs)
- [Streaming a command, and commands that never end](#streaming-a-command-and-commands-that-never-end)
- [The Command value](#the-command-value)
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

## Three tiers of cost

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

Tiers 1 and 2. Not tier 3.

Tier 1 is where the log-processing verbs actually live. Tier 2 is one
function, and `flat_map` earns it: a line that yields several records is
ordinary in a log.

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
picks up the source's row by folding it, exactly as the terminal operations
already do.

## Streaming a command, and commands that never end

`FS.stream_lines` and `IO.stdin_lines` are the only two sources. For deploys,
CI glue and log processing the conspicuous third is a subprocess.

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
Shell.stream $*(tail -f /var/log/app.log)
|> Stream.filter (fn l -> String.contains? "ERROR" l)
|> Stream.take 10
|> Stream.to_list
```

`$*(...)` is a `Command`, which the next section is about. `Shell.stream`
turns one into a stream of its output lines.

Four things have to be right for that to work, and they are decisions rather
than details.

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

One thing the type system cannot help with: an unbounded stream with no
`take` never terminates. `Shell.stream $*(tail -f x) |> Stream.fold_left f
init` hangs, and it should — it is `while true` written in another shape.

## The `Command` value

A command cannot be streamed by a function over `$()`, because `$()` has
already run it and read it to EOF by the time any function sees the value.
The obvious fix is a third command form that yields a stream. The better fix
is one level back: a form that yields the *command*, and functions that do
things with it.

```ocaml
$*(git status)        -- a Command. Nothing runs.
```

```ocaml
Shell.run    : Command -> String                            ! {Shell, Raise}
Shell.query  : Command -> ShellResult                       ! {Shell}
Shell.stream : Command -> Stream {Shell, Raise | ..} String
```

A `Command` can be named, passed and mapped over, which nothing today can
be:

```ocaml
let db     = "orders"
let backup = $*(pg_dump -Fc %{db})     -- assigned. Nothing has run.

let out = Shell.run!   backup
let s   = Shell.stream backup

List.map Shell.query [$*(git fsck), $*(git gc --dry-run)]
```

### Why `$*`

Each modifier borrows the bash `$X` whose meaning is nearest.

| wand | bash `$X` | means |
|---|---|---|
| `$(cmd)` | `$(...)` | command substitution |
| `$?(cmd)` | `$?` | exit status |
| `$*(cmd)` | `$*` | the arguments as one string |

`$?()` is a pun — bash's `$?` *is* the exit code, and wand's `$?()` is the
form that hands you one. `$*` and `$@` differ in exactly the way that
matters: `"$@"` expands to separate words, an argument vector, while `"$*"`
joins them into a single string. A wand command is one quoted command line
rather than a list of arguments, so `$*` is the form it rhymes with.

Two alternatives were weighed. `$|(...)` is the most immediately legible,
since `|` is the streaming symbol for anyone coming from a shell — but `|`
is already the most loaded character in wand, carrying type alternation,
`||` and `|>`, and it borrows no bash meaning. `$<(...)` has good semantics,
because bash's `<(cmd)` means "this command's output, as something you read
from" — but the mnemonic needs process substitution, and `$<` is not a bash
form. `$!(...)` is rejected despite the lexer already half-knowing it: `!`
means "raises" everywhere else in wand.

A bare sigil was considered and refused. `@` is the only free character —

```console
let x = #(a)  -> lex error: a comment is '-- ...', not '# ...'
let x = ^(a)  -> lex error: string concatenation is '++', not '^'
let x = @(a)  -> lex error: unexpected character '@'
let cmd = 1   -> cmd : Int
```

— and `@(` would hide from the `$(` grep someone reviewing a script reaches
for, which is the whole pitch. A `cmd(...)` keyword is out for a different
reason: `cmd` is a valid variable name and is the one a shell script uses.

### `$()` and `$?()` become sugar

```
$(cmd)   is  Shell.run!  $*(cmd)
$?(cmd)  is  Shell.query $*(cmd)
```

This is what keeps the common case one token and stops there being two ways
to write the same thing. It does mean the two forms every script already
uses stop being primitive, which is the largest single risk in this design
and the reason it should be done early or not at all.

### A function over a `Command` is safe; one over a `String` is not

The tidy-up that suggests itself — `Shell.run! "git status"`, taking a
`String` — must not exist, and the reason is what makes the `Command`
version work.

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
String to a shell and `whoami` runs. So `Shell.run! "echo %{name}"` is an
injection where `$(echo %{name})` is safe, and on the page the two are a
bracket apart. That inverts the claim the README leads with — *a filename
from the environment cannot become a second command*.

The quoting lives in the syntax. `Shell.run! backup` is safe for precisely
that reason: `backup` was built by `$*(...)`, so its arguments were
separated before any function saw it, and there is no constructor taking a
`String` to a `Command`. The type is the guarantee.

**Narrowing survives too.** `shell_sites` collects `RunCmd` and `RunQuery`
today; the `Command` literal joins that enumeration, so `shell_scan` finds
the command words where they are written, `Shell(tail)` narrows a streamed
command exactly as it narrows a capture, `V-SHELL1` reports a word the run
decides, and `--dry-run` holds it back because it is the same effect.

### What it costs

**A new type appears in signatures**, which is more machinery than a
language this size might want. It is the price of the three functions above
being ordinary functions.

**Constructing a `Command` performs `Shell!command`.** This is the decision
the rest of the design waited on, and it is the one place `Command` costs
something that `$()` does not.

The problem it answers: the word check and the effect check would otherwise
key off different sites. `shell_scan` finds command words at the literal,
while nothing is performed until the `Command` is consumed. So a file that
builds one and never runs it would be told by a narrowed manifest to list
`git`, and told by `A-USES1` to drop the `Shell` it does not use. Take the
second piece of advice and the literal stops being covered by the narrowing
at all. `$()` never had this, because there the two sites are one site.

Two answers were weighed.

*Check words where the `Command` is consumed*, leaving construction pure.
The word check then has to find the literal from the consumer, and the
consumer usually holds a variable — `Shell.run! backup` — or a list, or a
parameter. Where the value cannot be traced the words are unknown, so the
site falls to `V-SHELL1` and the run-time guard. Safe, because `guard_shell`
still refuses a disallowed word at spawn, but it moves the answer from
`wand t` to the run for exactly the files this feature is for, and it puts
the design's hardest analysis on its critical path.

*Perform an operation at construction*, which is the answer. The word check
does not move: it stays syntactic, at the literal, with no dataflow to get
wrong, and it covers every command literal whether it is run, passed, stored
or never used. That is more static coverage than there is today, and it is
bought without inventing an analysis.

What it costs is real and is accepted here rather than argued away.
Constructing a value performs, so a function that only builds commands
carries `Shell`:

```ocaml
let backup_cmd db = $*(pg_dump -Fc %{db})     -- Command ! {Shell}
```

`Shell` becomes the one label that means *does or describes* rather than
*does*. Every `$()` performs two operations where it performed one, since it
is sugar for `Shell.run! $*(...)`. And a handler stops discharging `Shell`
until it adds a case:

```ocaml
handle $(git push) with
| Shell!command _ k -> k ()
| Shell!run _ k -> k "ok"
| Shell!run_quiet _ k -> k ()
| Shell!capture _ k -> k "ok"
| Shell!exit_code _ k -> k 0
```

That is a change to every handler written so far and to the reference's own
example, which is cheap now and would not be later. It is the same argument
that puts this whole item early.

Two consequences to carry into the implementation. `Shell!command` must
never be withheld by `--dry-run`: the value is what the plan is printed
from, so it is the one operation that is always carried out, and
`is_mutation` has to say so. And it is a perform per command construction,
which is a startup-path change and takes before-and-after numbers.

**Does a `Command` print?** Showing the resolved command line is useful for
logging and for `--dry-run` output. It also puts the quoted form in front of
people as a `String`, which invites them to try to build one. Open.

**The operation table gains a row and the existing ones change performer.**

```ocaml
{ op_name = "Shell!command"; op_performers = ["$*(...)"] };
{ op_name = "Shell!run";     op_performers = ["$(...)"; "Shell.run"; "Shell.run!"] };
{ op_name = "Shell!capture"; op_performers = ["$?(...)"; "Shell.query"] };
```

That table is what an editor reads to answer "what can `Shell!` become", and
it is what `test_reference_signatures` checks the reference against, so both
move together.

**One implementation note.** `lexer.ml:101` scans `$?(` and `$!(` when
finding the extent of an interpolated expression. `$*(` has to be added
there too, or a command written inside a string will mis-scan.

## Left out on purpose

**`zip`.** Tier 3, and the case for it is array code rather than logs.

**Result-aware combinators.** A line that fails to parse is handled by
`filter_map` returning `None`, or by mapping to a `Result` and folding over
it. A parallel family of `Stream.map_ok`-style functions doubles the module
to save a line.

**Parallel streams.** `Par.map` over a `List` is the existing answer, and a
stream that fans out is a different subject with ordering questions of its
own.

**`Shell.exec`, taking argv.** An earlier draft proposed it as the safe
function form — `Shell.exec! ["git", "checkout", branch]`, no shell, each
element one argument by construction. `Command` subsumes it: it gives a safe
function over a syntactically built command, which is all `exec` was for,
and it does so without a second way to write a command. If a genuine
`execve` path is ever wanted — no shell at all, rather than a shell wand
quotes for — it should be a property of `Command`, not a parallel family.

**A general `unfold` or `iterate`.** Both want a closure as the source,
which is the thing the first-order representation deliberately does not
have. `SPull` exists for the tests and is reachable only from OCaml, and it
should stay that way.

## Order

The `Command` value first, and this is a change of order from an earlier
draft. It was going to be a streaming command form, scheduled after tier 1
on the grounds that it only removes a hole for people who have already
adopted wand. As a `Command` it is a bigger job and an earlier one, because
`$()` and `$?()` become sugar over it — the two forms every script already
uses stop being primitive, and that is a change to make while the number of
scripts is small.

Then tier 1, then the `FS` sinks, then `flat_map`. Tier 3 is not scheduled.

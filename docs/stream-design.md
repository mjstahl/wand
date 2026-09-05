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

`$*(...)` is the spelling proposed here: `$()` raises, `$?()` answers a
`ShellResult`, `$*(...)` answers a `Stream`. The character is genuinely
open — `$|(...)` argues for itself on the pipe association — and it is the
one thing in this document that a reader will see every day, so it is worth
choosing deliberately.

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

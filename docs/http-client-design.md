# Reading a response as it arrives, and asking again when it says no

Two things an HTTP client needs that wand does not have, recorded together
because the same caller needs both and the second depends on a decision the
first makes.

`HTTP.request!` answers with a whole `HTTPResponse`. Every other source wand
reads has a streaming form — `FS.stream_lines` for a file, `Shell.stream` for
a command, `FS.stream_lines_all` for several files as one — and `HTTP` has
none. And nothing in the standard library retries, though `Test` already
advertises testing one.

This document is the design record for both: what a caller gets back, what the
manifest checks and when, what a test double answers with, and what a rehearsal
does. It is a record of decisions and their reasons, written before the code.
It is not a specification.

Several questions in it are open. They are marked, and each says what turns
on the answer.

- [What is missing, and what it costs](#what-is-missing-and-what-it-costs)
- [The status is eager and the body is lazy](#the-status-is-eager-and-the-body-is-lazy)
- [Lines, chunks, or events](#lines-chunks-or-events)
- [One operation or two](#one-operation-or-two)
- [The manifest check, and redirects](#the-manifest-check-and-redirects)
- [Stopping early, failing late](#stopping-early-failing-late)
- [A stream that stalls](#a-stream-that-stalls)
- [What a rehearsal does](#what-a-rehearsal-does)
- [Asking again when it says no](#asking-again-when-it-says-no)
- [Retrying keys on the answer, not on the failure](#retrying-keys-on-the-answer-not-on-the-failure)
- [The policy is one record with defaults](#the-policy-is-one-record-with-defaults)
- [A rehearsal withholds the sleep, and sends the GET](#a-rehearsal-withholds-the-sleep-and-sends-the-get)
- [Where it lives](#where-it-lives)
- [Open questions](#open-questions)
- [Left out on purpose](#left-out-on-purpose)
- [Order](#order)

## What is missing, and what it costs

A response wand cannot bound is a response wand loads. `HTTP.download` is the
answer for a large body — it writes to a file and never holds it — but a
caller that wants the bytes *as they arrive* has nothing. Two ordinary jobs
need that:

- A long response read while it is still being written: a log endpoint, a
  build's output, an export.
- A token stream. Every LLM API answers `text/event-stream` and sends one
  fragment at a time, and reading it after it finishes defeats the point.

Today the only way to write either is

```
Shell.stream $*(curl -N -H "Authorization: Bearer %{token}" %{url})
```

which costs three things. The manifest says `Shell(curl)` and not `Net(host)`,
so the first line no longer tells a reviewer where the bytes go — and per
[A subprocess is outside every label](reference.md#a-subprocess-is-outside-every-label)
it never will, because that is a subprocess. The status code is gone, so a
429 cannot be told from a 200. And the token is on a command line, where `ps`
reads it.

`HTTP.stream` recovers all three: the host is in the manifest and checked, the
status is a field, and the header is a header.

## The status is eager and the body is lazy

This is the decision the rest turns on.

Every stream wand has today reads nothing until a terminal operation runs it.
`FS.stream_lines /missing` does not raise at the call; it raises at the fold.
A response cannot follow that rule all the way. The status and the headers
arrive *before* the body, and the status is the thing a caller branches on:

```
match HTTP.stream! req with
| (r, body) when r.status == 429 -> back_off ()
| (r, body) -> body |> Stream.each handle
```

To answer that `match`, the request has already been sent. So `HTTP.stream`
performs `Net` when it is called, not when the stream is folded, and it is the
first thing in wand that is half a description.

The alternative is to answer with a bare `Stream String` and make the whole
thing lazy, consistent with `FS` and `Shell`. It reads well and it loses the
status, which is exactly the loss that makes the `curl` version unacceptable.
Consistency is not worth buying back the defect we are fixing.

So: **`HTTP.stream` sends the request, answers with the status and the headers,
and leaves the body a stream.** The shape of that answer is
[an open question](#q1-what-shape-carries-the-status-and-the-body).

## Lines, chunks, or events

Three layers are available, and they are not the same:

| | what one item is | who wants it |
|---|---|---|
| chunks | whatever the transport handed over | almost nobody; the boundaries are meaningless |
| lines | up to the next `\n` | log endpoints, NDJSON, anything line-oriented |
| SSE events | a `data:` block terminated by a blank line | every token stream |

Chunks are out. A chunk boundary is an artefact of the network and no program
should see one.

Lines are the obvious floor, and they match `Shell.stream` and
`FS.stream_lines`, so `Stream.filter`, `Stream.take` and the rest work with no
new vocabulary.

SSE is where the motivating case actually lives, and lines do not reach it: one
event is several lines, a `data:` field can repeat and is joined with newlines,
a comment line begins with `:`, and the blank line is the terminator. A caller
handed lines writes that reassembly itself, gets it subtly wrong, and every
caller writes it again.

But SSE is a protocol layered *on* HTTP, and `HTTP` knowing about it is the
kind of thing that looks small and then grows a field per specification. See
[Q2](#q2-does-sse-belong-in-http).

## One operation or two

`HTTP.wand` says why there is exactly one operation today:

> One primitive underneath, so a double that stands in for `Net!http` covers
> every function here. […] the operation count is the mocking surface: four
> would be four ways for a test to believe it was sealed and not be.

A stream cannot go through `Net!http`. That operation resumes with an
`HTTPResponse`, and a handler case that answered a stream with one would have
to build the whole body — which is the thing being avoided.

`FS` already has this shape and the precedent is good: `FS!stream_lines` is a
second operation, and a double resumes it with a `List String`
(`Test.wand:233`). The list becomes the stream. A test writes data, not a
puller.

So `Net!stream` is a second operation under the `Net` label, resuming with a
`List String`. The cost is real and must be paid explicitly: **`Test.with_http`
has to answer both, or a test that seals the module seals half of it.** Any
`Test` helper for `Net` covers every `Net` operation or it is a trap. The same
already applies to `Net!download`, so this is the second instance of a rule
that should be written down rather than a new problem.

## The manifest check, and redirects

Unchanged in principle, and the timing is easier than for `$()`.

A request is checked against the manifest of the file that built its URL. For
a stream the request is sent when `HTTP.stream` is called, so the check happens
there — at the same point it happens for `HTTP.request`. Nothing moves to the
fold.

Redirects are the reason this is easy. A 302 is a status, and a status arrives
before the body. So a redirect is resolved before there is a stream at all, and
every hop is held to the manifest exactly as it is now. There is no case where
a stream is already running and the host changes.

`V-NET1` applies unchanged: a host the run decides is checked at the request
rather than at `wand t`.

## Stopping early, failing late

`Shell.stream` already settled these and `HTTP.stream` should answer the same
way, because a reader who learns one should not have to learn the other:

- **Stopping the read ends the transfer.** `Stream.take 10` over a stream that
  never ends stops after ten, and the connection closes.
- **An early stop is not a failure.** A stream read to the end raises on a
  transport failure; one stopped early does not look at it.
- **Folding twice sends the request twice.** A stream is a description. For a
  file that costs a re-read; here it costs a second request, which is worse and
  worth saying loudly in the doc comment.

There is one difference from `Shell.stream`, and it needs a decision. The
status is already known by the time anyone folds. If the fold then fails —
connection dropped at byte 40,000 of a 200 response — the raise carries no
status, because the status was fine. See
[Q3](#q3-what-does-a-mid-stream-failure-raise).

## A stream that stalls

`Shell.timeout` does not bound a stream: its deadline is on a command that
ends, and a stream is the case where the command does not
(`reference.md:3824`). `HTTP` inherits that gap, and for a token stream it is
not a gap but the common failure. A provider that stops sending mid-response
leaves the fold blocked forever, and no existing wand construct interrupts it.

`Par.timeout` bounds a thunk, so `Par.timeout 30s (fn () -> … |> Stream.to_list)`
bounds the whole read — but not the gap between two items, which is what
"stalled" means. See [Q4](#q4-how-is-an-idle-stream-bounded).

## What a rehearsal does

`--dry-run` withholds every change and reports it. A read is not a change, so
`FS.stream_lines` reads for real under a rehearsal, and by that rule
`HTTP.stream` on a `GET` should too.

`HTTP.request` already draws that line and this follows it. A rehearsal sends
`GET` and `HEAD` and withholds every other method, answering `202` with no body
— "the server took it and said nothing", which is the least a caller can read
into (`runner.ml:817`, `runner.ml:974`). So a streaming `POST` is withheld, and
the question is only what its *stream* answers with: an empty one is the
reading consistent with a `202` and no body.

## Asking again when it says no

Nothing in the standard library retries, and `Test` is written as though
something did. `Test.with_clock` exists so that "a test that exercises an hour
of backoff runs in microseconds", and the example under it is

```
let (elapsed, result) = Test.with_clock (fn () -> retry fetch)
```

`retry` does not exist. The test module advertises a way to test a thing the
library does not provide, so every caller writes the loop, and each one writes
it slightly differently.

The case that makes it urgent is the same one that wants streaming. Every LLM
API answers `429` under load and asks to be asked again, and a client that does
not retry is a client that fails whenever anyone else is busy. But retry is not
an HTTP feature: a flaky `$()`, a lock that is held, a mount that is not up yet
are the same shape. It is a general combinator that HTTP happens to need most.

## Retrying keys on the answer, not on the failure

This is the decision the rest turns on, and it is forced by a choice `HTTP`
already made.

A retry combinator in most languages wraps a call that *fails* and repeats it.
That is useless here. `HTTP.request` answers `Ok response` for a `429`, because
the exchange succeeded and the server said no — `HTTP.wand` says so, and it is
right. A `Result`-keyed retry would never fire for the one case that motivates
it.

So what is retried is an *answer the caller judges unacceptable*, and the
caller supplies the judgement:

```
Retry.until : ('a -> Bool) -> Policy -> (Unit -> 'a ! 'e) -> 'a ! {Clock | 'e}
```

```
Retry.until HTTP.ok? Retry.Policy() (fn () -> HTTP.request! req)
```

`HTTP.ok?` already exists and reads exactly right at the call site. A caller
wanting to retry a `503` but not a `404` writes the predicate, and the manifest
of the retrying file is the thunk's effects plus `Clock`.

A transport failure — a name that does not resolve, a connection refused — is a
raise rather than an answer, and it is a second axis. Whether one function
covers both is [R1](#r1-does-one-function-cover-a-bad-answer-and-a-raise).

## The policy is one record with defaults

Backoff has five knobs and nobody wants five arguments. wand has field
defaults, which is what makes a single record better than a family of
functions:

```
type Policy(
  attempts: Int      = 3,
  base:     Duration = 1s,
  factor:   Int      = 2,
  cap:      Duration = 30s,
  jitter:   Bool     = true
)
```

`Retry.Policy()` is the default and reads as "the usual thing".
`Retry.Policy(attempts = 5, cap = 2min)` changes two and says which two. No
overload set, no builder, and the type error names the field.

`jitter` is not free. Spreading the waits needs `Random`, so a script that
retries with jitter declares `Random` — a label a reader notices, on a script
that draws no lottery. See [R2](#r2-does-every-retrying-script-declare-random).

## A rehearsal withholds the sleep, and sends the GET

This is the sharpest problem in the retry half, and it is not hypothetical.

`Clock!sleep` is withheld under `--dry-run` (`runner.ml:830`), and a `GET` is
sent for real (`runner.ml:817`). A retry loop written in wand over
`Clock.sleep` therefore *spins* under a rehearsal: an hour of planned backoff
becomes microseconds of hammering a live endpoint. Rehearsing a script that
retries a read is a small denial-of-service against whoever is on the other
end.

wand has met this before and wrote down the answer. `FS!lock_wait` is its own
operation rather than a loop in wand over `FS!lock` and `Clock.sleep`, and the
reference says why: "a rehearsal withholds a sleep, so such a loop would spin
against a wall-clock deadline for the whole budget. One operation is also what
lets a rehearsal decline to wait."

Retry has the same shape and should get the same treatment: the wait inside a
retry is not a plain `Clock.sleep`, so a rehearsal can decline to retry rather
than retry instantly. Whether that means the whole combinator is an operation,
or only its wait, is [R3](#r3-is-the-wait-an-operation-a-rehearsal-can-decline).

Whatever the mechanism, the rehearsal's report should say the thing that is
true: *would retry up to N times, waiting up to D*.

## Where it lives

A module of its own, `Retry`.

Not `HTTP`, because retrying a command or a lock is the same combinator and
putting it in `HTTP` hides it from both. Not `Par`, which is about doing
several things at once and shares nothing with this but the word "thunk". Not
`Clock`, which tells the time and does not decide when to give up.

`Retry` is a shorter name than the module list's usual nouns, and it is the
word every caller will search for.

## Open questions

### Q1: What shape carries the status and the body?

Three candidates:

```
HTTP.stream! : HTTPRequest -> (HTTPResponse, Stream String)   -- (a) a tuple
HTTP.stream! : HTTPRequest -> HTTPStream                      -- (b) a type
HTTP.stream! : HTTPRequest -> Stream String                   -- (c) body only
```

(c) is rejected above — it loses the status. Between (a) and (b):

(a) needs no new type, and `HTTPResponse.body` would be `""` in the tuple's
first half, which is a lie sitting in a field. (b) is honest — `HTTPStream(status,
headers, body: Stream String)` has no empty body field — at the cost of a
fourth type beside `HTTPRequest`, `HTTPResponse` and `HTTPMethod`, and of
`HTTP.ok?` and `HTTP.header` not working on it without an overload wand does
not have.

**Turns on:** whether an empty `body` field on a response that has a body
elsewhere is acceptable. Leaning (b).

### Q2: Does SSE belong in `HTTP`?

Either `HTTP.stream` gives lines and something else assembles events, or
`HTTP` gains a second entry point:

```
HTTP.events! : HTTPRequest -> (HTTPResponse, Stream SSEEvent)
```

A third option is a `Stream` combinator with no HTTP knowledge — `Stream.sse :
Stream String -> Stream SSEEvent` — which keeps `HTTP` at one layer and puts
the reassembly somewhere testable with a list of lines and no network at all.
That is the most wand-shaped of the three and it is worth trying first.

**Turns on:** whether SSE reassembly can be written as a pure stream stage.
If it can, `HTTP` stays at lines and this is not an HTTP question.

### Q3: What does a mid-stream failure raise?

The status was 200 and the transfer then failed. `Shell.stream` raises on the
command's exit code. Here there is no exit code, only a dropped connection.
The options are a raise with a transport message, or ending the stream quietly
and letting the caller notice the body was short — which nobody notices.

**Turns on:** nothing else in the design. Leaning: raise, with the byte count
received, because a truncated answer that looks complete is the worst outcome.

### Q4: How is an idle stream bounded?

A per-read deadline is what "stalled" needs and wand has no vocabulary for it.
Candidates: a field on the request (`HTTPRequest(idle_timeout = 30s)`), an
argument to `HTTP.stream`, or a general `Stream.idle_timeout` that any stream
can carry — which would also close the `Shell.stream` gap in the same stroke.

**Turns on:** whether this is an HTTP problem or a `Stream` problem. If the
general form is buildable, it is worth more than the specific one, and
`Shell.stream` gets it free.

### Q5: Does the request body stream too?

`HTTP.upload` sends a file today. A streamed *request* body — sending while
generating — has no caller anyone has asked for. Named here so the answer is
"not now" on purpose rather than by omission.

### R1: Does one function cover a bad answer and a raise?

`Retry.until` keys on the answer. A transport failure never produces one — it
raises, or comes back `Error` from the non-`!` sibling. Three shapes:

- One function that retries both: it catches, and a predicate that must judge
  `Result String 'a` rather than `'a` loses the reading of
  `Retry.until HTTP.ok?`.
- Two functions, `until` on the answer and something like `Retry.while_raising`
  on the failure. Honest and doubles the surface.
- One function, and the caller composes: `Retry.until (fn r -> match r with Ok
  x -> HTTP.ok? x | Error _ -> false) p (fn () -> try f ())`. Nothing new, and
  the call site is a mouthful.

**Turns on:** whether the predicate can stay `'a -> Bool`, which is what makes
`Retry.until HTTP.ok?` read the way it does. Leaning: keep it, and let `try`
inside the thunk be how a raise becomes an answer.

### R2: Does every retrying script declare `Random`?

Jitter needs entropy, so `jitter = true` puts `Random` in the manifest of any
script that retries. That is truthful — the script does draw — and it is also
noise on the first line of a deploy script that draws nothing else, and
`Random` is a label a reviewer reads as "this run will not repeat".

Options: default `jitter` to false and make spreading opt-in; keep it true and
accept the label; or derive the spread from something that is not `Random` —
the attempt number and the process id are already to hand and need no effect,
at the cost of two processes started together retrying in step.

**Turns on:** whether a `Random` on the first line of every retrying script is
information or noise. Leaning: default true and accept it, because thundering
herd is a real failure and a label that says so is the manifest working.

### R3: Is the wait an operation a rehearsal can decline?

A plain `Clock.sleep` inside the loop makes `--dry-run` hammer the endpoint.
`FS!lock_wait` solved the same problem by being one operation. Candidates:

- The whole combinator is an operation, resuming with the final answer. A test
  double then stands in for retrying entirely, which is either convenient or a
  way to seal something you meant to exercise.
- Only the wait is its own operation — `Clock!backoff`, say — which a rehearsal
  declines and `Test.with_clock` already knows how to answer. Smaller, and the
  loop stays readable wand.
- Leave it a `Clock.sleep` and document that `--dry-run` does not rehearse a
  retry. Cheapest and worst: the failure is silent and lands on somebody else's
  server.

**Turns on:** whether a rehearsal must be safe for the *other* machine, not
just this one. The manifest record says it must. Leaning: the second option.

### R4: How does `Retry-After` reach the policy?

A `429` usually carries `Retry-After`, and honouring it is the difference
between a polite client and a rude one. `Retry.until`'s predicate answers
`Bool`, which cannot carry a duration.

Options: the predicate answers `Option Duration` — `None` for "this answer is
fine", `Some d` for "ask again after d" — which folds the two questions into
one and reads less well; a second optional field on `Policy` holding a function
from the answer to a delay; or an `HTTP`-side helper that builds a `Policy`
from a response.

**Turns on:** whether `Retry` is allowed to know that answers can suggest their
own delay, without knowing anything about HTTP. The first option is the only
one that keeps `Retry` general and still honours the header.

## Left out on purpose

- **Chunked reads below the line.** No caller wants a transport boundary.
- **WebSockets.** A second protocol, a second operation, and a different shape
  entirely: bidirectional, and not a `Stream`. `Net` would cover it, and it is
  its own record.
- **HTTP/2 multiplexing.** The transport is a `curl` subprocess and this
  changes nothing about it.
- **A connection pool.** One request, one process, today. Worth measuring
  before it is worth designing.
- **A circuit breaker.** Retry is per call site; a breaker is state shared
  across them, and wand has no place to keep it. A script that needs one is
  asking for a supervisor.
- **Retrying a stream mid-body.** The status is eager, so a `429` is known
  before there is a stream to retry. A body that fails halfway cannot be
  resumed without range requests, which is its own record.

## Order

1. Settle Q1 and Q2 — they decide the surface, and the rest is unaffected by
   either answer.
2. `Net!stream` as an operation, resuming with `List String`, and the `Test`
   double beside it. The double comes with the operation, not after it.
3. `HTTP.stream` over the existing `curl` transport with `-N`.
4. `Stream.sse` if Q2 lands that way, with its tests written against a list of
   lines and no network.
5. Q4 last, and as a `Stream` feature if it can be one.

Q3 and Q5 are answers to write down, not code to add.

The retry half is independent of all of it and can go first. Its own order:

1. Settle R1 and R4 — together they fix the predicate's type, and everything
   else is written against that.
2. `Retry.Policy` and `Retry.until` over a wait that a rehearsal can decline
   (R3), with `Test.with_clock` proving the backoff in microseconds — the
   example that module already advertises.
3. R2 is a default to choose, not code to write.

# Design: `Clock` — an eighth effect, and the three deadlines it buys

**Status: proposal — not implemented.** Review before code; the doc
retires once the reference documents the shipped behavior.

## The problem

wand cannot wait. `Duration` is a type with a literal syntax (`30s`,
`5min`) and arithmetic, and nothing anywhere consumes one as a *wait*.
There is no `sleep` and no deadline.

That gap has a script-shaped cost. A command that hangs hangs forever:
`$(curl %{url})` against a host that accepts the connection and never
answers will sit there until someone notices, and the manifest that
promised `Shell(curl)` gave no hint that the promise had no time bound
on it. Retrying with backoff cannot be written. Polling cannot be
written. "Whichever of these three mirrors answers first" cannot be
written.

Fixing that needs a clock, and a clock is an effect. This doc argues
for the eighth label, decides its shape, and then spends it on the
three operations that justify it.

## Why this is one block of work

`Clock` alone is a label with a `sleep` behind it — worth little, and
easy to get wrong in isolation, because a label's shape is only
testable against the things that perform it. `Par.timeout`,
`Par.race`, and `Shell.timeout` are the three operations anyone
actually wants, and each pushes on the design from a different side:
one asks for a deadline, one deliberately does not, one has to kill a
process rather than ask it nicely. Designed together they come out
consistent. Designed one at a time they come out as three unrelated
notions of what a deadline is.

Ordering comparisons on domain literals ride along for a narrower
reason, argued in its own section: without them the main use of
`Clock.sleep` cannot be written.

## The eighth label

The label set is closed at seven and the module comment states the
admission rule: *"A label is added when something can actually perform
it: network access reaches the outside world through a command today,
and so reports as `Shell`."* Network — the label everyone proposes
first — is declined by that rule, because every network access in wand
*is* a `Shell` spawn. There is no primitive that only `Net` would
explain, so `Net` would re-label a subset of `Shell`, and an
undecidable subset at that: nothing can tell the typechecker that
`curl` reaches the network and `ls` does not.

Waiting is not like that. `Clock.sleep` is performed directly by the
evaluator and reduces to nothing else. It has a primitive that only
`Clock` explains, so it clears the stated bar that `Net` fails.

Two objections, answered:

- *"An effect set says what evaluating does to the outside world, and
  sleeping does nothing to it."* Two of the existing seven do nothing
  to it either: `Raise` is "can raise instead of returning" and `Proc`
  is "ends the process". The set is already *things a caller must know
  that the type otherwise hides*, not world-mutation. A call that may
  take unbounded wall-clock time is squarely that.

- *"Seven is memorizable; eight starts a slope."* This is the real
  cost, and it is a cost in reading, not in code. Rows appear in every
  signature, every type error, every `wand t` suggestion, and the
  closed set's whole value is that a reader has a finite vocabulary to
  learn. The answer is not that eight is free — it is that this is the
  cheapest moment the change will ever have (no existing script
  performs it, so of the 45 manifests in the tree, zero change), and
  that the admission rule survives intact and still keeps `Net` out.

**Decision: add `Clock`.** Rendered `Clock`, sorted into `all` by the
existing alphabetical rule, which puts it first.

## The centerpiece decision: one label, not two

The obvious split is `Clock.Read` and `Clock.Wait`, on the `FS.Read` /
`FS.Write` template. Rejected — and decided now, though v1 ships only
the waiting half, because the answer determines whether reading the
clock can later be added without a second label.

`FS` splits because a handler distinguishes the halves usefully:
read-only is a coherent grant, `--dry-run` means something precise, and
there is a real safety gradient — reading cannot destroy anything and
writing can. That is the test a split has to pass.

A clock split fails it in both directions. There is no coherent handler
that grants one half and not the other: a virtual clock that answers a
clock read while `sleep` really sleeps produces a program whose clock
says five seconds elapsed while the wall says thirty, which is worse
than either alone. And there is no safety gradient — `sleep` cannot
damage anything, it only costs time.

So the halves are inseparable to every handler that would ever want
them, and the split would buy nothing but a longer vocabulary.

**`uses {Clock}`** reads as *this script's behavior depends on
wall-clock time* — covering both "may not return promptly" and, when
reading lands, "may not do the same thing twice".

## Why `Clock` and not `Time`

`Time` is taken, and taken by something narrower: it is the type of the
`14:30:00` literal, a time-of-day with no date attached. A module named
`Time` whose eventual clock read returns `DateTime` — while a type
named `Time` exists and means less — is a wart in the one place a
reader looks first.

Module-and-label sharing a name is established (`Proc`, `Env`, `IO`,
`Shell` all do it), and so is type-and-module (`Path`, `Duration`) —
but every existing type/module pair has the property that the module's
functions return the type, and `Time` would be the first to break it.
`Clock` collides with nothing and keeps the module-equals-label rule.

## Reading the clock is not in v1

`Clock.now` is deliberately absent, and this is the cut that keeps the
rest of the design honest.

It would be nearly inert. `DateTime` has no arithmetic at all — no
subtraction, no comparison, nothing connecting it to `Duration`;
`String.to_datetime` parses one and `FS.mtime` returns one, and that
is the entire surface. So a clock read could stamp a string and
nothing else. The task that actually wants it — *rebuild if the
artifact is older than an hour* — needs `now - mtime : Duration`,
which does not exist.

And adding that subtraction arms a trap. Civil time can step backwards
when the machine syncs, so `now - mtime` (correct: both are civil
readings of the same clock) and `now - an_earlier_now` (wrong:
measuring elapsed time with a clock that jumps) are the same operator,
and only one of them is sound.

**Decision: `Clock.now` and `DateTime` arithmetic land together,
later, as one piece of work with that trap documented once.** In v1 no
script can read a clock at all, so there is nothing to misuse.

The consequence worth stating: **v1 needs no monotonic clock.**
`Unix.sleepf` is `nanosleep` — a relative wait, immune to clock steps
by construction — and every deadline below is specified as a relative
wait. Nothing in v1 measures elapsed time. That keeps the dependency
list at four (OCaml's `Unix` exposes only `gettimeofday` and
`sleepf`; a monotonic source would mean the `mtime` package or the
project's first C stub). See "Not in v1" for when this changes.

## Semantics, stated bluntly

- **Every deadline is a relative wait.** Not "until this absolute
  instant" — *how long from now*. This is an implementation
  constraint, not a detail: it is what makes the deadlines correct
  across a clock step without a monotonic clock, and a future
  refactor that computes absolute deadlines from a civil clock would
  silently break them.
- **`Clock.sleep` is a floor, not a promise.** It waits *at least* the
  duration. A loaded machine, a descheduled domain, and a deferred
  interrupt window all extend it.
- **`Clock.sleep Duration.zero` returns immediately** and still
  performs the effect — so a trace and a mock see it, and a virtual
  clock is not silently bypassed by a zero.
- **A negative duration is a zero sleep**, not an error and not a wait
  forever.
- **Interrupts are not deferred across a sleep.** `Ctrl-C` during a
  `Clock.sleep` takes effect at once; a sleep is exactly the wrong
  thing to make uninterruptible.
- **Under a handler, the clock is virtual.** This is what makes
  deadlines testable rather than slow — see below.

## The centerpiece consequence: the virtual clock

Effects are the observability boundary, and a deadline that ignores it
is a deadline no test can afford. A suite that exercises a 30-second
timeout must not take 30 seconds.

**Decision: `Clock` performs are handler-answered like every other
effect, and `Test.with_clock` supplies a virtual one.** Under it,
`Clock.sleep` advances a virtual instant and returns immediately, and
the deadlines below fire off that instant. A test that exercises an
hour of backoff runs in microseconds.

Because scripts cannot read a clock in v1, the helper reports the
elapsed virtual time itself:

```
test "backoff gives up after an hour" (fn t ->
  let (elapsed, result) = Test.with_clock (fn () -> retry fetch) in
  t.eq 1h elapsed)
```

This follows `Test.with_shell`, `Test.without_writes` and
`Test.with_lines` exactly: the helper wraps the handler plumbing, and a
test author never meets the effect's representation. When `Clock.now`
lands, the helper grows a starting instant; the shape does not change.

## Ordering on domain literals

Not a clock feature, and in this block anyway, because without it the
main use of `Clock.sleep` cannot be written.

Durations cannot be compared:

```
30s < 5min     -- runtime error: '<' requires comparable types
30s == 30s     -- true
```

Equality works; ordering does not. `<`, `>`, `<=` and `>=` each handle
only `Int`, `Float` and `String`, and all four fail the same way —
`30s <= 5min` and `100MB >= 4KB` no better than `<`. So retry with
capped backoff — *double the delay, but never sleep longer than 30s* —
cannot be expressed. Every real use of sleeping is a backoff loop, so
shipping `Clock.sleep` without ordering ships a primitive whose main
use is unreachable.

The gap is not temporal — `100MB < 1GB` and `1.2.3 < 1.10.0` fail the
same way. But v1 fixes only the temporal types:

**Ordered in v1:** `Duration`, `Date`, `Time`, `DateTime` (joining
`Int`, `Float` and `String`).

**Ordered later:** `Size`, `Version`, `Port`, `IPv4`. Each has a total
order and each should get one; none is needed here, and `Version`
brings its own question about how semver's prerelease rules apply to
wand's literal.

**Never ordered:** `Path` and `Glob` (lexicographic order would be
mistaken for tree order), `Url`, `Regex`, `CIDR` (no natural total
order).

Stopping at the temporal four is not the arbitrary cut it would have
been under runtime dispatch. Because `Ord` is a type constraint, the
boundary is visible and enforced: `100MB < 1GB` reports that `Size` is
not ordered, at compile time, rather than failing mysteriously at run
time. And widening is purely additive — a member in the list, a
normalizer beside it, nothing to migrate.

`Date` joins even though nothing here needs it: it is free (see
below), and excluding it while including `Time` would be the odd cut.
`DateTime` earns its place on `FS.mtime a < FS.mtime b` — the
make-style *is the source newer than the artifact* check, which needs
no clock and cannot be written today.

**The rule that matters: ordering compares normalized values, never
the stored string.** Every one of these is `of string` in the
evaluator, which makes string comparison the tempting shortcut, and it
is wrong for exactly the cases people hit:

- `DateTime` carries an offset, so `2024-01-15T20:00:00+05:30` and
  `2024-01-15T14:30:00Z` are the same instant and compare unequal as
  strings. Needs normalizing to an instant, which means calendar
  arithmetic — the one type of the four with real implementation cost,
  and the cut line if this block needs to be smaller.
- `Duration` needs its existing internal normalizer (`dur_to_ms`).
- `Date` and `Time` are fixed-width and zero-padded, so lexicographic
  is correct — stated explicitly so the next reader knows it was
  checked, not assumed.

The types held back have the same rule waiting for them: `Version` is
semver, not lexicographic (`1.10.0` is above `1.9.0`, string order
says otherwise), and `Size` needs a to-bytes normalizer that does not
exist yet — only the `str_to_size` validator.

No `Duration.min` / `Duration.max`: with `<` working they are
one-liners at the call site, and one construct per problem.

### The ordered set is a type, not an evaluator table

Comparison is typed `'a -> 'a -> Bool` today, so mismatched operands
are already caught — `100MB < "x"` and `1 < 2.0` are type errors. What
escapes to run time is *same type, not orderable*:

```
[1] < [2]                  -- runtime error
r/x/ < r/y/                -- runtime error
(fn x -> x) < (fn y -> y)  -- runtime error
```

Two functions comparing is enough on its own to call this a bug.

**Decision: introduce `Ord`, a constrained type variable, and give the
four comparison operators `Ord -> Ord -> Bool`.** The list of ordered
types above stops being an evaluator dispatch table and becomes the
constraint's definition — written once, where the typechecker can
enforce it.

This is not new machinery. wand already has exactly one constrained
variable: `Num`, "Int or Float, decided at use", carried as a
`numeric : bool` on the tyvar (~:52) and handled at about six sites —
unify, instantiate, display, and the error message at ~:537. `Ord`
follows it precisely, and composes the same way: `let max a b = if a <
b then b else a` infers `Ord -> Ord -> Ord` and stays polymorphic,
just as `fn x -> x + x` stays `Num -> Num`.

Two details that fall out:

- **`numeric : bool` becomes a constraint variant.** `Num` is a subset
  of `Ord` — `Int` and `Float` are both ordered — so unifying a `Num`
  variable with an `Ord` variable must yield `Num`. Two independent
  booleans cannot express that; a small variant can, and having two
  constraints is the moment to stop using a flag.
- **The error message cannot follow `Num`'s.** "Num is Int or Float"
  works because there are two members; `Ord` starts at seven and grows
  as the held-back types land, so listing them is noise that would
  also go stale. It reports the offending type instead: *`Regex` is
  not ordered*, with the ordered set in the reference rather than in
  every error.

User-defined types are not ordered: there is no deriving mechanism and
inventing one here would be a second block of work.

## The three deadlines

### `Shell.timeout` — the one that matters most

```
Shell.timeout : Duration -> (Unit -> 'a ! 'e) -> Result String 'a ! ('e | Clock)
```

Most script hangs are not wand code, they are a subprocess. This wants
no domains and no racing: wait for the child with a relative deadline,
then `SIGTERM`, then `SIGKILL` after a fixed grace. It is the smallest
of the three, the only one that kills for real rather than
cooperatively, and the one that fixes the failure scripts actually
hit. **If only one of these ships, it is this one.**

The grace period is fixed and documented, not a second parameter: a
caller who wants to think about SIGTERM-versus-SIGKILL is a caller who
should be writing the signal handling explicitly, and an API with two
durations in it invites everyone else to think about it too.

`Error` carries what was killed and how long it got, because that
string ends up in a log and "timed out" alone is useless.

### `Par.race`

```
Par.race : (Unit -> 'a ! 'e) List -> Result String 'a ! 'e
```

Run every thunk at once, return the first to finish, stop waiting on
the rest.

**No worker limit**, breaking `Par.map`'s convention deliberately. That
convention exists because how much a script may do at once is a
decision about the machine, stated rather than inferred — but for
`race` the worker count *is* the list length and is visible at the call
site, so there is nothing left to state. A `race` with a limit below
the list length would be a staged race, which is not a thing anyone
wants.

**First to *finish*, not first to succeed.** A loser that raises is
simply discarded; a winner that raises comes back as `Error`, matching
how `Par.map` puts a raise in the element's place rather than failing
the call. First-to-succeed is a defensible different function and
should not also exist — one construct per problem.

**No `Clock` label.** `race` waits on workers, not on a clock: it never
asks for a deadline, and it returns when one finishes. Nothing about it
is nondeterministic that was not already nondeterministic in `'e`. That
asymmetry against `Par.timeout` is the evidence the label is cutting in
the right place — it appears exactly where a virtual clock would need
to intervene and nowhere else.

**Cancellation is cooperative, and the machinery exists.** Domains
cannot be killed, and `Par` today spawns domains and joins every one
of them precisely so that workers never outlive the call — the
invariant that lets `Par` have no handles and no await. A naive `race`
would break it, returning while three domains still run, and would
hand back exactly the unstructured concurrency `Par` was shaped to
refuse.

The way out is already in the evaluator: `defer_interrupts`,
`interrupt_taken` and `Interrupted` are a cooperative cancellation
mechanism with checkpoints at effect boundaries, built for `Ctrl-C`.
`race` reuses it. The winner's completion sets the losers' interrupt
flags; each loser raises `Interrupted` at its next effect, releases
what it holds, and is joined. **`race` still joins every worker before
returning.** It stops *waiting on an answer it no longer wants*; it
does not leave anything running.

The cost is stated, not hidden: a loser between checkpoints — spinning
in a pure loop, or blocked waiting on a subprocess — finishes what it
is doing. `race` bounds when you get the answer, not when the machine
goes quiet. A loser that must die promptly is a `Shell.timeout` inside
a `race`, and the reference says so.

**Watched mode is left-biased.** `Par` already serializes workers when
a handler is in scope, because an effect cannot reach a handler on
another domain. A raced list under a mock, `--dry-run` or `--trace`
therefore runs in order, and the first thunk that finishes wins — which
is the first thunk, in every case where all of them finish. This is
deterministic and it is the honest extension of the existing doctrine:
being watched costs the overlap, and nobody rehearses for speed. A test
that needs a *specific* racer to win says so with a virtual clock, not
by hoping.

### `Par.timeout`

```
Par.timeout : Duration -> (Unit -> 'a ! 'e) -> Result String 'a ! ('e | Clock)
```

A deadline on wand code, as `race` is a deadline on nothing in
particular. `Error "timed out after 30s"` on expiry — `Result` rather
than `Option` so the message carries the duration, because a timeout in
a log wants to say what it waited for.

Implemented as a `race` between the work and a sleeper, which is what
makes it a relative wait and therefore correct without a monotonic
clock. Same cancellation contract as `race`, same caveat: on expiry the
work is asked to stop at its next checkpoint. Under a virtual clock the
two compose exactly as they should — the work's own `Clock.sleep` calls
advance the virtual instant, and the timeout fires when they advance it
past the deadline, deterministically and instantly.

## Not in v1, each for a stated reason

- **`Clock.now` and `DateTime` arithmetic.** Argued above: inert
  apart, trapped together, and one coherent piece of work on their
  own. This is also the change that brings back the monotonic-clock
  question, because measuring elapsed time is the one use civil time
  cannot serve — and at that point the choice is not free: on Linux
  `CLOCK_MONOTONIC` excludes time spent suspended while
  `CLOCK_BOOTTIME` includes it, and on macOS the names are inverted.
  Whatever ships must pin the semantics per platform and say which.
- **`+` and `-` operators on `Duration` and `Size`.** Today it is
  `Duration.add`; `100MB + 4KB` does not typecheck. Belongs with the
  arithmetic work above, not here.
- **Ordering `Size`, `Version`, `Port` and `IPv4`.** Wanted, and
  additive whenever someone gets to them: a member in `Ord`'s list and
  a normalizer beside it. Held back only to keep this block to the
  types it needs.
- **Deriving `Ord` for user-defined types.** Comparing two
  `Circle`s stays a type error. A deriving mechanism is its own
  design, and nothing in this block wants one.
- **`Clock.deadline` / repeated scheduling.** A poll loop is
  `Clock.sleep` in a recursive function. Cron is not wand's job.
- **`Par.race_ok` (first to succeed).** One construct per problem
  until someone brings a script that needs the other.
- **Postfix or keyword syntax for timeouts** (`$(curl x) timeout 30s`).
  New syntax is a far larger commitment than a label, and three
  functions have to earn their keep first.

## What is touched

- `effect_set.ml`: the `Clock` constructor, `name_of`, and its place in
  `all` (alphabetical: first).
- `typechecker.ml`: the label in `effect_of_name` (~:2287), `"Clock"`
  in `stdlib_module_names` (~:12), the op-table entry for
  `Clock!sleep`, and what the three new operations perform.
- `evaluator.ml`: the `Clock.sleep` primitive and its default handler;
  the virtual-clock handler; `race`'s winner-cancels-losers path over
  the existing interrupt machinery; `Shell.timeout`'s deadline wait,
  `SIGTERM`, `SIGKILL` sequence.
- `evaluator.ml` again, for ordering: the four comparison operators
  (~:911-934) plus a normalizer per ordered type — `DateTime`-to-instant
  is new code, not a new match arm; `Duration` reuses `dur_to_ms` and
  `Date`/`Time` compare as written. `<`, `>`,
  `<=` and `>=` are four identical copies of one three-arm match
  today; they collapse into a single normalize-then-compare helper
  returning an ordering, so the ordered set is realized in exactly one
  place. `==` and `!=` are untouched — they go through `wand_equal`,
  which already handles every type.
- `typechecker.ml` for `Ord`: `numeric : bool` (~:52) becomes a
  constraint variant, with the subset rule in unify (~:526-535),
  instantiate (~:728, ~:795), display (~:401), the new error message,
  and `Ord` accepted as a written annotation beside `Num` (~:858).
  The runtime arms and the constraint's member list must agree; the
  test below is what holds them together.
- `stdlib/Clock.wand` (new), plus `Par.wand`, `Shell.wand`, and
  `Test.with_clock` in `Test.wand`.
- Reference: a `Clock` section, the eighth row in the effects table at
  ~:873, the relative-wait and watched-race rules in bold, the ordered
  and unordered type lists, the module lists, and `Par`'s doc comment —
  which currently says fork-join "and nothing else" and will need to
  say what `race` is and why it still keeps the no-handles promise.
- `README.md` if it enumerates the labels; `CLAUDE.md`'s "seven effect
  labels" line.
- Compile-cache version bump: the effect-set representation changes.

## Test plan

- **The label**: a script that sleeps and does not declare `Clock` is a
  type error; one that declares it and does not sleep is `A-USES1`;
  `wand t --fix` adds the line. `Net` stays absent.
- **Virtual clock**: `Test.with_clock` makes a 1h backoff test run
  instantly and report the elapsed virtual time; `Clock.sleep zero`
  still performs (a trace sees it).
- **Ordering is normalized, not lexical**: two spellings of one
  instant comparing equal across offsets, and one ordering correctly
  against another in a different zone. This is the case a string
  comparison gets wrong, so it is the one that proves the normalizer
  exists.
- **The held-back types report cleanly**: `100MB < 1GB` is a type
  error naming `Size`, not a runtime failure — the boundary is the
  feature, so it is tested.
- **`Ord` rejects at compile time**: comparing two functions, two
  lists, two maps or two regexes is a type error, not a runtime one;
  `let max a b = if a < b then b else a` stays polymorphic and works
  at `Int` and `Duration` alike; `fn x -> x + x < x` infers `Num`, not
  `Ord`, which is the subset rule doing its job.
- **The `mtime` consumer works**: `FS.mtime a < FS.mtime b` decides
  which file is newer, since that is what `DateTime` ordering is here
  for.
- **The two lists agree**: a test that walks the `Ord` member list and
  asserts each type actually compares at run time, so a type admitted
  by the constraint can never reach a missing evaluator arm.
- **`race` joins everything**: an OCaml-level test that the call
  returns only after every domain is joined, and that a loser blocked
  on an effect is interrupted rather than left running. This is the
  invariant worth a dedicated test — it is what stops `race` from
  becoming unstructured concurrency.
- **Watched race is left-biased**: under `Test.with_shell`, a raced
  list returns the first thunk's result, repeatably.
- **`Shell.timeout` actually kills**: spawn a real sleeper via the
  built binary (not `dune exec`, and self-terminating — see the
  bounded-experiment rule), assert the child is gone afterwards, and
  assert the `SIGKILL` path by ignoring `SIGTERM` in the child.
- **`race` + `Shell.timeout` compose**: the documented recipe for a
  loser that must die promptly does.

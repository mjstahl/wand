# Design: `Stream` — reading through, without reading in

**Status: proposal — not implemented.** Review before code; the doc
retires once the reference documents the shipped behavior.

## The problem

wand reads files whole: `FS.read_file!`, then `String.lines`, then list
combinators. Right for the 20-line script; wrong the day the log is
10GB. The language needs a way to fold over a file's lines in bounded
memory — and the design question is what kind of *value* a stream is,
because the obvious kinds are diseased.

## The position: a stream is a recipe

A lazy cursor — an open handle wearing a value's clothes — is wand's
first scope-bound value, Haskell's lazy-IO wound in miniature: escape
the bracket that opened it and the type system happily hands you a
landmine. A memoized lazy list reintroduces the memory problem
streaming exists to solve the moment anything retains the head. Both
rejected.

A **recipe** has neither disease. `FS.stream_lines path` returns an
inert description: a source plus a pipeline of stages. `Stream.map f s`
returns a bigger description. Nothing opens until a **terminal
operation** runs the whole recipe — open, stream each line through the
fused stages, close — entirely inside one call, releasing on the way
out however the call ends. A recipe is as self-contained as every other
wand value: store it, return it, close over it, send it to `Par`.

This is the move `Resource` already made — the value describes the
protocol, it is never the open thing — which makes `Stream` Resource's
twin, not its resident. It cannot *be* a `Resource`: that type's whole
consumption protocol is acquire-once-hand-over-once (`with r as x`),
and iteration does not fit through a hand-it-once doorway — forcing it
through makes the bound `x` a cursor and smuggles the disease back in.
Twin means: the same type shape (`TStream of row * typ` beside
`TResource of row * typ`, printed `Stream {FS.Read} String`), the same
release-on-unwind machinery inside, and the same paragraph of
documentation. `with` remains the language's only bracket; a stream's
brackets are all interior.

## The centerpiece decision: effects at open granularity

Effects are the observability boundary — mocks, `--dry-run`,
`--trace`, and Par's watched mode all live on intercepted performs —
and a fold over a million lines must not escape them. What does
enumeration perform?

- *A perform per line* is honesty no consumer can afford: a million
  trace lines per fold, a mutex round trip per pull under watched Par,
  and mocks forced into a stateful cursor protocol in a language with
  no mutation.
- *One perform carrying the user's closure*, so a mock can run the fold
  itself, is worse than loud — it is wrong: a handler body runs outside
  its own scope, so the closure's effects escape any handler between it
  and the interceptor, and `Test.without_writes` inside a mocked fold
  quietly stops sealing.
- *No perform at all* is the rehearsal hole, disqualified on arrival.

**Decision: one perform per open.** A terminal operation performs a
single `FS!stream_lines`-family effect whose answer is the line source;
the default handler answers with the real file, a test handler answers
with fake lines — statelessly and wholesale, the exact ergonomics of
mocking `read_file` today. The runtime then pulls lines internally,
running stages and the user's closure from the ordinary stack, so their
effects meet handlers in the usual order with the usual guarantees.

The clinching argument: this **preserves the language's current
observability granularity exactly**. `FS.read_file!` is already one
file-level effect; a watcher today sees "this file was read", never
"these bytes were". Streams inherit the same contract — no regression
for watchers, no state machines for mockers, one trace line per fold.
`Test.with_lines path lines thunk` wraps the handler plumbing so test
authors never meet the source's representation.

The consequence, stated precisely: mid-stream powers belong to
**participants, not wrappers**. The fold's own closure runs per line on
the ordinary stack and can count, pace, print progress, or abort by
raising; the runtime, which does the pulling, reports the aggregate
(the trace line at close carries the line count). What no handler can
do is observe or intervene *in flight* on someone else's fold — the
same boundary `Par` already draws, where a watcher intercepts workers'
effects but cannot pause the fan-out mid-run. The one anticipated
victim is the deferred command-output source (`tail -f`), where a test
plausibly wants a reactive, pull-based mock; the open effect's answer
protocol can grow that variant additively when that source lands,
without touching existing folds.

## Semantics, stated bluntly

- **A terminal operation re-runs the recipe.** Fold a stream twice and
  the file is opened and read twice, reflecting the file as it is each
  time. Traversal is not free and not snapshotted; `List` intuition
  does not transfer, and the reference says so in bold.
- **`Par` workers enumerate independently.** A recipe sent to `Par.map`
  re-opens per worker. Consistent with the above; documented beside it.
- **stdin is single-shot.** `IO.stdin_lines` is the one source that
  cannot re-run; a second enumeration raises, catchably, saying why.
- **Failure mid-stream releases.** The file truncated underneath, a
  closure raising at line 40,000: the raise propagates out of the
  terminal operation and the handle closes on the unwind — interior
  `Fun.protect`, no user-facing protocol.
- **Line semantics match the house rules**: the trailing newline does
  not produce a phantom empty line; an empty file is zero lines.

## The v1 surface

Deliberately small, mirroring `List` names exactly where meanings
match:

```
FS.stream_lines : Path -> Stream {FS.Read, Raise} String
IO.stdin_lines  : Unit -> Stream {IO, Raise} String
Stream.of_list  : List 'a -> Stream {} 'a

Stream.map      : ('a -> 'b ! 'e) -> Stream 'r 'a -> Stream {'r, 'e} 'b
Stream.filter   : ('a -> Bool ! 'e) -> Stream 'r 'a -> Stream {'r, 'e} 'a
Stream.take     : Int -> Stream 'r 'a -> Stream 'r 'a

Stream.fold_left : ('a -> 'b -> 'a ! 'e) -> 'a -> Stream 'r 'b -> 'a ! {'r, 'e}
Stream.each      : ('a -> 'b ! 'e) -> Stream 'r 'a -> Unit ! {'r, 'e}
Stream.to_list   : Stream 'r 'a -> List 'a ! 'r
```

(The row spellings above are the intent; the implementation prints them
however `Resource` prints its row today.)

**The error channel.** A recipe is inert, so `FS.stream_lines
missing.log` succeeds and the failure surfaces at the terminal
operation, when the open happens. That raise rides the *stream's row*,
stamped by the source -- following the `!` convention's real rule: the
bang marks a function's own added raise, never effects flowing through
its parameters (`List.map` is not `map!` though `f` may raise through
it). So the terminals stay three, un-banged, and generic; a fold's
failures -- the source's I/O and the closure's raises alike -- arrive
through one channel, and `try` is the one capture:

```
match try (log |> Stream.fold_left tally Map.empty) with
| Ok counts -> ...
| Error why -> ...
```

There are deliberately no Result-returning terminal siblings: a fold
fails from two directions at once, and a `Result` that caught the
source's failures but let the closure's raise past would be a lie. A
fold over `Stream.of_list` provably cannot raise, because its row says
so. `take` is why stages are
interpreted by the runtime rather than desugared: `take 100` of a 10GB
file must stop reading. Not in v1, each for a stated reason: `length`,
`reverse`, `sort` (read-everything traps wearing innocent names —
`to_list` first, so the cost is visible); `zip` (two sources open at
once; wanted, later); streaming a command's output (the tail -f use
case; wants the Shell effect story told first); `drop`, `take_while`
(follow `take` trivially once someone asks).

There is no separate `FS.fold_lines!`: it would be a second spelling of
`Stream.fold_left` over `FS.stream_lines`, and one construct per
problem says no. Nor is one needed for brevity — the stream argument
comes last precisely so the composition pipelines, and a script that
folds the same way twice writes its own one-line helper, specialized
to its own fold:

```
let tally_log path =
  FS.stream_lines path |> Stream.fold_left tally Map.empty
```

Every call site is then shorter than a generic `fold_lines` call would
have been. The dogfood is `examples/log-summary.wand` and the d3 demo,
both currently read-all-then-split.

## What is touched

- `typechecker.ml`: `TStream of row * typ` by `TResource`'s template —
  unify, display, occurs, free vars, instantiate; module signatures.
- `evaluator.ml`: the recipe value, the terminal-op loop (open effect,
  fused stage interpretation, protect-close), `Stream`/source builtins.
- `stdlib/Stream.wand`, plus the two source functions in `FS.wand` and
  `IO.wand`; `Test.with_lines` in `Test.wand`.
- Reference: a `Stream` section beside `Resource`'s, the re-enumeration
  and stdin rules in bold, the module lists; the syntax card's line.
- Compile-cache version bump if the value representation is marshaled.

## Test plan

- Recipes are inert: constructing performs nothing (a trace sees no
  effect until a terminal op).
- Bounded memory: fold a generated large file without materializing it
  (observable via `to_list` vs `fold_left` on a size that would be
  felt).
- Fusion and early exit: `take n` stops reading. Provable only below
  the effect boundary — under open-granularity a wand-level mock hands
  its lines over wholesale and cannot count pulls — so this is an
  OCaml-level test injecting an instrumented source into the terminal
  loop.
- Re-enumeration re-opens (mock counts opens); `Par` workers open
  independently; stdin's second enumeration raises.
- Interception: `Test.with_lines` feeds a fold; `without_writes` seals
  a closure that writes, *inside* a mocked fold — the option-B failure
  case, locked as a test.
- Mid-stream raise releases the handle; the raise is catchable with
  `try`.
- Effect rows: a stream's row unions stage rows; `fold_left`'s
  signature carries both; a manifest that omits `FS.Read` rejects a
  stream-folding file.
- Line semantics: trailing newline, empty file.

## 0.50.0 - 2026-08-25

Three ways a script could end with a raw OCaml exception, and none of them do
now: an effect in an imported module, an operation with no handler, and
nesting calls without end. Each ended the run with an OCaml fatal error —
two of them naming an internal constructor — none of them carrying a
position, and none of them catchable.

The last could not be fixed by catching it. `Stack overflow` cannot be caught
on this runtime: a handler that matches it hangs rather than unwinds, and so
does one whose guard rejects it, because the guard runs on the stack that
just ran out. So the depth is bounded before the stack goes. That bound
refuses a non-tail recursion deeper than a million, and is the one change
here that can reject code that ran before.

The rest is smaller. A lint's verdict is reachable now from the path that
runs the file: `wand a.wand --lint` reports the findings and runs it anyway,
because a lint is not a type error and not a compiler error, and so is not a
condition of running unless `--strict` asks for that. A Unit answer that was
suppressed is printed. A constructor that swallowed an argument is corrected
rather than only reported.

### Added

- `wand a.wand --lint` reports the lint findings, then runs the file.
  Findings go to stderr, so stdout stays the script's. `V-IMP1` — a later
  import silently deciding an earlier line — was reachable from `wand t`,
  from the editor and from the test runner, and from nothing that ran a
  file: loudest where the shadowing is harmless and silent where it does its
  work
- `wand a.wand --lint --strict` makes a violation a failure, and a failure
  does not run. `--strict` is wand's only beside `--lint`; on its own it
  reaches the script untouched, as every other subcommand's flag does
- `WAND_MAX_CALL_DEPTH`, how deep calls may nest before a run is refused.
  Lower it when the stack is smaller than the default — under
  `OCAMLRUNPARAM=l=...` or a small `ulimit -s` — because a bound above what
  the stack can carry never fires

### Changed

- **A call that nests deeper than 1,000,000 is refused.** A call with work
  waiting on it keeps a frame, so nesting without end exhausted the stack.
  The depth is bounded before that happens and the refusal is a wand error a
  script can catch. Only `apply` is bounded and never `apply_tail`, so a
  tail-recursive loop still runs to any depth. A non-tail recursion deeper
  than the bound ran before and does not now; reaching that depth costs time
  quadratic in it, because the frames are live roots and every minor
  collection rescans them, so what this rejects was already paying for the
  depth. `WAND_MAX_CALL_DEPTH` raises it

### Fixed

- An expression that answers Unit without performing anything prints its
  answer. `()` was silent, and so were `let u = () in u` and `if c then ()
  else ()`. Every Unit was suppressed, which is right for `IO.println "hi"`
  — the line is already on the screen — but the suppression keyed off the
  value, and a unit you asked to see has the same value as one a call handed
  back. It keys off the effects the expression performed now
- An effect in an imported module's top-level binding runs. `let greeting =
  $(hostname)` at the top of a module ended the program with
  `Unhandled(WandEffect ...)`. The cause was ordering, not policy: imports
  were evaluated before the handler was installed, in every run path.
  Manifests are unchanged — a module whose `uses` is narrower than what it
  does is still refused
- An operation with no handler comes back as a wand error naming it. The
  handler's cases end in a fallthrough, so an unknown name or a payload of
  the wrong shape reached OCaml's `Effect.Unhandled` and printed raw
- A bare constructor that swallowed an argument is corrected, not just
  reported. `f None (1)` is `f (None 1)`, and the argument meant for the
  call went to `None`. The checker knew the arity and said to write
  `(None)`; `wand t --fix` and the editor's code action write it now. The
  parse is unchanged — reading arity there is what made `Ctor (a, b)` mean
  different things in different files

The bound on nesting is a count, and the stack it stands in for is not: under
a smaller stack it never fires and the fatal comes back. `docs/gaps.md`
records that, and `WAND_MAX_CALL_DEPTH` is how to suit the bound to the stack
a run actually has.

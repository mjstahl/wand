# Wand-writing benchmark suite

## Context

Language and doc changes intended to help an LLM write correct wand (e.g.
the type-annotation/print-symmetry fix — making `:t`'s printed types like
`List Int`/`(Int, Int)`/`Int -> Int` actually parseable as annotations,
implemented 2026-07-25) are argued to help, but that claim has been
untestable — there's no measurable signal for "does this language or doc
change actually improve an LLM's hit rate," only anecdotes from whatever
comes up in conversation. This is a benchmark harness, not a language
change, and should be tracked and executed separately from any specific
language fix.

## Goal

A fixed suite of small coding tasks, generated **single-shot with no
execution feedback** (no `:t`/`:e` REPL loop, no iterating on errors) and
scored automatically, so results are comparable across language/doc
revisions over time. Single-shot isolates "can an LLM produce correct wand
on the first try" from "can it converge given a feedback loop" — different
capabilities, and the first one is what's actually at stake when evaluating
whether a syntax fix helps.

## Design

**Task corpus**: ~20-50 small specs spanning the language's actual surface —
arithmetic/`String` ops, pattern matching over ADTs, recursion/`List`
processing, `Result`-based error handling, stdlib usage (`JSON`/`CSV`/
`TOML`/`Map`/`Env`), and both constructor-field styles (positional and
named). Each task: a natural-language spec, a target function signature,
and a set of hidden input/output test cases.

**Storage**: a `bench/` directory, one subdirectory per task —
`spec.md` (the prompt given to the LLM), `cases.wand` or `cases.json`
(hidden test inputs/expected outputs), optionally a reference `solution.wand`.

**Scoring, two stages per task** (these diagnose different failure modes,
so report them separately, not just pass/fail):
1. **Parses/typechecks?** (`dune exec wand -- t <file>` succeeds) — isolates
   syntax fluency specifically; this is the class of failure that motivated
   the annotation-syntax fix (guessing `List Int` was writable, guessing at
   `Rect (Int, Int)` semantics before it was resolved).
2. **Passes hidden tests?** (given it parses) — isolates logic/stdlib
   correctness, independent of syntax fluency.

**Harness**: a script that, for each task, feeds `spec.md` to an LLM with no
repo context and no tool access, saves the raw output as a `.wand` file,
then runs it through the `Runner`/CLI to check parse + typecheck + test
results, aggregating into a report (per-task status + failure category:
parse error / type error / wrong output / pass).

**Before/after comparison**: run the full suite against a given wand
revision, then again after a language/doc change, same tasks, same
prompts, no feedback either time. Parse-rate specifically should visibly
rise if closing a syntax gap actually helps — turning an argument into a
number instead of an assertion.

**Tracking over time**: store dated snapshots (e.g. `bench/results/
2026-07-25.md`) with parse-rate, typecheck-rate, test-pass-rate, and a
failure-category breakdown, so future language/doc changes can be evaluated
the same way rather than by anecdote.

## Order of work

1. Draft the task corpus (~20-50 specs) covering the surface areas above.
2. Write the scoring harness (parse/typecheck/test-pass checks against the
   `Runner`/CLI, likely as an OCaml test executable or a small script
   wrapping `dune exec wand`).
3. Run a baseline against the current language and record results.
4. After each subsequent language/doc change, re-run the identical suite
   and diff parse-rates/test-pass-rates against the baseline.
5. Keep dated result snapshots under `bench/results/` for trend tracking.

## Verification

- Harness produces a reproducible report (same tasks scored the same way
  each run) with per-task pass/fail and failure category.
- Baseline run completes and produces a real (not hypothetical) parse-rate
  and test-pass-rate number.

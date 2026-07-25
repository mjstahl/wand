# Wand-writing benchmark

Measures whether an LLM can write correct wand single-shot (no `:t`/`:e`
feedback loop, no iterating on errors). See
`.claude/plans/wand-benchmark.md` for the full design rationale.

## Layout

Each `tasks/<NN-slug>/` contains:
- `spec.md` — the natural-language prompt given to the model, with no
  repo context beyond the language reference it's handed alongside it.
- `cases.wand` — a wand script that `import ./solution` and asserts
  against it, printing `FAIL: <label>` and exiting 1 on the first failing
  check, or printing `ALL PASS` and exiting 0 if everything passes.
- `reference.wand` — a hand-verified correct solution (used to validate
  `cases.wand` itself, not fed to the model, not scored).
- `solution.wand` — the model's generated answer, dropped in by whoever
  runs a generation pass. Absent until a generation pass fills it in;
  `run.sh` skips any task without one.

Task `08-generic-stack` has no `reference.wand` — it requires a real
generic user-defined type, which fails to parse before
`.claude/plans/generics.md` lands (see its `NOTE.md`). This is
deliberate: it's the sharpest available probe of the pre-generics gap.

## Running

```
bench/run.sh [--label NAME]
```

For each task with a `solution.wand`, checks (1) does it parse/typecheck
on its own, then (2) does `cases.wand` pass. Prints a per-task PASS/FAIL
(with failure category: parse error / type error / wrong output / runtime
error) and writes `bench/results/<label>.md` (default label: today's date).

## Generating solutions

Solutions should be generated **single-shot**: give the model only
`spec.md` plus the language reference (`README.md`), no tool access, no
execution feedback, no iterating on errors. Save its raw output as
`solution.wand` in the task directory, then run the harness.

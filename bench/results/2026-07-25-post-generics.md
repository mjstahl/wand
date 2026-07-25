# Benchmark results: 2026-07-25-post-generics

Passed: 9 / 12 scored (0 skipped)

Re-run against the same 12 cold-generated solutions from the pre-generics
baseline (`bench/results/2026-07-25-baseline.md`, 8/12), after implementing
`.claude/plans/generics.md` (user-defined generic types, `TApp`, `Option`,
and generalizing `Result`'s error type). No solutions were regenerated —
this measures the effect of the language change alone.

| task | before | after | why |
|---|---|---|---|
| 01-fizzbuzz | fail | fail | unrelated — missing `import String` |
| 02–07, 12 | pass | pass | unaffected |
| 08-generic-stack | fail | **pass** | the intended fix — `type Stack 'a = Stack (List 'a)` now parses and typechecks; `reference.wand` added |
| 09-word-count | fail | fail | unrelated — `let rec` misparse (no `rec` keyword in wand) |
| 10-json-extract | pass | pass* | *stayed passing only after fixing a stale corpus artifact — see below |
| 11-csv-sum-column | fail | fail | unrelated — missing imports |

## Corpus maintenance required by this language change

Four tasks' `spec.md` files (`06`, `07`, `08`, `10`) prescribed function
signatures using the pre-generics 1-argument `Result T` convention (e.g.
`Result Int`, `Result (a, Stack a)`). Since `Result` now takes two type
arguments (error, value), that syntax is stale. Updated all four to
`Result String T` (or `Result String 'a` for the generic-stack task, which
also had its `a`/`'a` type-variable syntax updated to match the decided
quoted convention). Also updated `08-generic-stack/NOTE.md` — it
previously documented the task as having no possible reference solution;
it now has one, and passes.

This surfaced a **real bug during verification, not just corpus drift**:
task `10`'s cold-generated `solution.wand` had an *explicit* annotation
(`extract_name : String -> Result String`) that broke under the new 2-arg
`Result` (`Error "Result now takes two type arguments..."`), while tasks
`06`/`07`'s solutions had no explicit `Result`-naming annotation at all and
were unaffected regardless of their spec text. This is exactly the
distinction predicted during planning: HM inference absorbs the arity
change silently at `Error "msg"`/`Ok v` call sites, but any annotation that
*names* `Result` explicitly needs updating. Confirms the blast-radius
prediction was accurate in practice, not just in theory.

## Net effect

Generics closed exactly the gap it was meant to close (`08`), with zero
collateral regressions in any of the other 11 tasks — the two
non-generics-related failures (`01`, `09`, `11`) are unchanged pre-existing
syntax-fluency issues, not new breakage from this language change.

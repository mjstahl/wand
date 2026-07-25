This task was the sharpest pre-generics gap probe in the corpus: before
generics landed, `type Stack 'a = ...` (or the pre-decision bare-`a` form)
failed to parse, since `type_def` had no type-parameter slot at all.

`reference.wand` was added once generics shipped (see git history around
2026-07-25) and confirms the loop closed — `bench/run.sh` now scores this
task PASS. `cases.wand` was validated pre-generics against a temporary
Int-hardcoded stand-in (nested match, tuple-pattern destructuring in
`pop`, `&&`), which passed everything except the "works for strings" case,
as expected at the time.

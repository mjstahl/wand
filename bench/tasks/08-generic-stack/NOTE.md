This task has no `reference.wand` — as specified (generic over element
type, not hardcoded to `Int`, not just `List` directly), it cannot be
solved correctly before `.claude/plans/generics.md` lands: `type Stack a =
...` fails to parse (`type_def` has no type-parameter slot). This is
deliberate — the point of this task is to measure the pre-generics failure
mode directly, then re-check once generics ships.

`cases.wand`'s non-generic parts (nested match, tuple-pattern destructuring
in `pop`, `&&`) were validated against a temporary Int-hardcoded stand-in,
which passed everything except the "works for strings" case, as expected.

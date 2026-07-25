Define a wand type `Stack` that is generic over its element type (i.e. a
`Stack Int` and a `Stack String` are both valid, distinct instantiations —
don't hardcode the element type to `Int`, and don't just use `List`
directly in place of a dedicated `Stack` type). Give it a single
constructor wrapping the elements.

Implement:
- `push : a -> Stack a -> Stack a` — push an element on top
- `pop : Stack a -> Result (a, Stack a)` — remove and return the top
  element along with the remaining stack, or `Error "..."` if empty
- `peek : Stack a -> Result a` — return the top element without removing
  it, or `Error "..."` if empty
- `empty : Stack a` — an empty stack

Write only the type and function definitions needed — no example calls,
no top-level script.

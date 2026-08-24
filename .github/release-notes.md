## 0.45.0 - 2026-08-24

A field puns, in a pattern and in a construction.

    match p with | Pod(name, restarts) -> "%{name}: %{restarts}"
    let p = Pod(name, restarts)

Both are what you would have written as `Pod(name = name, restarts =
restarts)`. A map has punned since it got braces, and a record had no
equivalent, so field names in a record pattern were spelled twice -- and the
repetition grew with the record.

Which reading a list of bare names carries comes from the declaration, not
from the spelling. `Pod` names its fields, so those are fields. A constructor
whose payload is a tuple reads the same list as the tuple, so `Some(a, b)` is
what it always was. The space in `Pod (name, restarts)` decides nothing, and
a single name is the payload either way.

A pun mixes with a field that carries a value: `Pod(name, restarts = 0)` in a
pattern, `Pod(restarts = 0, name)` in a construction. The construction is the
narrower of the two, because a bare name written first is the base of an
update:

    Pod(base, restarts = 7)   -- the update, as before

Writing a pun there gets a type error that names the reordering.

Also fixed: `type X (T, U)` left the parser's bracket count raised, so no
newline after it ended a top-level statement. A definition two lines down was
read as a continuation of the one above it, and `wand f` wrote that reading
back to the file -- the formatter changing what the source meant. Every
rewind in the parser now restores the count with the position.

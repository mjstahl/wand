## 0.42.0 - 2026-08-22

A tail call does not grow the stack, so a loop written as one runs to any
depth.

    let sum 0 acc = acc
    let sum n acc = sum (n - 1) (acc + n)

    sum 10000000 0

That is new. On 0.41.0 the same script ran out of stack. Nothing about how a
script is written changes, and evaluation is faster across the board:

    tail-recursive loop, 200k         245 ms ->  45 ms
    tail-recursive loop, 1.6M      11,642 ms -> 323 ms
    List.fold_left over 200k          449 ms -> 100 ms
    map and filter over small lists   829 ms -> 451 ms
    non-tail recursion, 400k          731 ms -> 401 ms
    a loop that stays shallow         209 ms -> 151 ms
    startup                           7.8 ms -> 7.5 ms

### Where the time was going

Every `Located` node wrapped evaluation in an exception handler, to stamp a
line and column onto an error passing through it. A handler is a stack
frame, and a `Located` sits on every function body and every match arm, so a
frame stayed behind on each one. Frames on the tail path never come back, so
the stack grew with the call chain — and every minor collection rescans the
whole stack, which made a long recursion cost time quadratic in its own
depth. The position now travels in a cell, which leaves the tail call a tail
call.

Every step of evaluation also asked whether it should stop, and reaching
that answer read two pieces of domain-local state — more, on the shapes a
script actually runs, than resolving all of its names. Both reasons to stop
are announced globally before any domain can see them, so two atomic loads
now rule them out.

An error still reports the line and column it was raised at. Ctrl-C still
stops a running script in about a millisecond, and a losing racer still
stops where it stands.

### Written down

`docs/reference.md` now says which positions are tail positions: the last
statement of a block, either branch of an `if`, the body of a match arm, and
the body of a `let ... in`.

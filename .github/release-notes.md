## 0.57.1 - 2026-09-04

`try` now discharges a raise across a function boundary. 0.57.0 gave `handle`
that and left `try` with the limit it had. This is the other half.

### The caught raise that leaked

`try` answers a raise with a `Result`. It did that only when the body's
effects were already known:

```ocaml
fn () -> try List.head! []
-- Unit -> Result String 'a               correct: the raise is caught
```

A wrapper takes the body as a parameter, and a parameter's effects are an
open set with nothing known in it. Taking `Raise` out of the known half
removed nothing, so the argument row and the result row stayed one variable:

```ocaml
let attempt f = try f ()
fn () -> attempt (fn () -> List.head! [])
-- Unit -> Result String 'a ! {Raise}     wrong: it answered a Result
```

That line is the bug entire. The result is a `Result`, so the raise *was*
caught, and the signature still said the expression could raise. It leaked
to every caller of the function that caught it.

`try` splits the tail now, the way a handler has since 0.57.0:

```ocaml
attempt : (Unit -> 'a ! {Raise | 'e}) -> Result String 'a ! 'e
```

The argument asks for a thunk that may raise and answers one that cannot. A
thunk that never raises still passes, because a generalized row instantiates
fresh.

### V-BANG1 read the wrong half

A `!` on a name says the function can raise, and `V-BANG1` finds a function
that raises without one. It asked whether `Raise` appears anywhere in the
type. That was the same question until now: a function's argument row and
its result row could not disagree.

They can now. A `try` wrapper carries `Raise` on its argument and not on its
result, and `V-BANG1` read both -- so it told `attempt` to rename itself
`attempt!`. That is the opposite of what `attempt` is. It is the version
that returns a `Result`.

A raise the caller may bring is not one the function performs. Argument
positions no longer count, and positions flip through them: a function this
one is handed is one it calls, and a function handed to *that* one is one
this one supplies. It is the rule manifests took in 0.57.0, for the same
reason.

The rule still reads what a function itself does. `let first xs = List.head!
xs` is still told to be `first!`.

### Two signatures say what they always did

`Test.test` and `Test.group` wrap the body in `try`. A test body that raises
is a failure, not a crash. Neither signature said so:

```ocaml
-- before
test : String -> (Testing 'b 'a -> TestOutcome ! 'e) -> TestOutcome ! 'e

-- after
test : String -> (Testing 'b 'a -> TestOutcome ! {Raise | 'e}) -> TestOutcome ! 'e
```

`group` changed the same way. No call site changes. The two stopped
understating what they do.

### What this breaks

Nothing. Every signature that changed became more precise in the direction
that admits more, so a call that typechecked before typechecks now. The 1404
tests in `test/wand` all call `Test.test`, and none of them moved.

### Also

`handle` and `try` agree now, and both go through `Effect_set.discharge`.
Two rules are unchanged: an effect is discharged only when every operation
carrying it is handled, and answering an operation fixes what it returns
whether or not the label goes away.

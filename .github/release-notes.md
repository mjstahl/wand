## 0.44.0 - 2026-08-23

A `Result` module, with three functions.

    to_option : Result 'b 'a -> Option 'a
    ok?       : Result 'b 'a -> Bool
    error?    : Result 'b 'a -> Bool

`Option` had eight combinators and `Result` none, though `Result` is the
commoner of the two: every fallible operation answers with one, and `try`
makes one. The asymmetry showed up as work. `Env.get`, `Map.get` and
`List.get` each wrote this out by hand:

    match ... with
    | Ok v -> Some v
    | Error _ -> None

which is one function spelled three times. All three are written with
`to_option` now.

`Option.to_result` already existed, so the crossing between the two types was
named going one way and hand-written coming back. `to_option` is the way
back, and drops the reason on purpose: it is for a caller with somewhere to
put "no value" and nowhere to put "because".

`ok?` and `error?` are the same question either way, so the failing branch can
be the one a script is written around, and either can be handed to
`List.filter` without brackets.

Matching a `Result` stays the usual way to deal with one. These are for the
three questions a match cannot ask more briefly.

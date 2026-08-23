## 0.43.1 - 2026-08-23

0.43.0 said every function in the standard library carried an example. 53 of
them did not.

The count that made it look complete was per module: every module reported a
number, no function was ever asked whether it had one, and a module with one
example and fifteen functions passed the gate exactly like a finished one.

They have examples now — 296 of 303 functions, 357 examples. Most of the gap
was systematic rather than random: each `Result` and `!` pair had the raising
half documented and the `Result` half skipped, which is backwards. The
`Result` is the half whose shape a caller has to handle:

    -- >> with FS.temp_dir "ex_" as d ->
    -- ..   (match FS.delete (Path.join d ./missing) with
    -- ..    | Ok _ -> "gone" | Error _ -> "was not there")
    -- "was not there" : String

The seven that cannot have one are listed in `tools/check_docs.wand` with the
reason: `Proc.exit` ends the process, five `IO` readers wait on stdin, and
`IO.flush` neither answers nor writes.

### The gate counts functions now

It ran every example and checked that each produced what it said. It never
asked which functions had none, so it could not have caught this. It counts
per function now and fails on any non-exempt function without an example —
checked against a real gap rather than assumed.

### A lint that suggested an impossible name

`V-BANG1` tells a function that can raise to end its name in `!`. For a
predicate it said `found?` should be `found?!` — and a name takes one
ending, so `ok?!` and `ok!?` are both parse errors. The advice could not be
followed by anyone who received it.

It raises, so it ends in `!`: `found?` is `found!`.

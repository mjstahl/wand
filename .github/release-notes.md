## 0.55.4 - 2026-08-31

One `wand f` fix, found by the daily fuzzer. `wand f` writes in place, so it
changed a file it was asked to tidy.

### An `and` group stays under the `let` it belongs to

A binding's value runs onto the next line only where that line is indented
past its `let`. That is what lets a file be read the way it looks: a line
level with the keyword, or left of it, is the next thing rather than more of
this one.

A function binding writes its `in` on a line of its own and opened what
follows on that same line, so a `let ... and ...` group written there started
three columns right of the `in`. The group laid its own continuation out at
the `in`'s indent instead. A value that wrapped, and the `and` line under it,
landed left of the `let` they belong to:

```
$ cat r.wand
let describe t = t
in
let render row = String.join " | " (List.map describe (List.append row.header row.cells)) (List.length row.header)
and width n = n
in ()

$ wand f r.wand
$ cat r.wand
let describe t = t
in let render row = String.join
  " | "
  (List.map describe (List.append row.header row.cells))
  (List.length row.header)
and width n = n
in ()

$ wand f r.wand
Error: r.wand: parse error: 6:1: unexpected token: and
```

A chain of more than one line now takes the whole line, which is what a value
binding's `in` already did:

```
$ wand f r.wand
$ cat r.wand
let describe t = t
in
let render row = String.join
  " | "
  (List.map describe (List.append row.header row.cells))
  (List.length row.header)
and width n = n
in ()
```

The value has to wrap before the `and` moves out from under its `let`, so a
group whose bindings each fit on a line was never touched. Two files in the
test corpus move: an `in` that shared a line with a chain of more than one
line now sits alone. The bug was present in 0.55.3 and earlier. Nothing else
changed: the command line, the type checker and the lint rules are exactly
0.55.3's.

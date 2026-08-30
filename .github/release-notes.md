## 0.55.3 - 2026-08-30

Two `wand f` fixes, both found by the daily fuzzer. `wand f` writes in place,
so each one changed a file it was asked to tidy.

### A comment survives a separator written above it

An item that opens with an operator continues the item above it, so `wand f`
writes back the `;` that separated the two. A comment runs to the end of its
line and swallows whatever follows it, so where that line ended in a comment
the `;` landed inside it:

```
e--
-"";--     -->  -"";--;
-
--
let h=t
```

The comment's own text changed, which is the one thing `wand f` promises not
to do. 0.55.2 stopped that `;` growing once per pass; it is now not written
at all, because a comment ends the line it is on and the operator below it is
not continuing anything.

### A constructor behind a module's name is guarded

A constructor takes the bracket written after it, so `wand f` brackets an
argument that would otherwise take one belonging to the call. That guard
reads the flattened application spine, and the spine stopped at a module's
name.

`p.M N` and `p.M(N)` are the same program built two ways. Only the first
reached the guard as a head and an argument; in the second the constructor
sat inside the head, where nothing guarded it:

```
$ cat m.wand
let x = p.M(N)(9 [])

$ wand f m.wand
$ cat m.wand
let x = p.M N (9 [])
```

`N` now takes the bracket, so the call has one argument where it had two.
Both spellings reach the guard as one head and two arguments now, and each
piece that could take a bracket it does not own is given its own:

```
$ wand f m.wand
$ cat m.wand
let x = (p.M) (N) (9 [])
```

Both were present in 0.55.2 and earlier. Nothing else changed: the command
line, the type checker and the lint rules are exactly 0.55.2's.

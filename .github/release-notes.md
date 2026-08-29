## 0.55.2 - 2026-08-29

Two fixes, both reached through `wand f`. Either one turned a working file
into one that does not parse, and `wand f` writes in place.

### A constructor's brackets hold a block

`(a; b)` is a block anywhere a bracket opens — statements in sequence,
valuing the last. After a constructor it was a parse error:

```
$ wand t -e 'Some (let x = 1; x + 1)'
Error: parse error: 1:16: expected ), got ;
```

A bracket after a constructor names fields, one per comma, and the branch
that reads it took an expression and then only `,` or `)`. A `;` can never
be a field list, so the bracket is now the ordinary one. `Ctor (a; b)` and
`Ctor (let x = 1; f x)` are the constructor applied to that block.

`(Some)(a; b)` — the same node, with the head bracketed — always parsed.
`wand f` writes an application head without its brackets, so it turned the
spelling that worked into the spelling that did not.

### `wand f` writes a statement separator once

An item that opens with an operator continues the item above it, so the `;`
that separated the two is written back. Where the item above was copied
verbatim it already ended in that `;`, and a second one went on after it:

```
()--
-let e = ();      -->  -let e = ();;   -->  -let e = ();;;
--
let k = ()
```

The line grew a `;` per pass, for ever. `wand f` now asks what the line
above ends with rather than what kind of item it is.

Both were present in 0.55.1 and earlier. Nothing else changed: the command
line, the type checker and the lint rules are exactly 0.55.1's.

## 0.53.2 - 2026-08-28

One fix. **If you are on 0.53.1, take this one** — `wand f` could corrupt a
file, and it writes in place.

### `wand f` could grow a file without bound

0.53.1 writes a `;` before a top-level item that opens with an operator, so
the item does not read as a continuation of the one above it. The separator
goes on the piece above — and a comment cannot hold one. A comment runs to the
end of its line and swallows whatever follows, so the `;` became part of the
comment, the operator line still opened a line of its own, and the next pass
wrote another:

```
--          -->   --;        -->   --;;
-                 -                -
--                --               --
let e=e           let e=e          let e=e
```

A character per pass, without bound. The comment's own text changed under it
too, so a file could lose what its author wrote there. `wand f` writes in
place, so a file formatted twice was a file corrupted twice.

Nothing is owed above a comment in the first place: a comment ends the line it
is on, so an operator below it is not continuing anything.

**0.53.0 is not affected.** Only 0.53.1 carries this.

Found by the fuzz oracle, on all eight seeds of one sweep — eleven findings,
one bug. The reproducer is
`test/fuzz/regressions/formatter-separator-written-onto-a-comment.wand`, and
`dune test` runs it from here on.

Nothing else changed. The command line, the type checker and the lint rules
are exactly 0.53.1's.

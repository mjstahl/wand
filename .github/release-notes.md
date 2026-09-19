## 0.80.3 - 2026-09-18

One formatting change.

### `wand f` no longer brackets a match that stands as a statement

The parentheses were for the reader, not the parser, and they made a match
in the middle of a block look unlike the match that ends one.

```
-- before                     -- now
(match same with              match same with
 | false -> stop ()           | false -> stop ()
 | true -> ());               | true -> ();
```

A match that is a binding's value is unchanged: it still ends on `in`,
which no arm can swallow. Run `wand f` once and your own files settle the
same way.

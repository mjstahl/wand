## 0.80.4 - 2026-09-19

One parser fix.

### A positional payload reaches through a lowercase module

A module bound by `let l = import ./lib` has a lowercase name, so the type
`l.S` opens with a word the parser also reads as a variable. The bracketed
spelling read it; the unbracketed one `wand f` writes did not, and the
payload became a statement below the constructor.

```
-- type T(l.S) formatted
-- before        -- now
type T = T       type T = T l.S
l.S
```

Both spellings read it now, so a type declared this way survives `wand f`.
An applied type and the arguments of `implement` read it too.

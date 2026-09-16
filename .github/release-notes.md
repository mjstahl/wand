## 0.77.1 - 2026-09-16

One fix, from the daily fuzzer.

### `wand f` kept a contract's bracket off a glob's star

A contract body that opens with an operator is bracketed, so the line starts
something new rather than continuing the clause above it. A glob opens with
a star, and the bracket went straight onto it:

```ocaml
let f n =
  requires n > 0
  **/*.wand
```

The body came back as `(**)`, which the lexer reads as an attempt at a block
comment. The body was saved and the file stopped parsing anyway.

The formatter has one place that writes an opening bracket in front of
emitted text, and it has held the space for this since three earlier
findings of the same shape. The contract case wrote its bracket by hand
instead. It no longer does.

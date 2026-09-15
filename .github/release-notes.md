## 0.75.0 - 2026-09-15

`wand f` writes `;` where it wrote `in`, and a stray `in` now says what it
is for.

### One separator for a binding's body

`in`, a block's `;`, and the newline that ends a right-hand side all bind the
name over the same body. They are one thing to the compiler, and they now
come back one way:

```ocaml
-- before
let of_hex algorithm text =
  let want = _hex_length algorithm in
  let lower = String.lower text in
  String.length lower == want

-- after
let of_hex algorithm text =
  let want = _hex_length algorithm;
  let lower = String.lower text;
  String.length lower == want
```

A chain of bindings needs no brackets either, so a body written as a block
loses them:

```ocaml
-- before
let timed thunk = (
  let before = clock_elapsed ();
  let answer = thunk ();
  (clock_elapsed () - before, answer)
)

-- after
let timed thunk =
  let before = clock_elapsed ();
  let answer = thunk ();
  (clock_elapsed () - before, answer)
```

Across the standard library, the tests and the examples this took out 140
dangling `in`s, 27 `in`s that had a line to themselves, and 10 pairs of
brackets.

### What `in` still says

Two spellings survive, and each says something the `;` cannot.

`in` stays where the value ends on a `match` or `handle` arm. An arm runs to
the next `|`, so a `;` sitting on one is read as part of it; `in` is a
keyword no arm can swallow, and it needs no brackets to hold the two apart:

```ocaml
let release =
  fn taken -> match taken with
    | Ok taken -> fs_unlock taken
    | Error _ -> ()
in
Resource.make acquire release
```

`in` also stays where it narrows. Written ahead of a `;` it keeps the name
off the statements below, which is meaning rather than spelling:
`(let x = 1 in x + 1; 9)` gives `x` to `x + 1` and to nothing after it.

The brackets stay where the statements are not all bindings. A `;` outside
them ends a binding's right-hand side and hands the rest to its body, and
that is the whole of what it does there -- a statement that binds nothing is
not joined to what follows by a `;` any more than by a newline.

Nothing you have written stops working. All three spellings still parse, and
only what `wand f` prints has changed.

### A stray `in` says what it is for

`in` belongs to a `let`. Reached without one, the message named the bracket
or the token and left the reader to work out which of the three parts was
wrong:

```
(fn () -> g x in y)
-- before: expected ), got in
-- after:  'in' closes a 'let' and there is none open here; a binding is
--         'let name = value in body', or 'let name = value;' with the
--         body below
```

See the [CHANGELOG](https://github.com/mjstahl/wand/blob/main/CHANGELOG.md)
for the full list.

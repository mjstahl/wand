## 0.76.0 - 2026-09-15

A definition's body takes statements, as a binding's body already did.

### The same two lines, two answers

```ocaml
-- this was a type error
let go () =
  IO.println "one"
  IO.println "two"

-- this ran, and still does
let go () =
  let a = 1;
  IO.println "one"
  IO.println "two"
```

Whether a body sequenced depended on whether a binding happened to come
first, which is nothing a reader could see.

A binding anchors at its own `let`, so a line level with it starts a new
statement. A definition's body kept the definition's column, so a line one
indent in was past it and read as more of the same expression -- which is
how two `IO.println`s became one applied to the other. The body anchors at
its own column now, where it begins a line of its own.

Cuddled after the `=` or an arrow it keeps the outer anchor, because there
the body starts right of the lines below it:

```ocaml
let f =
  fn p -> String.replace
    "a" "b" p
```

Both spellings of a body now print the same way, which is the point of the
fix. `wand f` writes the block form for either:

```ocaml
let go () = (IO.println "one"; IO.println "two")
```

Nothing that parsed before parses differently: no file in the standard
library, the tests, the examples or the demos moved.

See the [CHANGELOG](https://github.com/mjstahl/wand/blob/main/CHANGELOG.md)
for the full list.

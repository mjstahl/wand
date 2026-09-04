## 0.59.1 - 2026-09-04

`wand f` writes one spelling for a binding. Four bugs where `wand f` wrote a
different program are fixed.

0.59.0 was not released. Its changes are in here.

### A binding has one spelling

A binding joins to its body three ways. All three parse:

```ocaml
let x = e in body       -- names a value for one expression
(let x = e; body)       -- a binding in a block
(let x = e              -- the newline ends the right-hand side
 body)
```

`wand f` printed each back as itself, except the newline. That came back as
a `let ... in` chain inside the block's own brackets, so one block held two
forms:

```ocaml
let deploy! () = (
  let v = version! ()
  FS.write_file! p "%{v}"
  "deployed %{v}"
)
```

0.58.0 wrote that back as:

```ocaml
let deploy! () =
  let v = version! () in (FS.write_file! p "%{v}"; "deployed %{v}")
```

`wand f` now picks by position. A binding in a block takes the `;`. A
binding that names a value for one expression takes `in`:

```ocaml
let deploy! () = (let v = version! (); FS.write_file! p "%{v}"; "deployed %{v}")
```

A body of several statements is a block, with or without the brackets you
wrote. So `let x = e in (a; b)` comes back as `(let x = e; a; b)`.

One `in` is left alone. In `(let x = 1 in x + 1; 9)` the `in` keeps `x` off
the statements below it. That is meaning, not spelling.

A newline also separates two statements in a block, so the `;` between them
is optional on the way in. `wand f` writes it.

### Four programs `wand f` used to write

Each of these took one program and wrote another.

**A binding written with a newline took every definition below it.** Each
one went inside that binding's body. A `main! ()` inside a function nobody
calls prints nothing and exits 0:

```ocaml
import IO
let f () =
  let a = 1
  a + 1
let g () = 2
let main! () = IO.println "%{f ()} %{g ()}"
main! ()
```

0.58.0 ran this and printed nothing. 0.59.1 prints `2 2`.

**A version literal absorbed the field access after it.** A prerelease is dot-separated,
so `(1.0.0-a).f` came back as `1.0.0-a.f`, which is one version literal.

**A single field pun was read as a payload.** `B(n = n)` came back as
`B(n)`, which is `B` applied to `n`. A pun in front of a named field was
read as a record update: `M(a = x, b = "z")` came back as `M(x, b = "z")`.
A construction now puns every field or none.

**A qualified constructor lost the bracket that holds its payload.** The
bracket puts the payload inside the module, so `foo.Boxed(Red)` reads `Red`
in `foo` and `foo.Boxed Red` does not. `n d.M(N) (s [])` came back as
`n d.M N (s [])`.

### Also

A `;` after a `match` or `handle` arm now follows a `)`. The `;` used to sit
against the arm, where it reads as part of it.

`check_fmt` covers `demos/` and `tools/`. They were outside the gate, which
is why the field pun bug sat in a demo unseen.

### What this breaks

`wand f` rewrites files that use the older spellings. Run it once and commit
what it writes. Nothing about the language, the standard library or a
script's behaviour changed, except that the four programs above are now the
ones you wrote.

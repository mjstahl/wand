## 0.74.0 - 2026-09-15

Eight fixes from the daily fuzzer and from reading two scripts that used
wand in anger. `wand f` writes fewer brackets, the lint that finds a binder
doing nothing can now see all of them, and a binding in a function body may
end with `;`.

### A binding in a function body can end with `;`

A `;` after a binding ends its right-hand side and hands the rest to its
body, which is what a newline already did. The brackets are no longer
needed for this:

```ocaml
let of_hex algorithm text =
  let want = _hex_length algorithm;
  let lower = String.lower text;
  String.length lower == want
```

Indentation decides, as it does for a newline: at or past the binding's
column the rest is the body, and back inside it the `;` ends the statement.
Two statements that bind nothing still want the brackets -- a newline does
not join those either.

`wand f` still writes `in` here.

### `wand f` writes fewer brackets

A call that runs onto more lines used to be wrapped in brackets. A line
indented past the statement above it continues that statement, so the call
is still one call and needs nothing to say so:

```ocaml
-- before
let seconds =
  (List.fold_left
    (fn total (_, duration, _) -> total + Result.default 0 (String.to_int duration))
    0
    calls)

-- after
let seconds =
  List.fold_left
    (fn total (_, duration, _) -> total + Result.default 0 (String.to_int duration))
    0
    calls
```

A closing bracket took a line of its own more often than it earned one. It
now does so where the last line is a `match` or `handle` arm, and where more
arguments follow the bracket:

```ocaml
-- before
(Shell.stream $*(printf "a\nb\n")
  |> Stream.filter (fn l -> l == "b")
  |> Stream.to_list
))

-- after
(Shell.stream $*(printf "a\nb\n")
  |> Stream.filter (fn l -> l == "b")
  |> Stream.to_list))
```

An arm keeps the line, because a bracket sitting on one reads as part of it.
So does a bracket with arguments after it, because the break is what puts
them at the start of a line.

### `A-BIND1` sees every `let _ =`

The rule only reported a value on the binder's own line, and pointed at the
wrong line when it did fire:

```ocaml
let _ =
  IO.println "a"
```

That said nothing. It is reported now, at the binder.

A top-level `let _ =` also took the rest of the file as its body, so every
statement below it became part of one binding and `wand f` wrote them back
as a single bracketed block. Those are separate statements again. A named
binding was never affected.

### A type alias builds and matches with bare field names

An alias names its target's constructor, so it builds what the target
builds -- the punned form included, where a bare name is the field of that
name:

```ocaml
type Pod(name: String, tries: Int)
type Target = Pod
let mk name tries = Target(name, tries)
```

This reported `expected String, got ('a, 'b)`. The named form always
worked, and it is what `wand f` shortens to the punned one, so a file that
typechecked could come back rejected after a format.

### An import statement ends with the module name

Anything else on the line is a parse error, and the message names the way
to the module:

```
import Config(x)
-- error: put this on a line of its own; it binds 'Config',
--        so 'Config.member' reaches into it
```

What followed the name used to become a second statement on the same line,
so `import A(import B)` parsed as two imports where one was written.

### Also

`wand f` wrote a contract body that did not parse, when the body opened
with an operator: the brackets that told it apart from the clause above it
were dropped, and `requires n > 0` over `(-n)` re-read as
`requires n > 0 - n`.

See the [CHANGELOG](https://github.com/mjstahl/wand/blob/main/CHANGELOG.md)
for the full list.

## 0.59.4 - 2026-09-05

One formatter bug that changed what a program said, and two changes to how
text is written down.

### `wand f` no longer gives one arm's cases away to another

A `match` or `handle` arm ends only where the next `|` begins. So a bare
`match` printed at the end of an arm takes the arms below it, and the
formatter writes a bracket to keep them apart. It found the end of an arm
by following `let` tails alone. A `with` body prints just as unguarded:

```ocaml
let render x =
  match x with
  | 0 ->
    (with Resource.make (fn () -> 1) (fn _ -> ()) as n ->
      match n with
      | 1 -> "one"
      | _ -> "many")
  | _ -> "rest"
```

0.59.3 dropped the brackets, and `| _ -> "rest"` became a case of the inner
`match`:

```ocaml
  | 0 -> with Resource.make (fn () -> 1) (fn _ -> ()) as n ->
  match n with
  | 1 -> "one"
  | _ -> "many"
  | _ -> "rest"
```

The outer `match` is left with one case, so the file stops typechecking:
`non-exhaustive match: missing case, e.g. _`. That is the loud ending. The
same shape under a `handle` loses an operation instead, and a `fn` or an
`if` tail loses whatever followed it.

0.59.4 keeps the bracket. `fn` bodies and `if` branches print their tails
the same way and had the same hole; an `if` with no `else` prints its *then*
branch last, which is a fourth. All four are fixed.

**Read the diff if `wand f` has run over a file with a nested `match`.** The
output was a fixed point in three of the four shapes: the formatter printed
a different program and then settled on it, so nothing said anything was
wrong. Found by the daily fuzzer, which saw it only because one reparse also
respelled an operation as a pattern.

### A multi-line backtick string starts on the line of its `=`

The opening backtick leaves that line as unfinished as a bare `[` does, so
it now counts as a bracket:

```ocaml
let payload =            let payload = `
  `                      {"name": "web-01", "restarts": 4}
{"name": "web-01"...}    `
`
```

The lines under it are the string's own content. The break that used to land
there moved that text one line down the page and said nothing in its place.
The text inside a backtick string was never altered by `wand f`, and is not
now — only where the literal starts on the page.

### The stdlib's doc examples write JSON and TOML between backticks

`wand d` shows a function's examples to someone asking what it does, which
is the worst place to spend a reader's attention on escapes:

```
>> let doc = JSON.parse! "{\"a\": 1, \"b\": 2}"     -- 0.59.3
>> let doc = JSON.parse! `{"a": 1, "b": 2}`        -- 0.59.4
```

Twenty-one lines across `Decode`, `JSON` and `TOML`. The expected-output
lines under them are unchanged: those are what wand prints, and it prints a
`String` with escapes.

### What this breaks

Nothing in the language or the standard library. `wand f` writes a different
file than 0.59.3 did for the two shapes above — run it once and commit what
it writes. The first of those is a correctness fix, so a file it rewrites
was a file whose meaning the formatter had changed.

## 0.59.2 - 2026-09-04

Three fixes, all found by reading what 0.59.1 wrote.

### A function that returns Bool and can raise now has a name

A name carries one ending. `has_example?!` does not parse. So this function
had no name that answered both rules:

```ocaml
let has_example! p = String.contains? ">>" (FS.read_file! p)
```

0.59.1 asked for a `?`:

```
V-PRED3: 'has_example!' returns Bool but is not named as a predicate
```

Rename it to `has_example?` and V-BANG1 asks for the `!` back. The `!` wins.
V-BANG1 said so already, in its own words: *"`?` is not the ending it takes;
it is 'has_example!'"*. V-PRED3 is quiet now when a function can raise, and
still fires on one that cannot.

### One block, one binding spelling

The spelling follows where the binding stands. 0.59.1 asked only whether the
body was a block, so a binding written `in` with statements above it kept
the `in` and stood beside their `;`:

```ocaml
let main! () = (
  let missing = collect ();
  if List.empty? missing then () else report missing;
  let results = modules |> List.map check in finish results
)
```

0.59.2 writes the `;`:

```ocaml
  let results = modules |> List.map check;
  finish results
```

Brackets of its own do not change where a binding stands. `wand f` drops
them, so `(t; (let f = e in ()))` comes back as `(t; let f = e; ())`.

The first statement of a `( ... )` is the exception. `(let f = ... in f ())`
is a parenthesis around one expression, and it keeps its `in`. So does the
`in` that narrows: in `(let x = 1 in x + 1; 9)` the `in` holds `x` off the
statements below it.

### A `with` body opens its bracket on the `->` line

0.59.1 broke after the `->` and gave the bracket a line of its own:

```ocaml
let main! () =
  with FS.temp_dir "wand_fmt_check_" as dir ->
  (copy_into! dir; format_in! dir; report_on! dir)
```

0.59.2 writes what a binding's value has written since 0.45.0:

```ocaml
let main! () =
  with FS.temp_dir "wand_fmt_check_" as dir -> (
    copy_into! dir;
    format_in! dir;
    report_on! dir
  )
```

A bracket on a line of its own says nothing. The items sit at the same
column either way. Eleven files in the tree each get a line back.

### What this breaks

`wand f` rewrites files that hold the older spellings. Run it once and
commit what it writes. The language, the standard library and every script's
behaviour are unchanged.

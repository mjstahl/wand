## 0.43.0 - 2026-08-23

Every function in the standard library carries an example, and CI runs them.

    -- Keep only elements satisfying a predicate.
    --
    -- >> List.filter (fn x -> x >= 2) [1, 2, 3]
    -- [2, 3] : List Int

308 of them, across 26 modules. `wand d -x <name>` prints a doc with its
examples run where they stand; `wand d -t` reports only what does not hold
and says nothing when everything does. `tools/check_docs.wand` is `-t` over
the whole library, and a wrong example now fails a build.

An example is read by someone deciding how to call a function, and a wrong
one is read with exactly the trust a right one is. Writing these found four
docs that were already wrong:

- `List.range` documented as excluding its upper bound, which it has never
  done
- `Map.empty` and `JSON.of_map` recommending the `[]` map literal, which
  stopped being map syntax in 0.18.0
- `Float.round -2.5`, `floor -2.1` and `ceil -2.9` — three examples written
  in prose that do not parse, because a negative literal after a function
  name is the subtraction it looks like

### A value shows as a value

A string is shown with the quotes it was written with, at any depth:

    ["a, b"]          was [a, b], which is also how ["a", "b"] printed
    zip ["x, y"] [1]  was [(x, y, 1)] — a pair printed as a triple

A TOML value shows as a value rather than as a document. A table used to
print as a whole TOML file, newlines and all, so a list of two tables ran
over four lines. It shows like a map now, and an array shows its elements
instead of `<toml-array>`.

Neither changes what a program writes. `IO.println` and `%{...}` write a
string as its characters and a TOML table as its document, as before, and a
script that ends in a string still writes that string. What changed is what
the REPL echoes and what an error message names.

### Also

`Shell.failed?`, which is `Shell.ok?` asked the other way. The library
already pairs `Option.some?`/`none?` and `Path.absolute?`/`relative?`, and
`List.filter Shell.failed?` needs no brackets where `!(Shell.ok? r)` does.

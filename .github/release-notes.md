## 0.59.3 - 2026-09-04

One change, to the two messages a multi-equation definition can produce.
Both now say where, and one of them quotes what you wrote.

### An unreachable equation is quoted, not counted

wand tries equations in the order you wrote them, so an equation an earlier
one already answers for can never fire:

```ocaml
let classify _ = "other"
let classify 0 = "zero"
```

0.59.2 counted equations, and stopped there:

```
equation 2 for 'classify' is unreachable
```

0.59.3 quotes the equation and says where it is:

```
2:14: equation 'classify 0' is unreachable
```

The equation is already on the screen. Quoting it is what saves the reader
counting lines back to the one the message means.

### A local definition reports its own name

The name in the message used to be the name of the top-level definition,
whatever the equation was written under. So a function inside another one
reported its host, and pointed at the host's line:

```ocaml
let outer x =
  let step _ = 0
  let step 1 = 1
  step x
```

```
2:3: equation 2 for 'outer' is unreachable        -- 0.59.2
3:12: equation 'step 1' is unreachable            -- 0.59.3
```

`'outer 1'` is a quote of something nobody wrote, which is why the name had
to follow the equation once the message began quoting it.

### Equations that leave a gap say where the group starts

```ocaml
let name 0 = "zero"
let name 1 = "one"
```

```
the equations for 'name' do not cover every case, e.g. _        -- 0.59.2
1:10: the equations for 'name' do not cover every case, e.g. _  -- 0.59.3
```

No single equation leaves the gap, so the position is the first of the
group, where the definition starts. A `match` you wrote yourself is
unchanged: it already reported its own `match`.

Both messages had no position for the same reason. wand folds a group of
equations into one `match` over the parameters, and an equation stops being
a syntactic unit there. It now carries the location of its first pattern
through the fold.

### What this breaks

Nothing in the language, the standard library, or what a script does. A tool
that matches the old text of either message needs its pattern updated. Under
`wand t --json` both diagnostics keep their `E-TYPE` code and now carry the
equation's own `line`/`col`, plus the `end_line`/`end_col` that a located
diagnostic carries — where they used to fall back to `1`/`1` with no end.

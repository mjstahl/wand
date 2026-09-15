## 0.77.0 - 2026-09-15

A keyword names a field, a decoder is reached through its module, and an
import stops costing more the larger the module.

### `type` is a field name

A field name is not a name any scope can see. It sits after a `.`, or before
the `:` or `=` inside a constructor's brackets, and nothing else can stand
there. So a word the language has taken now reads as itself:

```ocaml
type Condition (type : String, status : String, when : String = "now")

let c = Condition (type = "Ready", status = "True")

c.type                              -- "Ready"
Condition (c, type = "Available")   -- an update names one too

match c with
| Condition (type = k) -> k
```

This is what lets a type match the document it was written for. `type` is
the field in every Kubernetes condition, every JSON Schema node and a long
list of web APIs. A derived `T.decoder` reads those documents, and `JSON.of`
writes the word back out unchanged.

The short form is the one field position this does not reach, since the bare
name binds as well as names. It says so:

```ocaml
Condition (type, status = "True")
-- parse error: 'type' is a keyword, so this field cannot take the short
--   form: write 'type = type_'
```

### An import no longer costs the module's size squared

A file that imported a large module spent its run deciding which
constructors were in scope rather than checking itself. The cost grew with
the square of the module, so it was invisible at ten types and ruinous at
seven hundred:

```
100 types   205.8 ms ->   46.0 ms
200 types  1319.2 ms ->  141.7 ms
700 types     52.7 s  ->   1.45 s
```

The module alone typechecks in 1.23s, so importing seven hundred types now
costs 0.22s on top rather than fifty-one seconds. Startup is unchanged.

### A derived decoder is reached through its module

```ocaml
let Apps = import ./k8s/apps/v1
let Core = import ./k8s/core/v1

JSON.decode Apps.Deployment.decoder doc   -- reads Apps's type
JSON.decode Core.Deployment.decoder doc   -- reads Core's
```

`Apps.Deployment.decoder` used to read as a construction of `Deployment` and
report that the type was missing its fields. `encoder`, `usage` and `parser`
are reached the same way.

Underneath that sat a wrong answer rather than an error. A field holding
another of the module's own types decoded into whichever module was loaded
last, so two modules that each declare a `Meta` gave values that printed
alike and were not equal -- and the module loaded *first* was the one that
broke.

### An error inside a `%{...}` points at where it was written

The body of an interpolation is read on its own, and its positions started
again at 1:1. A mistake in a string near the bottom of a file was reported
at line 1, at a column that line may not have had.

```
10 |  IO.println "%{Point}"

was:  Error: type error: 1:1:   constructor 'Point' has named fields
now:  Error: type error: 10:15: constructor 'Point' has named fields
```

Every form that holds one is fixed: `"..."`, a backtick string, `$()`,
`$?()` and `$*()`.

### `Decode.and_map`

A record of any width reads as a pipeline, where `map2` and `map3` stopped
at three:

```ocaml
let pod =
  Decode.succeed (fn n r -> Pod (name = n, restarts = r))
  |> Decode.and_map (Decode.field "name" Decode.string)
  |> Decode.and_map (Decode.field "restarts" Decode.int)
```

A type whose field names are the document's needs none of this -- its own
decoder is derived and reads any width. Reach for `and_map` when the names
differ, or when the document spells a field something wand cannot, like
`$ref`.

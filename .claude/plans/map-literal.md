# Map Literal Plan

Introduce `[x = 1, y = 2]` as a first-class lexical Map type.

## Design

```
[x = 1, y = 2]          -- ident keys desugar to string names
[x = 1, y = "hello"]    -- heterogeneous values not allowed (Map String T)
[]                       -- ambiguous with empty list; [] stays List, use Map.empty
```

Disambiguation from List: after `[`, if the first token is `ident =`, it is a
Map literal; otherwise it is a List. An empty `[]` remains a List — use
`Map.empty` for an empty map.

Ident keys desugar to their string name: `[x = 1]` is equivalent to
`["x" = 1]`. String keys are also accepted for cases where the key is not a
valid identifier (e.g. HTTP headers: `["content-type" = "json"]`).

## Access

Dot notation works on Map literals the same as named-field ADT access:

```
let m = [x = 1, y = 2]
m.x    -- 1
m.y    -- 2
```

The evaluator's existing `Field` path handles this. ADT field access is
type-directed; Map field access is dynamic — key not found raises a runtime
error (consistent with `Map.get!`).

## Type

A Map literal produces a `Map String T` value where `T` is the unified type of
all values. The `Map` module functions (`Map.get`, `Map.set`, `Map.keys`, etc.)
all work on it.

## Changes required

### Lexer
No changes needed. `[`, `ident`, `=` are already valid tokens. The parser
handles disambiguation.

### AST
Add `MapLit of (string * expr) list` to `expr`.

### Parser — `atom_`
After consuming `[`, peek ahead: if `Token.Ident _ :: Token.Eq :: _` then
parse a Map literal; otherwise parse a List as today.

Parse each entry as `ident = expr` (or `string = expr`), comma-separated,
until `]`.

### Parser — `pat_` / `pat_atom_`
Add `PMap of (string * pat) list` pattern for destructuring:

```
let [x = a, y = b] = m
match m with | [x = a, y = b] -> a + b
```

Disambiguation same as expression side.

### Typechecker
- `MapLit fields`: infer type of each value, unify all to a common `T`, return
  `TApp (TName "Map", [TString; T])` once generics exist. Until generics,
  return a monomorphic map type or `TDynMap`.
- `Field (MapLit _, key)` and `Field (e, key)` where `e : Map String T`:
  return `T`. Currently `Field` only handles named-type ADTs — extend to also
  handle Map.
- `PMap`: each value pattern checked against `T`.

### Evaluator
- `MapLit fields`: evaluate each value, build a `VMap of (string * value) list`
  (ordered, association-list backed for now; switch to balanced tree when Map
  module lands).
- `Field (e, key)` on `VMap`: look up key, raise `EvalError` if missing.
- `try_match (PMap bindings) (VMap entries)`: for each `(key, pat)` in
  bindings, find key in entries and match pat against its value. Fail if any
  key is missing.

### Stdlib Map module interaction
`Map.from_list`, `Map.get`, `Map.set`, etc. accept `VMap` values. The Map
literal is construction sugar; the module provides the operations.

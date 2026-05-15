# Generics (TApp) Plan

Parameterised types for wand. This is the largest outstanding language feature
and a prerequisite for Option, Result, Map, and user-defined generic types.

## Typechecker changes

Add `TApp of typ * typ` to `typ`:

- `unify`: handle `TApp` structurally — `TApp (f1, a1)` unifies with
  `TApp (f2, a2)` by unifying `f1`/`f2` and `a1`/`a2`.
- `ctor_schemes`: constructors of parameterised types get universally-quantified
  schemes. e.g. `Some : forall a. a -> Option a`.
- `type_of_te`: handle `TEApp` in `type_expr` so annotations like
  `Option Int`, `List String`, `Map String Int` parse and typecheck.
- `pp_typ`: render `TApp (TName "Option", TInt)` as `Option Int`.

## Parser changes

`parse_type_expr` needs left-associative type application:
`Option String`, `Map String Int`, `Result String Int`.

## Built-in parameterised types

Once TApp lands, wire these into the initial type environment:

```
type Option a = None | Some a
type Result e a = Error e | Ok a   (* Ok/Error already exist as constructors *)
```

## Dependent modules (implement after generics)

- **Option** — `is_some?`, `is_none?`, `map`, `and_then`, `or_else`,
  `default`, `get!`, `to_result`
- **Result** — `is_ok?`, `is_err?`, `map`, `map_error`, `and_then`,
  `or_else`, `default`, `get!`, `to_option`
- **Map** — see `map-literal.md` for literal syntax. Backed by OCaml `Map`.
  `empty`, `from_list`, `to_list`, `get`, `get!`, `set`, `delete`,
  `contains?`, `size`, `is_empty?`, `keys`, `values`, `map`, `filter`,
  `merge`, `iter`
- **List.group_by** — `('a -> 'b) -> List 'a -> List ('b, List 'a)`

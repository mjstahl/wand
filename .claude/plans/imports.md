# Imports Plan

Redesign the import system to be expression-based, consistent with existing
`let` destructuring syntax, and support private symbols.

## New syntax

### Stdlib imports (unchanged)

Bare `import` stays as sugar for stdlib modules:

```
import List
import String
```

Desugars to `let List = import List` etc. No change to existing behaviour.

### User module imports

```
let utils   = import ./utils              -- whole module as namespace
let Helpers = import ./helpers            -- capitalisation is convention, not enforced
```

File extension is optional — `./utils` and `./utils.wand` are equivalent.

### Destructured imports

Since an imported module is just a map of its exported symbols, existing map
destructuring applies directly:

```
let [foo, bar]    = import ./utils        -- bind foo and bar
let [f = foo]     = import ./utils        -- bind foo as f
let [f = foo, bar] = import ./utils       -- mix of both
```

If a symbol named in the destructure does not exist in the module, it is a
type error at import time — not a runtime error.

### Field access

Works identically to maps:

```
let utils = import ./utils
utils.foo
utils.bar
```

## Private symbols

Any name beginning with `_` is private — it is excluded from the exported
namespace map and cannot be accessed from outside the module.

```
-- utils.wand
let _helper x = x * 2          -- private, not exported

let double x = _helper x        -- public, calls private helper fine
```

From outside:
```
let utils = import ./utils
utils.double 5    -- Ok: 10
utils._helper 5   -- type error: _helper not found in module
```

Private symbols are fully usable within the module — they just don't appear
in the exported map.

## Implementation

### Parser changes

- Add `ImportExpr of string` to `expr` — the path/name after `import`
- Bare `import Name` at top level remains a `TLImport` statement (sugar)
- `let x = import ./path` parses as a normal `TLLet` with an `ImportExpr` RHS
- `let [f = foo] = import ./path` parses as a `TLLet` with `PMap` pattern and
  `ImportExpr` RHS

### Typechecker changes

- `ImportExpr` infers to a `Namespace` scheme (already exists) built from the
  module's exported symbols
- Private symbols (leading `_`) are filtered out of the `Namespace` before it
  is returned — they remain in the module's internal env during typechecking
- Destructured import: unify the `PMap` pattern against the `Namespace` type,
  giving a type error if a named symbol is missing

### Evaluator changes

- `ImportExpr` evaluates by loading the module (same mechanism as current
  `TLImport`), then returning a `VMap` of exported name→value pairs
- Private symbols filtered from `VMap` on export
- Field access (`utils.foo`) already works on `VMap` — no change needed

### Circular imports

Already handled by the current load-once mechanism — no change needed.

### README changes

- Update imports section with new `let x = import ./path` syntax
- Document map destructuring for named imports
- Document `_` private convention
- Note capitalisation is convention only, not enforced for user modules

# File Format Parsing Plan

Standard library modules for reading and writing common file formats encountered
in scripting work. All parsers return `Result` on failure rather than raising.

## Priority order

### 1. `JSON` — highest value

JSON is ubiquitous: API responses, npm/package files, config, data exchange.

**Approach:** Use the `yojson` OCaml library (already on hex/opam). Wrap it in a
wand-native value type rather than exposing the OCaml variant directly.

**Value representation:** JSON maps to existing wand types:
- object → `Map String` (heterogeneous problem — see note below)
- array  → `List`
- string → `String`
- number → `Float` (or `Int` when whole)
- bool   → `Bool`
- null   → needs `Option` or a `Null` sentinel

**Note:** Heterogeneous JSON objects (mixed value types) are a problem without
generics or a union type. Initial approach: represent all JSON values as a
`JSON` opaque type with typed accessors:

```
JSON.parse   src           -- String -> Result JSON
JSON.stringify j           -- JSON -> String
JSON.get_str  key j        -- String -> JSON -> Result String
JSON.get_int  key j        -- String -> JSON -> Result Int
JSON.get_bool key j        -- String -> JSON -> Result Bool
JSON.get_arr  key j        -- String -> JSON -> Result (List JSON)
JSON.get_obj  key j        -- String -> JSON -> Result JSON
JSON.keys     j            -- JSON -> List String
```

Usage pattern:
```
let raw = FS.read_file config.json
let j   = JSON.parse raw
let name = j |> JSON.get_str "name"
```

### 2. `Env.load` / `Env.read` — dotenv lives in `Env`

`.env` files are just a way to populate environment variables — they belong in
the `Env` module, not a separate `Dotenv` module.

```
Env.load  path   -- Path -> Unit        parse .env and set all vars into env
Env.read  path   -- Path -> Map String  parse .env and return map without setting
```

`Env.read` is useful when you want to inspect or transform values before applying
them. `Env.load` is the one-liner for the common case.

Implementation: pure OCaml builtin in the `Env` module. No dependencies.

### 3. `CSV` — data files, exports, spreadsheet interop

```
CSV.parse      src           -- String -> List (List String)
CSV.parse_with sep src       -- String -> String -> List (List String)
CSV.stringify  rows          -- List (List String) -> String
CSV.read_file  path          -- Path -> Result (List (List String))
```

Headers are just the first row — caller slices with `List.head` / `List.tail`.

Implementation: pure OCaml builtin, handle quoting and escaped commas.

### 4. `TOML` — config files (Cargo.toml, pyproject.toml, etc.)

Same heterogeneous-value problem as JSON. Use same opaque `TOML` value approach
with typed accessors. Depends on `toml` opam library.

```
TOML.parse      src       -- String -> Result TOML
TOML.get_str    key t     -- String -> TOML -> Result String
TOML.get_int    key t     -- String -> TOML -> Result Int
TOML.get_table  key t     -- String -> TOML -> Result TOML
TOML.get_array  key t     -- String -> TOML -> Result (List TOML)
```

### 5. `YAML` — CI/CD configs, k8s manifests

Defer until after generics — YAML's schema-less nature makes it harder to type
well. Same opaque accessor pattern as JSON/TOML. Depends on `yaml` opam library.

## Implementation notes

- All parsers take `String` (caller uses `FS.read_file`); no magic file-reading
  inside the module. This keeps effects in one place.
- Stringify/serialisation can come in a second pass — parsing is the 80% case
  for scripts.
- JSON is the only one worth doing before generics; Dotenv and CSV work fine
  with existing types.

## Sequencing

1. `Env.load` / `Env.read` — no deps, extends existing module
2. `CSV` — no deps, pure parsing
3. `JSON` — add `yojson` to `wand.opam`, implement opaque accessor API
4. `TOML` — after JSON pattern is established
5. `YAML` — after generics

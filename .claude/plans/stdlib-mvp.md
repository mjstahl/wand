# Stdlib MVP Implementation Plan

## Phase 0: Language prerequisites

These must land before the stdlib modules that depend on them.

### 0.1 `?` and `!` suffix in identifiers

Currently `?` lexes as `Hole` and `!` lexes as `Bang` (prefix unary) or
`BangEq`. The design uses them as identifier suffixes: `is_empty?`, `get!`.

Changes:
- `read_ident`: after consuming `[a-zA-Z0-9_]+`, consume one trailing `?` or
  `!` and include it in the identifier string.
- `keyword_or_ident`: keywords never end in `?`/`!`, so no conflict there.
- The `?` standalone token (currently `Hole`) stays — it is only `Hole` when
  not immediately following an identifier character.
- `!` standalone (Bang) and `!=` (BangEq) stay — same rule: only when not
  following an identifier character. `read_ident` runs before the `'!'` branch
  so the suffix is consumed first.

### 0.2 DateTime timezone support

Currently the DateTime lexer accepts `T`, `:`, digits, `Z`, `+`, `-` after the
date. This already handles `Z` and `+HH:MM` / `-HH:MM` offsets structurally,
but it hasn't been validated or tested.

Changes:
- Confirm the lexer already captures `2024-01-15T14:30:00+05:30` correctly.
- Add lexer tests for: `Z`, `+HH:MM`, `-HH:MM` offsets.
- Expose timezone offset in `DateTime` module operations (format, parse,
  conversion to UTC).
- `DateTime.to_utc  : DateTime -> DateTime`
- `DateTime.offset  : DateTime -> Option Duration` — the UTC offset, if any.

### 0.3 `Option` and `Result` as built-in ADTs

`Option` and `Result` are referenced throughout the stdlib signatures. They
need to be pre-defined in the runtime type environment rather than requiring
`import Option`.

Add to the initial type environment in `runner.ml` / `typechecker.ml`:
```
type Option a = None | Some a       -- requires generic types (Phase 0.4)
type Result e a = Err e | Ok a
```

Until generics land (Phase 0.4), these can be modelled as unparameterised
runtime constructors `None`, `Some`, `Ok`, `Err` with monomorphic types
where needed, and the typechecker defers to dynamic checking.

### 0.4 Parameterised types (generics) — required for Map, Option, Result

The typechecker currently has `TName of string` with no parameters. Full
generic types need `TApp of typ * typ` (or `TName of string * typ list`).

Changes to `typechecker.ml`:
- Add `TApp of typ * typ` to `typ`.
- `unify`: handle `TApp` structurally.
- `ctor_schemes`: constructors of parameterised types get universally-quantified
  schemes. e.g. `Some : forall a. a -> Option a`.
- `type_of_te`: handle `TEApp` in `type_expr`.
- Parser: `parse_type_expr` needs to handle `List Int`, `Option String`,
  `Map String Int`, etc. (left-associative type application).

This is the largest prerequisite. All of Map, Option, Result, JSON, and the
generic List functions depend on it.

---

## Phase 1: Pure modules (no new language features needed after 0.1)

These can be implemented as OCaml primitives registered in the evaluator and
typechecker, exposed as `ModuleName.function_name` via the module namespace
mechanism already in place.

### 1.1 String (expand existing)

The `String.wand` file already exists with a subset. Replace it with OCaml
primitives for the full design surface:

`length`, `is_empty?`, `upper`, `lower`, `trim`, `trim_left`, `trim_right`,
`split`, `join`, `lines`, `contains?`, `starts_with?`, `ends_with?`,
`replace`, `repeat`, `reverse`, `to_int`, `to_float`

`chars` and `from_chars` require a `Char` type (see Phase 3).

### 1.2 Path (new module)

Pure operations on the existing `Path` token type. Implemented in OCaml using
`Filename` and `String` stdlib.

`join` (also `/` operator overload on Path × Path → Path), `parent`,
`basename`, `dirname`, `extension`, `with_extension`, `is_absolute?`,
`is_relative?`, `normalize`, `to_string`, `components`

### 1.3 List (expand existing)

Current `List.wand` is written in wand itself. For functions that need OCaml
(sort, unique, etc.) or that require generics, split into:
- Keep pure recursive functions in `List.wand`.
- Add OCaml primitives for `sort`, `sort_by`, `sort_with`, `unique`,
  `contains?`, `group_by`, `range`, `flatten` once generics exist.

Functions implementable now without generics: `range`, `flatten`,
`concat`, `iter`.

### 1.4 IO (replaces Exe.stdin / Exe.exit)

`print`, `println`, `print_err`, `println_err`, `read_line`, `read_all`,
`eof?`, `flush`

`Exe.stdin ()` becomes `IO.read_all ()`. `Exe.exit` becomes the auto-imported
top-level `exit`.

Top-level aliases `print`, `print_err`, `read_line`, `args`, `exit` are
auto-imported (added to the initial eval env in runner.ml).

### 1.5 Duration (new module)

Pure arithmetic on the existing `Duration` token type.

`zero`, `seconds`, `minutes`, `hours`, `days`, `add`, `sub`, `scale`, `format`

---

## Phase 2: Effectful I/O modules

Require the effect system to be wired into the typechecker (currently effects
are runtime-only). For the MVP, type-check these as returning plain values and
add effect row typing later.

**Delete `Exe`** once Phase 1.4 (IO) and Phase 2.1 (FS) and Phase 2.3 (Env)
are complete. Migration: `Exe.stdin()` → `IO.read_all()`, `Exe.args` →
`Env.args()`, `Exe.exit` → `exit`, `Exe.cwd` → `FS.cwd()`.

### 2.1 FS (expand existing; absorbs Exe.cwd)

Current `FS.wand` / OCaml primitives already cover `read_file` and
`write_file`. Expand to full design surface:

`read_file`, `read_bytes`, `write_file`, `write_bytes`, `append`,
`create_file`, `mkdir`, `mkdir_p`, `delete`, `delete_dir`, `rename`, `copy`,
`exists?`, `is_file?`, `is_dir?`, `list_dir`, `walk`, `mtime`, `size`,
`cwd`, `cd`, `with_temp_file`, `with_temp_dir`

`Exe.cwd` (currently a `String`) becomes `FS.cwd ()` returning `Path`.

### 2.2 Process (new module)

Wraps `Unix.create_process` / `Unix.open_process_*`.

`run`, `run_quiet`, `shell`, `spawn`, `wait`, `pid`

`ProcessResult` needs named-field constructor syntax:
`type ProcessResult (exit Int, stdout String, stderr String)`

### 2.3 Env (new module; absorbs Exe.args)

`get`, `get!`, `set`, `unset`, `all`, `args`, `home`, `user`

`Exe.args` becomes `Env.args ()` (and the auto-imported top-level `args`).

**`$SYNTAX` consistency**: `EnvVar` in the evaluator calls `Sys.getenv_opt` at
evaluation time (not at parse time), so `Env.set "FOO" "bar"` followed by
`$FOO` in the same script will see the updated value. The two are naturally
consistent — no special wiring needed.

**`Env.set` implementation**: use `Unix.putenv`. OCaml's stdlib has no direct
`unsetenv`; `Env.unset` can be implemented by setting the variable to `""` or
by shelling out — document the behaviour clearly.

**Case convention**: the `$VAR` lexer only tokenises `$[A-Z0-9_]+` as
`EnvVar`, so `Env.set "lower" "val"` will update the process environment but
the value won't be reachable via `$lower` (it won't lex as an EnvVar). This is
intentional — env vars are conventionally uppercase. `Env.get "lower"` still
works for lowercase keys.

---

## Phase 3: Modules requiring additional token types

### 3.1 Char type

Add `Char` as a primitive type and `'c'` character literals to the lexer.
Needed for `String.chars`, `String.from_chars`.

### 3.2 Regex module

Add `/pattern/flags` regex literals to the lexer (currently `'/'` starts a
path). Disambiguation: `/` at the start of a token followed by non-path
characters.

`match`, `match_all`, `replace`, `replace_all`, `split`, `matches?`

---

## Phase 4: Modules requiring generics (Phase 0.4)

### 4.1 Option module

Built-in `type Option a = None | Some a`.

`is_some?`, `is_none?`, `map`, `and_then`, `or_else`, `default`, `get!`,
`to_result`

### 4.2 Result module

Built-in `type Result e a = Err e | Ok a` (rename `Error` → `Err` to avoid
clash with existing runtime `Error` string).

`is_ok?`, `is_err?`, `map`, `map_error`, `and_then`, `or_else`, `default`,
`get!`, `to_option`

### 4.3 Map module

See also: [map-literal.md](map-literal.md) — `[x = 1, y = 2]` literal syntax,
dot access, and `PMap` destructuring patterns. Implement the literal before or
alongside this module.

Backed by OCaml `Map` functor or a balanced BST. Keys require `Ord`.

`empty`, `from_list`, `to_list`, `get`, `get!`, `set`, `delete`, `contains?`,
`size`, `is_empty?`, `keys`, `values`, `map`, `filter`, `merge`, `iter`

---

## Phase 5: Domain modules (depend on Map + generics)

### 5.1 Date / Time / DateTime modules

Backed by OCaml `Ptime` or hand-rolled arithmetic.

Date: `today`, `year`, `month`, `day`, `day_of_week`, `add_days`, `diff_days`,
`is_before?`, `is_after?`, `format`, `parse`

Time: `now`, `hour`, `minute`, `second`, `format`, `parse`

DateTime: `now`, `utc_now`, `date`, `time`, `add`, `diff`, `is_before?`,
`is_after?`, `format`, `parse`, `to_utc`, `offset`

### 5.2 URL module

Operations on the existing `Url` token type.

`scheme`, `host`, `port`, `path`, `query` (returns `Map String String`),
`fragment`, `with_path`, `with_query`, `parse`

### 5.3 JSON module

Backed by `yojson` or hand-rolled parser.

`type JSON = JNull | JBool Bool | JNumber Float | JString String | JArray (List JSON) | JObject (Map String JSON)`

`parse`, `encode`, `encode_pretty`, `read_file`, `write_file`

Accessors: `get_field`, `as_string`, `as_int`, `as_float`, `as_bool`,
`as_array`, `as_object`

### 5.4 CSV module

`type CSVOptions (delimiter Char, has_header Bool)`

`parse`, `parse_with`, `encode`, `read_file`, `write_file`

### 5.5 HTTP module

Backed by `cohttp-lwt` or `httpaf`. Requires async story to be decided first.

`type HTTPResponse (status Int, headers Map String String, body String)`
`type HTTPRequest (method String, url URL, headers Map String String, body Option String, timeout Option Duration)`

`get`, `post`, `put`, `delete`, `request`

---

## Implementation order

```
0.1 ?/! identifiers
0.2 DateTime timezone tests + to_utc/offset
1.4 IO module  ← absorbs Exe.stdin, Exe.exit
1.1 String (expand)
1.2 Path module
2.1 FS (expand)  ← absorbs Exe.cwd
2.2 Process module
2.3 Env module  ← absorbs Exe.args
delete Exe
1.5 Duration module
0.3 Option/Result as built-in constructors (unparameterised)
0.4 Generics (TApp)  ← big ticket
4.1 Option module
4.2 Result module
map-literal.md  ← [x = 1, y = 2] literal + dot access + PMap patterns
4.3 Map module
1.3 List (expand with sort, unique, etc.)
3.1 Char type
5.1 Date/Time/DateTime modules
5.2 URL module
5.3 JSON module
3.2 Regex module
5.4 CSV module
5.5 HTTP module  ← last, needs async decision
```

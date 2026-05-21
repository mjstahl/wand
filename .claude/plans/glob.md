# Glob Plan

Add a `Glob` type and `FS.glob` for concise file selection. Consistent with the
language's philosophy of distinct types for distinct concepts (`Path`, `Url`,
`IPv4` etc.).

## `Glob` type

A `Glob` is a path pattern — syntactically distinct from `Path`. A `Path` points
to one location; a `Glob` describes a set.

```
*.wand              -- Glob
src/**/*.ml         -- Glob
test/*_test.wand    -- Glob
./utils.wand        -- Path (no wildcards — unchanged)
```

Functions are explicit about which they accept:
- `FS.glob : Glob -> List Path` — takes a glob, returns many paths
- `FS.read_file : Path -> String` — takes a single path; passing a glob is a type error
- `import` — takes a `Path`; `import *.wand` is a type error

String fallback for dynamic patterns:

```
let ext = "wand"
FS.glob "*.${ext}"     -- String also accepted, checked at runtime
```

## API

```
FS.glob  pattern       -- Glob -> List Path   glob from cwd
FS.glob! pattern dir   -- Glob -> Path -> List Path   glob from specific dir
```

`FS.glob` always returns a list — empty list if nothing matches, never raises.
Results are sorted lexicographically.

Supported wildcard characters:
- `*`     — any characters within a single path segment
- `**`    — any number of path segments (recursive)
- `?`     — any single character
- `[abc]` — character class

## Implementation

### Lexer changes

- When lexing a path-like token, if it contains `*` or `?` emit `Token.Glob`
  instead of `Token.Path`
- `**` is a valid token within a glob segment

### Typechecker changes

- Add `TGlob` to `typ`
- `Glob` literal → `TGlob`
- `FS.glob  : Glob -> List Path`
- `FS.glob! : Glob -> Path -> List Path`
- `FS.read_file`, `FS.write_file`, `import` etc. continue to require `TPath` —
  passing a `TGlob` is a type error

### Evaluator changes

- Add `VGlob of string` to value
- Add `fs_glob : string -> string -> string list` builtin (pattern, base dir)
- `FS.glob pattern` passes `fs_cwd ()` as base dir
- `FS.glob! pattern dir` passes explicit dir
- Returns `VList` of `VPath` values
- Use the `glob` or `re` opam library, or implement via `FS.walk` + pattern
  matching since the primitives already exist

### stdlib/FS.wand changes

```
(** Return all paths matching a glob pattern, relative to the current directory. *)
let glob  pattern     = fs_glob pattern (fs_cwd ())

(** Return all paths matching a glob pattern relative to the given directory. *)
let glob! pattern dir = fs_glob pattern dir
```

### README changes

- Add `Glob` to the lexical domain types table
- Add `glob`, `glob!` to the `FS` stdlib listing
- Add example showing glob vs path distinction

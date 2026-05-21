# String Parsing Plan

Add numeric parsing functions to the `String` module. Essential for converting
process output and file contents to typed values.

## API

```
String.to_int    s   -- String -> Result Int     parse decimal integer
String.to_float  s   -- String -> Result Float   parse float
String.to_bool   s   -- String -> Result Bool    "true"/"false" (case-insensitive)
```

All return `Result` — no raising variants since bad input is a normal condition
when parsing process output.

Usage:

```
let n = $(wc -l file.txt) |> String.trim |> String.to_int
match n with
| Ok count  -> "found ${count} lines"
| Error msg -> "parse failed: ${msg}"
```

## Implementation

Pure OCaml builtins wrapping `int_of_string_opt` and `float_of_string_opt`.

### Evaluator changes

- `string_to_int   : string -> value`  — returns `VOk (VInt n)` or `VError (VString msg)`
- `string_to_float : string -> value`  — returns `VOk (VFloat f)` or `VError (VString msg)`
- `string_to_bool  : string -> value`  — returns `VOk (VBool b)` or `VError (VString msg)`

### Typechecker changes

- `String.to_int`   : `String -> Result Int`
- `String.to_float` : `String -> Result Float`
- `String.to_bool`  : `String -> Result Bool`

### stdlib/String.wand changes

```
(** Parse a string as an integer, returning Ok or Error. *)
let to_int   s = string_to_int s

(** Parse a string as a float, returning Ok or Error. *)
let to_float s = string_to_float s

(** Parse "true" or "false" (case-insensitive), returning Ok or Error. *)
let to_bool  s = string_to_bool s
```

### README changes

- Add `to_int`, `to_float`, `to_bool` to the `String` stdlib listing

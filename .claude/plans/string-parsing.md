# String Parsing Plan

Add parsing functions to the `String` module for converting strings to typed
values. Essential for processing process output, file contents, and command-line
options.

## API

### Primitive types

```
String.to_int    s   -- String -> Result Int     parse decimal integer
String.to_float  s   -- String -> Result Float   parse float
String.to_bool   s   -- String -> Result Bool    "true"/"false" (case-insensitive)
```

### Lexical domain types

```
String.to_path     s   -- String -> Path          any string is a valid path
String.to_url      s   -- String -> Result Url
String.to_ipv4     s   -- String -> Result IPv4
String.to_cidr     s   -- String -> Result CIDR
String.to_port     s   -- String -> Result Port
String.to_version  s   -- String -> Result Version
String.to_size     s   -- String -> Result Size
String.to_date     s   -- String -> Result Date
String.to_time     s   -- String -> Result Time
String.to_datetime s   -- String -> Result DateTime
String.to_duration s   -- String -> Result Duration
```

`Path` does not return `Result` — any string is a valid path. All others return
`Result` since they can fail on malformed input.

All return `Result` where applicable — no raising variants since bad input is a
normal condition when parsing process output or config files.

## Usage

```
-- Parse a version from process output
$(cat .version) |> String.trim |> String.to_version

-- Parse a port from an environment variable
Env.get "PORT" |> String.to_port

-- Parse a file size
$(du -sh .) |> String.split "\t" |> List.head |> String.to_size
```

## Implementation

Reuse the existing lexer where possible — the lexer already knows how to
recognise these types from source. Expose the same logic as runtime builtins.

### Evaluator changes

- `string_to_int      : string -> value`
- `string_to_float    : string -> value`
- `string_to_bool     : string -> value`
- `string_to_path     : string -> value`  — always succeeds, returns `VPath`
- `string_to_url      : string -> value`
- `string_to_ipv4     : string -> value`
- `string_to_cidr     : string -> value`
- `string_to_port     : string -> value`
- `string_to_version  : string -> value`
- `string_to_size     : string -> value`
- `string_to_date     : string -> value`
- `string_to_time     : string -> value`
- `string_to_datetime : string -> value`
- `string_to_duration : string -> value`

All fallible variants return `VOk v` or `VError (VString msg)`.

### Typechecker changes

Add corresponding types to stdlib type env for each function.

### stdlib/String.wand changes

Add doc-commented `let to_*` wrappers for each builtin.

### README changes

- Add all new `to_*` functions to the `String` stdlib listing

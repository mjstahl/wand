# wand

A typed ML-style scripting language for Human-AI collaboration.

> "What makes wand easy for me to write is that the types tell the truth. When I generate code I'm reasoning about structure, not running it — so a type error caught by `wand t` is immediate, honest feedback rather than a runtime surprise three steps later. The typed holes let me sketch a solution and ask the type system to fill in what I'm uncertain about instead of guessing. And because errors are `Result` values rather than exceptions, the control flow is explicit in the code itself — I can read what I wrote and know exactly where things can fail without simulating execution. The syntax helps too: it's dense without being cryptic, and the lack of noise means what I generate is close to what I meant."
> — Claude

---

## Quick start

```
wand script.wand        # run a script
wand i                  # interactive session
wand e "1 + 2"          # evaluate an expression
wand t "1 + 2"          # typecheck without evaluating
wand d "List.map"       # show doc string
wand env                # list all names in scope
wand h                  # help
```

---

## Primitives

```
42          -- Int
3.14        -- Float
"hello"     -- String
true        -- Bool
()          -- Unit
```

String interpolation:

```
let name = "world"
"hello, ${name}!"        -- "hello, world!"
"1 + 1 = ${1 + 1}"      -- "1 + 1 = 2"
```

String concatenation with `++`:

```
"foo" ++ "bar"           -- "foobar"
```

---

## Lexical domain types

wand has first-class literal syntax for common scripting values. These are
distinct types — not strings — so the type system catches mistakes like passing
a `Date` where a `Duration` is expected.

| Type | Example literals |
|---|---|
| `Path` | `/etc/hosts` `/home/user/file.txt` `./relative` |
| `Glob` | `*.wand` `./**/*.ml` `**.wand` |
| `Date` | `2024-01-15` |
| `Time` | `14:30:00` |
| `DateTime` | `2024-01-15T14:30:00Z` `2024-01-15T09:00:00+05:30` |
| `Duration` | `5min` `1h30m` `2d` `500ms` `1w` |
| `Url` | `https://example.com` `http://localhost:8080/api` |
| `IPv4` | `192.168.1.1` `10.0.0.1` |
| `CIDR` | `192.168.0.0/24` `10.0.0.0/8` |
| `Port` | `:80` `:8080` `:443` |
| `Version` | `1.2.3` `0.1.0` `1.2.3-alpha.1` |
| `Size` | `10MB` `512KB` `1.5GB` `100B` |

```
let deadline = 2024-12-31
let server   = https://api.example.com
let log_dir  = /var/log/app
let timeout  = 30s
let limit    = 100MB
```

---

## Let bindings

```
let x = 42
let greeting = "hello"
```

With a type annotation:

```
let x : Int = 42
let name : String = "wand"
```

---

## Functions

```
let double x = x * 2
let add x y  = x + y
```

Anonymous functions with `fn`:

```
fn x -> x + 1
fn x -> fn y -> x + y
```

Recursive functions reference themselves by name:

```
let fact n = if n <= 0 then 1 else n * fact (n - 1)
```

With a return type annotation:

```
let double x : Int = x * 2
```

Multi-equation functions — pattern match directly in the definition:

```
let fib 0 = 0
let fib 1 = 1
let fib n = fib (n - 1) + fib (n - 2)
```

Works locally too, with `in` — repeating `let` on each clause or not:

```
let answer =
  let fib 0 = 0
  let fib 1 = 1
  let fib n = fib (n - 1) + fib (n - 2)
  in fib 10
```

Mutually-recursive functions — chain definitions with `and`:

```
let is_even n = if n == 0 then true else is_odd (n - 1)
and is_odd n = if n == 0 then false else is_even (n - 1)
```

Works the same way locally, with `in`:

```
let answer =
  let is_even n = if n == 0 then true else is_odd (n - 1)
  and is_odd n = if n == 0 then false else is_even (n - 1)
  in is_even 7
```

`and`-bound members must be functions (at least one parameter) — a plain
value can't reference a sibling that isn't defined yet, since evaluation
happens eagerly; only a function's body is deferred until it's called.

---

## If expressions

```
if x > 0 then "positive" else "non-positive"
```

---

## Pipeline

`|>` threads a value through a sequence of functions left to right:

```
[1, 2, 3, 4, 5]
  |> List.filter (fn x -> x > 2)
  |> List.map (fn x -> x * 2)
```

---

## Pattern matching

```
match x with
| 0 -> "zero"
| 1 -> "one"
| n -> "other: ${n}"
```

With guards:

```
match n with
| x when x < 0  -> "negative"
| x when x == 0 -> "zero"
| _             -> "positive"
```

### Exhaustiveness checking

`wand t` checks that every `match` covers all possible cases, and rejects
the program at type-checking time if it doesn't — a missing case is a
type error, not a runtime surprise:

```
let f x = match x with | 0 -> "zero"
-- wand t: type error: non-exhaustive match: missing case, e.g. _
```

Because guards (`when`) aren't guaranteed to fire, a guarded arm never
counts toward exhaustiveness on its own — it always needs a plain
fallback arm alongside it. Infinite domains (`Int`, `Float`, `String`, and
the other lexical domain types) can only be covered by an explicit
wildcard or variable pattern; `Bool`, tuples, lists, `Result`, and
user-defined variant types (including generics like `Option`) are checked
structurally against their actual set of constructors. Map patterns are
intentionally partial by design and are never flagged.

---

## Tuples

```
let pair   = (1, 2)
let triple = (true, "hello", 42)

let (a, b) = pair      -- destructure
```

---

## Lists

```
let xs    = [1, 2, 3]
let empty = []

1 : [2, 3]             -- cons: [1, 2, 3]
1 : 2 : 3 : []         -- [1, 2, 3]
```

List patterns:

```
match xs with
| []        -> "empty"
| [x]       -> "one element: ${x}"
| [x, y]    -> "exactly two"
| [h : t]   -> "head ${h}, tail ${t}"
```

Cons patterns chain, matching several leading elements at once:

```
match xs with
| [a : b : c : t] -> "first three: ${a}, ${b}, ${c}, rest: ${t}"
| _               -> "fewer than three elements"
```

Multi-equation over lists:

```
let sum []      = 0
let sum [h : t] = h + sum t
```

---

## Maps

String-keyed, homogeneous maps. The type is `Map T` where `T` is the value type.

```
let m = [x = 1, y = 2, z = 3]   -- Map Int
```

Using the `Map` module:

```
Map.get  "x" m     -- Some(1)
Map.get! "x" m     -- 1  (raises on missing)
Map.has? "x" m     -- true
Map.set  "w" 4 m   -- [w = 4, x = 1, y = 2, z = 3]
Map.delete "x" m   -- [y = 2, z = 3]
Map.keys   m       -- ["x", "y", "z"]
Map.values m       -- [1, 2, 3]
Map.size   m       -- 3
Map.to_list m      -- [("x", 1), ("y", 2), ("z", 3)]
Map.from_list [("a", 1), ("b", 2)]   -- [a = 1, b = 2]
Map.map    (fn x -> x * 2) m         -- [x = 2, y = 4, z = 6]
Map.filter (fn x -> x > 1) m        -- [y = 2, z = 3]
Map.merge m1 m2                      -- keys in m2 take precedence
```

Map patterns (partial — only name the keys you need):

```
match m with
| [x = a, y = b] -> a + b    -- binds a to key x, b to key y

let [x = a] = m in a         -- extract just x; other keys ignored
```

An empty map is `Map.empty`.

---

## Shell execution

Run a shell command and get its stdout as a `String`. Raises on non-zero exit.

```
$(git status)
$(ls -la)
$("git log --oneline -${count}")    -- interpolation works
```

Get full output without raising using `$?()`, which returns a `ShellResult`:

```
let r = $?(git status)
r.stdout   -- String
r.stderr   -- String
r.code     -- Int
```

Pipeline with `|>` threads the left-hand string as stdin to the command:

```
$(git log --oneline)
  |> $(grep "fix")
  |> $(wc -l)
```

Combined with regex:

```
$(git log --oneline)
  |> String.lines
  |> List.filter (Regex.match? r/fix|bug/i)
```

---

## Glob

`Glob` is a distinct type from `Path` — a pattern describing a set of files.
Glob literals use `*`, `**`, or `?` wildcards:

```
*.wand              -- Glob
./**/*.ml           -- Glob (relative paths need ./ prefix)
**.wand             -- Glob (recursive, any depth)
/var/log/*.log      -- Glob

./utils.wand        -- Path (no wildcards — unchanged)
```

`FS.glob` accepts a `Glob`, not a `Path` — mixing them is a type error:

```
import FS

FS.glob    *.wand            -- List Path, relative to cwd
FS.glob_in ./**/*.ml ./src   -- List Path, relative to ./src
```

Both always return a list (empty if nothing matches, never raises).
Results are sorted lexicographically.

---

## Regex

Regex literals use the `r/pattern/` syntax with optional flags `i`, `m`, `s`:

```
r/\d+/          -- one or more digits
r/foo/i         -- case-insensitive
r/^\w+/m        -- match at start of each line
```

```
Regex.match?      r/\d+/ "abc123"          -- true
Regex.capture     r/(\w+)@(\w+)/ "a@b"     -- ["a@b", "a", "b"]
Regex.replace     r/\d+/ "X" "a1b2"        -- "aXb2"
Regex.replace_all r/\d+/ "X" "a1b2"        -- "aXbX"
Regex.split       r/\s+/ "a  b   c"        -- ["a", "b", "c"]
Regex.match_all   r/\d+/ "a1b22c333"       -- ["1", "22", "333"]
```

`match_all` returns every non-overlapping match in order — useful for
simple tokenizing with an alternation pattern:

```
Regex.match_all r/[a-zA-Z_]\w*|[{}=,]|"[^"]*"|\d+/ "block{x=\"1\"}"
-- ["block", "{", "x", "=", "\"1\"", "}"]
```

Compile a pattern at runtime (e.g. from user input):

```
match Regex.compile pattern with
| Ok re  -> Regex.match? re input
| Error e -> false
```

---

## Type definitions

### Enum-style (no payload)

```
type Direction = North | South | East | West

let describe d = match d with
| North -> "up"
| South -> "down"
| East  -> "right"
| West  -> "left"
```

### Variants with payloads

```
type Shape = Circle Int | Rect Int Int

let area s = match s with
| Circle r   -> r * r * 3
| Rect w h   -> w * h
```

Positional fields are space-separated type atoms — `Rect Int Int` is two
`Int` fields, matching how constructor/function application already works
(`f x y`). Parentheses are reserved for grouping a single field's type when
it needs its own structure, not for listing multiple fields:

```
type Wrap = Wrap (List Int)     -- one field, type List Int
type Pair = Pair (Int, Int)     -- one field, tuple type (Int, Int)
```

### Single-constructor shorthand (named fields)

`type Point (x : Int, y : Int)` is shorthand for
`type Point = Point (x : Int, y : Int)`.

```
type Point  (x : Int, y : Int)
type Circle (radius : Int)

let p = Point  (x = 3, y = 4)
let c = Circle (radius = 5)

p.x        -- 3
c.radius   -- 5
```

#### Construction

Fields are named, in any order:

```
Point (x = 1, y = 2)
Point (y = 2, x = 1)    -- same thing
```

#### Pattern matching on named fields

```
let magnitude p =
  match p with
  | Point (x = a, y = b) -> a * a + b * b

let area c =
  let Circle (radius = r) = c in
  r * r
```

---

## Generics

Type definitions can take type parameters, written with a leading quote
(`'a`, `'b`) — matching the syntax `:t` already uses to print inferred
polymorphic types:

```
type Option 'a = None | Some 'a

let describe o = match o with
| Some v -> "got a value"
| None   -> "empty"
```

Multiple parameters are space-separated, matching how positional
constructor fields already work:

```
type Pair 'a 'b = Pair 'a 'b
```

Type variables can also appear in ordinary annotations:

```
let identity : 'a -> 'a = fn x -> x
```

`Option` ships in the standard library — see "Imports" below. `Result`'s
error type is a real type parameter too, not fixed to `String` — the
common case (`Error "message"`) still infers as `Result String T`
automatically, but custom error types work the same way:

```
type ParseError = UnexpectedToken String | UnexpectedEof

let parse s : Result ParseError Int =
  if s == "" then Error UnexpectedEof
  else match String.to_int s with
  | Ok n    -> Ok n
  | Error _ -> Error (UnexpectedToken s)
```

---

## Type inference and unification

wand uses Hindley-Milner type inference — types are inferred without
annotation, and the type checker unifies constraints across the whole
expression.

```
let identity x = x
identity 42        -- inferred: Int -> Int at this call
identity "hello"   -- inferred: String -> String at this call
```

The type checker catches mismatches:

```
let add x y = x + y
add 1 "hello"      -- Error: cannot unify Int with String
```

Types flow through pipelines:

```
let double x = x * 2
[1, 2, 3] |> List.map double
-- List.map inferred as (Int -> Int) -> List Int -> List Int
```

Recursive types are inferred:

```
let length []      = 0
let length [_ : t] = 1 + length t
-- inferred: List 'a -> Int
```

Constructor types are checked at construction and match sites:

```
type Wrap = Wrap Int

Wrap 42        -- ok
Wrap "hello"   -- Error: cannot unify Int with String

match Wrap 42 with
| Wrap n -> n * 2   -- n inferred as Int
```

---

## Type annotations

Any type the checker can infer or print, you can also write explicitly:

```
let x : Int = 42

let xs : List Int = [1, 2, 3]

let pair : (Int, Bool) = (1, true)

let f : Int -> Int = fn x -> x + 1
```

Grouping and nesting compose the same way for annotations as they do for
the printed types:

```
let g : (Int -> Int) -> Int = fn f -> f 1        -- parens needed for left-nesting
let m : Map (List Int) = [a = [1, 2], b = [3]]   -- parens needed for a compound argument
```

`:t` prints types in exactly this syntax, so what you see there is always
what you can paste back into an annotation.

---

## Imports

### Standard library modules

```
import List
import String
import FS
```

Scripts (run via `wand file.wand`) must `import` a stdlib module before
using it — referencing `List.map` without `import List` fails with an
unbound-name error, even though the module ships with wand. The
interactive REPL and the one-shot `e`/`t`/`d`/`env` subcommands are the
exception: they preload `List`, `String`, `Path`, `FS`, `IO`, `Duration`,
`Env`, `Map`, and `Regex` for convenience (but not `JSON`, `TOML`, `CSV`,
or `Process` — those still need an explicit `import` everywhere).

Imported names are available under the module prefix:

```
import List

List.map    (fn x -> x * 2) [1, 2, 3]    -- [2, 4, 6]
List.filter (fn x -> x > 2) [1, 2, 3]    -- [3]
List.length [1, 2, 3]                     -- 3
```

### User modules

Bind a user module to a name:

```
let utils   = import ./utils
let Helpers = import ./lib/helpers    -- capitalisation is convention, not enforced
```

File extension is optional — `./utils` and `./utils.wand` are equivalent.

Access members via dot notation:

```
let utils = import ./utils

utils.my_function 42
utils.greeting
```

### Destructured imports

Import specific names from a module using map destructuring:

```
let [foo = bar]     = import ./utils    -- bind utils.foo as bar
let [f = foo, baz]  = import ./utils    -- rename foo as f, import baz as-is
```

Or bind multiple names directly (shorthand for same key and alias):

```
let [foo, bar] = import ./utils         -- bind foo and bar
```

### Stdlib bound to custom name

```
let L = import List
L.length [1, 2, 3]    -- 3
```

### Private symbols

Names beginning with `_` are private — they cannot be accessed from outside the module:

```
-- utils.wand
let _helper x = x * 2      -- private
let double x = _helper x    -- public, calls private helper
```

```
let utils = import ./utils
utils.double 5       -- 10
utils._helper 5      -- type error: _helper not found in module
```

A user-path import must state the name it binds. `import ./utils` on its own
is an error — use `let utils = import ./utils` or a destructuring pattern, so
the name a module arrives under is written at the import site and greppable.
(`import FS` and other stdlib imports are unaffected: the name is already
written there.)

---

## Current standard library

### `List`

`map`, `filter`, `fold_left`, `fold_right`, `length`, `append`, `reverse`,
`head`, `head!`, `tail`, `tail!`, `is_empty?`, `any`, `all`, `find`, `zip`, `take`, `drop`,
`take_while`, `drop_while`, `each`, `sort`, `sort_by`, `unique`, `range`,
`flatten`, `concat`, `get`, `get!`

### `String`

`length`, `is_empty?`, `upper`, `lower`, `trim`, `trim_left`, `trim_right`,
`slice`, `split`, `contains?`, `starts_with?`, `ends_with?`, `replace`,
`repeat`, `reverse`, `chars`, `join`, `lines`, `words`, `of_int`, `to_int`,
`to_float`, `to_bool`, `to_path`, `to_url`, `to_ipv4`, `to_cidr`, `to_port`,
`to_version`, `to_size`, `to_date`, `to_time`, `to_datetime`, `to_duration`

### `Regex`

`compile`, `match?`, `capture`, `replace`, `replace_all`, `split`, `match_all`

### `Map`

`empty`, `get`, `get!`, `set`, `delete`, `has?`, `keys`, `values`, `size`,
`to_list`, `from_list`, `merge`, `map`, `filter`

### `FS`

`read_file`, `write_file`, `append`, `create_file`, `temp_file`, `mkdir`,
`delete`, `rename`, `copy`, `list_dir`, `mtime`, `size` — each with a `!`
sibling that raises instead of returning a `Result`.
`exists?`, `is_file?`, `is_dir?`, `glob`, `glob_in`, `cwd`

### `Path`

`join`, `parent`, `basename`, `dirname`, `extension`, `with_extension`,
`is_absolute?`, `is_relative?`, `normalize`, `to_string`, `of_string`,
`components`

### `IO`

`print`, `println`, `print_err`, `println_err`, `read_line`, `read_all`, `flush`

### `Env`

`get`, `get!`, `set`, `unset`, `all`, `args`, `home`, `user`, `read`, `load`

### `CSV`

`parse`, `parse_with`, `stringify`, `stringify_with`, `read_file`, `read_file!`

Parses [RFC 4180](https://tools.ietf.org/html/rfc4180) CSV.  Fields may be
quoted with `""`; embedded quotes are doubled (`"say ""hi"""`).  `read_file`
returns `Result String (List (List String))`; `read_file!` raises on error.

```
import CSV

let rows = CSV.parse "name,age\nAlice,30"
-- [["name", "age"], ["Alice", "30"]]

let tsv = CSV.parse_with "\t" "a\tb\tc"

CSV.stringify [["x", "y,z"]]
-- x,"y,z"

match CSV.read_file ./data.csv with
| Ok rows  -> rows
| Error msg -> []
```

### `JSON`

`parse`, `parse!`, `stringify`, `stringify_pretty`, `read_file`, `read_file!`,
`null`, `of_bool`, `of_int`, `of_float`, `of_string`, `of_list`, `of_map`,
`is_null?`, `get_bool`, `get_int`, `get_float`, `get_string`, `get_array`,
`get_object`, `field`, `field!`

`JSON` is an opaque type.  `parse` / `read_file` return `Result String JSON`;
the `!` variants raise on error.  Typed extractors each return `Result`.

```
import JSON

let j = JSON.parse! "{\"name\":\"Alice\",\"age\":30}"

match JSON.field "name" j with
| Ok v  -> JSON.get_string v    -- Ok "Alice"
| Error _ -> Error "missing"

-- Building JSON
let arr = JSON.of_list [JSON.of_int 1, JSON.of_int 2]
JSON.stringify arr    -- "[1,2]"

match JSON.read_file ./config.json with
| Ok cfg -> JSON.field! "host" cfg
| Error msg -> JSON.of_string "localhost"
```

### `TOML`

`parse`, `parse!`, `stringify`, `read_file`, `read_file!`,
`is_table?`, `is_array?`, `get_bool`, `get_int`, `get_float`, `get_string`,
`get_array`, `get_table`, `field`, `field!`

`TOML` is an opaque type representing any TOML value (table, string, int,
float, bool, array).  The top-level parse result is always a table.
Typed extractors each return `Result`; `field` / `field!` navigate keys.

```
import TOML

let cfg = TOML.parse! "[server]\nhost = \"localhost\"\nport = 8080\n"

let server = TOML.field! "server" cfg

match TOML.get_string (TOML.field! "host" server) with
| Ok h  -> h          -- "localhost"
| Error _ -> "?"

match TOML.get_int (TOML.field! "port" server) with
| Ok p  -> p          -- 8080
| Error _ -> 0

match TOML.read_file ./config.toml with
| Ok t    -> TOML.field! "database" t
| Error m -> TOML.parse! ""
```

### `Duration`

`zero`, `seconds`, `minutes`, `hours`, `days`, `weeks`, `add`, `sub`, `scale`,
`format`, `to_ms`

### `Option`

`is_some?`, `is_none?`, `map`, `and_then`, `or_else`, `default`, `get!`,
`to_result`

`Option 'a` is a generic type (`type Option 'a = None | Some 'a`) — see
"Generics" above.

---

## Testing

The `Test` module gives each test a handle (`t`) exposing `ok`, `eq`, and
`raises`:

```
import Test

test "add" (fn t -> t.eq (2 + 2) 4)
test "is_some" (fn t -> t.ok (Option.is_some? (Some 1)))
test "get! out of bounds raises" (fn t -> t.raises (fn () -> List.get! 9 [1, 2, 3]))
```

- `t.eq expected actual` — pass if `expected == actual`.
- `t.ok cond` — pass if `cond` is `true`.
- `t.raises thunk` — pass if calling `thunk ()` raises. `thunk` must be a
  zero-argument function (`fn () -> ...`), not the expression directly —
  wand evaluates arguments eagerly, so `t.raises (List.get! 9 xs)` would
  raise while evaluating the argument itself, before `t.raises` ever runs.

Each `test` call needs explicit parens around its `fn` argument
(`test "x" (fn t -> ...)`) — wand doesn't currently allow a bare `fn` as
a trailing application argument.

Run one or more test files with `wand test`:

```
wand test my_test.wand
wand test test/*.wand
```

Each call to `test` is printed as `ok   <label>` or `FAIL <message>`; a
test whose body raises outside of `t.raises` is reported as a failure
without stopping the rest of the file. `wand test` exits nonzero if any
test failed or any file had a lex/parse/type error.

---

## Comments

Line comments run to the end of the line:

```
-- this is a comment
let x = 1     -- so is this
```

Block comments, nestable:

```
(* this is a comment *)

(*
  multi-line
  (* nested comment *)
*)
```

---

## REPL and CLI

### Running scripts

```
wand script.wand          # run a script
wand script.wand arg1     # pass arguments (available via Env.args)
```

### Interactive session

```
wand i                    # start session
wand i --load utils.wand  # start with a file preloaded
```

Inside the session:

```
>> 1 + 2
3 : Int

>> let double x = x * 2
double : Int -> Int

>> double 21
42 : Int

>> List.map double [1, 2, 3]
[2, 4, 6] : List Int
```

This is a REPL/one-shot-command convenience, not a script one — see
"Standard library modules" under "Imports" above for exactly which
modules are preloaded, and note that scripts (`wand file.wand`) always
need an explicit `import`.

Special commands:

| Command | Short | Description |
|---|---|---|
| `:type <expr>` | `:t` | Show type without evaluating |
| `:doc <name>` | `:d` | Show doc string |
| `:load <path>` | `:l` | Load a `.wand` file into the session |
| `:reload` | `:r` | Reload the last loaded file |
| `:env` | | List all bindings in scope |
| `:reset` | | Clear all session bindings |
| `:quit` | `:q` | Exit |

Multi-line input is detected automatically (unclosed brackets, trailing `->`, `=`, `|`, etc.). A blank continuation line submits the accumulated input.

History is saved to `~/.wand_history` between sessions.

### One-shot commands

```
wand e "1 + 2"                        # evaluate and print result
wand e --load config.wand "host"      # evaluate in context of a file
wand t "List.map"                     # typecheck only
wand d "List.map"                     # show doc string
wand env                              # list all names and modules in scope
wand fmt script.wand                  # format a file in place
wand fmt stdlib/*.wand                # format multiple files in place
wand test my_test.wand                # run one or more test files
wand h                                # show all commands
wand h e                              # help for a specific command
```

Each subcommand has a full-word alias: `i`/`interactive`, `e`/`eval`, `t`/`type`, `d`/`doc`, `fmt`/`format`, `h`/`help`.

### Formatter

`wand fmt <file>...` formats one or more `.wand` files in place (each
file is overwritten with its formatted contents; a confirmation line is
printed per file). Shell globs work as expected: `wand fmt stdlib/*.wand`
reformats every file in `stdlib/`.

Comments (`-- ...`, `(* ... *)`, and doc `(** ... *)`) are always preserved —
never silently dropped, and never rewritten from one style into the other. Multi-equation function definitions
(`let f 0 = ... / let f n = ...`) are reconstructed as separate clauses
rather than left as the desugared `match`.

A handful of rarer constructs don't have a dedicated formatting rule yet
and are re-emitted verbatim, unchanged, wherever they appear:
`requires`/`ensures` contracts, `handle`, `$(...)`/`$?(...)` shell
commands, `try`, and regex literals. This is a deliberate, safe
degradation — such code is left exactly as written rather than risk
misformatting it.

---

## Building

```bash
# Install dependencies (including test deps like alcotest)
opam install . --deps-only --with-test

# Build
dune build

# Run tests
dune test

# Create a local wand symlink for development
ln -sf _build/install/default/bin/wand wand
```

Requires OCaml 5.x and opam. Dependencies managed via `wand.opam`.

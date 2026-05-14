# wand

A typed ML-style scripting language for Human-AI collaboration.

---

## Quick start

```
dune exec bin/wand -- script.wand   # run a script
wand i                              # interactive mode (coming soon)
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

Multi-equation over lists:

```
let sum []      = 0
let sum [h : t] = h + sum t
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
type Shape = Circle Int | Rect (Int, Int)

let area s = match s with
| Circle r   -> r * r * 3
| Rect w h   -> w * h
```

### Single-constructor shorthand (named fields)

`type Point (x Int, y Int)` is shorthand for `type Point = Point (x Int, y Int)`.

```
type Point  (x Int, y Int)
type Circle (radius Int)

let p = Point  (x = 3, y = 4)
let c = Circle (radius = 5)

p.x        -- 3
c.radius   -- 5
```

#### Construction

Named (any order):

```
Point (x = 1, y = 2)
Point (y = 2, x = 1)    -- same thing
```

Positional (declaration order):

```
Point (1, 2)
```

#### Pattern matching on named fields

```
let magnitude p =
  match p with
  | Point (x = a, y = b) -> a * a + b * b
```

#### Shorthand destructuring (single-constructor types only)

```
let (x, y) = p     -- binds x and y positionally from Point fields
let (r)    = c     -- binds r from Circle's single field

let area c =
  let (r) = c in
  r * r
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

## Imports

### Standard library modules

```
import List
import String
import FS
```

Imported names are available under the module prefix:

```
import List

List.map    (fn x -> x * 2) [1, 2, 3]    -- [2, 4, 6]
List.filter (fn x -> x > 2) [1, 2, 3]    -- [3]
List.length [1, 2, 3]                     -- 3
```

### User modules

```
import ./utils
import ./lib/helpers
```

Top-level definitions from the imported file are available under the module
name derived from the filename:

```
import ./utils

utils.my_function 42
```

---

## Current standard library

### `List`

`map`, `filter`, `fold_left`, `fold_right`, `length`, `append`, `reverse`,
`head`, `tail`, `is_empty`, `any`, `all`, `find`, `zip`, `take`, `drop`, `each`

### `String`

`length`, `upper`, `lower`, `trim`, `split`, `join`, `lines`, `contains`,
`starts_with`, `ends_with`, `replace`, `chars`, `slice`, `words`

### `FS`

`read_file`, `write_file`

---

## Comments

Block comments, nestable:

```
(* this is a comment *)

(*
  multi-line
  (* nested comment *)
*)
```

---

## Building

```bash
# Build
dune build

# Run tests
dune test

# Run a script
dune exec bin/wand -- examples/hello.wand
```

Requires OCaml 5.x and opam. Dependencies managed via `wand.opam`.

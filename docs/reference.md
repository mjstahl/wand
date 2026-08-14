# wand language reference

The complete language: syntax, types, the standard library, and the tools.
For what wand is and why, see the [README](../README.md).

---

## Contents

- [Quick start](#quick-start)
- [Primitives](#primitives)
- [Lexical domain types](#lexical-domain-types)
- [Let bindings](#let-bindings)
- [Functions](#functions)
- [If expressions](#if-expressions)
- [Pipeline](#pipeline)
- [Sequencing](#sequencing)
- [Pattern matching](#pattern-matching)
- [Tuples](#tuples)
- [Lists](#lists)
- [Maps](#maps)
- [Shell execution](#shell-execution)
- [Glob](#glob)
- [Regular expressions](#regular-expressions)
- [Errors and `try`](#errors-and-try)
- [Effects](#effects)
- [Manifests](#manifests)
- [Effect handlers](#effect-handlers)
- [Resource brackets](#resource-brackets)
- [Decoders](#decoders)
- [Contracts](#contracts)
- [Typed holes](#typed-holes)
- [Type definitions](#type-definitions)
- [Generics](#generics)
- [Type inference and unification](#type-inference-and-unification)
- [Type annotations](#type-annotations)
- [Imports](#imports)
- [Current standard library](#current-standard-library)
  - [List](#list) · [Resource](#resource) · [Proc](#proc) · [String](#string) · [Regex](#regex) · [Map](#map) · [FS](#fs) · [Path](#path) · [IO](#io) · [Env](#env) · [CSV](#csv) · [JSON](#json) · [TOML](#toml) · [Duration](#duration) · [Par](#par) · [Shell](#shell) · [Decode](#decode) · [Option](#option) · [Test](#testing)
- [Testing](#testing)
- [Comments](#comments)
- [REPL and CLI](#repl-and-cli)
- [Building](#building)

---

## Quick start

```
wand script.wand        # run a script
wand --dry-run deploy.wand   # report what it would change, without doing it
wand --trace deploy.wand     # run it, reporting each effect as it happens
wand i                  # interactive session
wand e "1 + 2"          # evaluate an expression
wand t "1 + 2"          # typecheck without evaluating
wand d "List.map"       # show doc string
wand env                # list all names in scope
wand fmt script.wand    # format a file in place
wand test               # run every test_*.wand from here down
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
| `Port` | `:80` `:8080` `:443` — 0 to 65535; outside that is a lex error naming the rule |
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

Equations are one definition, so they must be written consecutively and take
the same number of parameters. They are tried in the order written; an
equation an earlier one already covers is an error:

```
let f _ = 0
let f 1 = 1     -- error: equation 2 for 'f' is unreachable
```

The equations must also cover every case together, checked the same way a
`match` is.

In the REPL a later `let` for an existing function adds a clause to it
instead, and the result is reported as `f : Int -> Int, 2 equations`.

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

An `if` with nothing to do when the condition is false leaves the branch out:

```
if stashes > 0 then println "Stashes: ${stashes} saved"
```

That is the same expression as `else ()`, not a second kind of conditional —
so the branch has to be `Unit`, since a missing branch can only be `()`:

```
if ready then 1
-- an `if` with no `else` does nothing when the condition is false,
--   so its branch must be Unit -- this one is Int
```

`wand fmt` writes an empty `else` out of existence: `if c then f () else ()`
comes back as `if c then f ()`.

---

## Pipeline

The pipeline operator `|>` has two meanings, chosen by the syntactic shape of
its right operand. This is the one place in wand where an operator's semantics
are decided at parse time rather than by the value it is applied to — it is a
*special form*, and knowing which meaning applies requires looking only at the
right-hand side, never at runtime values.

**Form 1 — application.** When the right operand is any ordinary expression,
`x |> f` is exactly `f x`:

```
[1, 2, 3] |> List.map double |> List.filter (fn x -> x > 2)
$(git log --oneline) |> String.lines |> List.length
```

**Form 2 — stdin threading.** When the right operand is *literally* a `$()` or
`$?()` form, `|>` threads the left value (a `String`) into the command's
standard input:

```
$(git log --oneline) |> $(grep "fix") |> $(wc -l)
report |> $?(mail -s "nightly" ops@example.com)
```

Each stage's stdout becomes the next stage's stdin; `|>` associates left, so a
chain reads as a shell pipeline. A `$?()` stage yields a `ShellResult` and
therefore ends the threading chain (pipe its `.stdout` onward explicitly if
needed).

**The distinction is syntactic, and that is the point.** `$()` is not a
function value — `let g = $(grep foo)` *runs* `grep` immediately and binds its
output `String`; it does not create a pipeable stage. Stdin threading happens
only when `$()`/`$?()` appears directly to the right of `|>`. Which meaning you
are reading is always decidable locally, from the text, without type
information: *right side starts with `$` → process; otherwise → application.*

**Choosing between wand pipes and shell pipes.** Both of these are idiomatic:

```
$(git log --oneline | grep fix | wc -l)          -- one shell pipeline
$(git log --oneline) |> $(grep fix) |> $(wc -l)  -- three wand stages
```

Use a **shell-internal pipe** when transcribing an existing one-liner, when the
pipeline is an indivisible idiom, or when only the final output matters — it is
one opaque operation. Use **wand-level stages** when you want wand in the
middle (filtering with a typed function between commands), per-stage error
handling via `$?()`, or stage-by-stage visibility. Rule of thumb: *the boundary
between shell and wand should sit where you want types, errors, or auditability
to begin.*

---

## Sequencing

Expressions evaluated for their effects are separated with `;`; the value of
the sequence is the last expression:

```
println "starting";
println "working";
42
```

A newline alone ends a statement, so `;` is only needed to put several on one
line or to make the sequencing explicit.

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

Because guards (`when`) aren't guaranteed to fire, a guarded case never
counts toward exhaustiveness on its own — it always needs a plain
fallback case alongside it. Infinite domains (`Int`, `Float`, `String`, and
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

A key is any string. Write it quoted when it is not an identifier — which is
most keys a document from elsewhere contains:

```
["content-type" = "application/json", "@type" = "Pod", name = "web"]
```

Quoted keys work in patterns too: `| ["content-type" = v] -> v`.

A key is held once. Give one twice and the last value wins, in the place the
key first appeared — what an assignment means, and what keeps a document
written back out in the order it came in:

```
[a = 1, b = 2, a = 9]        -- [a = 9, b = 2]
Map.set "b" 99 [a = 1, b = 2, c = 3]   -- [a = 1, b = 99, c = 3]
Map.merge [a = 1, b = 2] [b = 9]       -- [a = 1, b = 9]
```

A JSON document *can* name a key twice, even though a `Map` cannot hold one
twice. Every reader takes the later one — `JSON.field`, `Decode.field`, and
the `Map` that `JSON.get_object` gives back — so two readers of the same
document in one program cannot disagree about it.

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

## Regular expressions

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

## Errors and `try`

Fallible operations return a `Result`, and their `!`-named siblings raise
instead. `try` runs an expression and converts a raise back into a `Result`,
so raising code can be handled as values at whatever boundary you choose:

```
try (FS.read_file! ./config.toml)   -- Result String String
try (1 + 1)                          -- Ok(2)
```

The error payload is the message the raise carried, without a source position:
it describes what went wrong, not where.

`try` is the only construct for capturing a raise. It is a fixed handler over
the same machinery `handle` exposes.

---

## Effects

A signature says what a function does to the machine, not just what it does
to its arguments. The effects appear after `!`:

```
FS.read_file!   Path -> String ! {FS.Read, Raise}
FS.exists?      Path -> Bool ! {FS.Read}
Map.get!        String -> Map 'a -> 'a ! {Raise}
String.upper    String -> String
```

### What you write, and what you only read

| | |
|---|---|
| Effect labels — `{Shell, FS.Write}` | **Never written.** There is no syntax to annotate them; they are always inferred. Writing `let f : Unit -> String ! {Shell} = …` is a parse error. |
| Operation names — `FS!read_file` | **Written only in a handler case**, when intercepting that operation in a test. |
| Everything else | Ordinary wand. Effects follow from the builtins your code reaches. |

So writing a script means writing no effects at all. You read them back from
`wand t`, `wand d`, and the interactive session.

### The labels

Seven, and a script cannot define more:

| Label | Means |
|---|---|
| `Shell` | runs a subprocess — including anything reaching the network, since it does so through a command |
| `FS.Read` | reads from the filesystem |
| `FS.Write` | creates, changes or removes something on disk |
| `Env` | reads or changes environment variables |
| `IO` | reads or writes the program's own streams |
| `Proc` | ends the process; nothing catches this |
| `Raise` | can raise instead of returning |

A label answers "what can this touch?", which is why it is coarse: it has to
fit in a signature and be memorable in full.

### They are inferred, however deep

```
let fetch () = $(curl https://example.com)
let sync ()  = fetch ()

sync            -- Unit -> String ! {Shell, Raise}
```

Nothing above is annotated. `$()` runs a command and raises on a non-zero
exit, so it carries `{Shell, Raise}`; `$?()` hands back a `ShellResult`
instead and carries `{Shell}` alone. `$NAME` reads the environment, so it
carries `{Env}`.

### `try` and `handle` take effects away

`try` converts a raise into a `Result`, so `Raise` does not escape it:

```
fn () -> $(git status)          -- Unit -> String ! {Shell, Raise}
fn () -> try ($(git status))    -- Unit -> Result String String ! {Shell}
```

This is why each fallible operation and its `!` sibling differ by exactly
one effect — the plain one is `try` over the raising one:

```
FS.read_file!   Path -> String ! {FS.Read, Raise}
FS.read_file    Path -> Result String String ! {FS.Read}
```

A handler case removes the effect of the operation it intercepts:

```
fn () -> handle $(git push) with
         | Shell!run _ k -> k "ok"     -- Unit -> String ! {Raise}
```

`Shell` is gone. `Raise` stays: a row records which effects occurred, not
which operation caused them, so the raise `$()` performs on a non-zero exit
cannot be told apart from one a raising call elsewhere in the body would
perform. Removing it would drop that one too.

### Effect variables

A function that passes effects through carries a variable rather than a
fixed set, written `'e` — a variable ranging over effects, as `'a` ranges
over types:

```
List.map   ('a -> 'b ! 'e) -> List 'a -> List 'b ! 'e
```

`List.map` performs whatever the function it is given performs, and no more.
Applying it to a shell command yields `{Shell, Raise}`; applying it to
arithmetic yields nothing.

A row can be partly known: `{Raise | 'e}` means "raises, plus whatever `'e`
turns out to be". The `|` separates what is known from the rest.

### What inference promises

A signature may name an effect a function does not always perform, but it
never omits one it does. Where two calls in one body both have undetermined
effects, they share the scope's unknowns, so an effect proved for one is
attributed to both. Erring in this direction is what makes a signature worth
reading: a missing effect would be a lie, an extra one is only imprecise.

---

## Manifests

A file may declare what it is allowed to do:

```
uses {Shell, FS.Write}
```

This is the one place a script author writes effect labels. It goes first,
before everything but a shebang and comments, so a reader knows the bound
without searching for it — a manifest that could be anywhere would be worth
no more than none at all.

A file without a manifest is unconstrained, so casual scripts pay nothing.

### Doing more than you declared is an error

The manifest is checked against everything the file defines, not only what
running it performs — a function that shells out still shells out when
another file imports and calls it.

```
$ wand t --file deploy.wand
Error: type error: 'publish' performs Shell, which the manifest does not allow.
       The manifest should be:  "uses {Shell, FS.Write}"
```

The error names the binding that introduced the effect and the line to
write, so the fix is a copy rather than a derivation.

### Declaring more than you use is a warning

```
warning: 1:1: A-USES1: the manifest permits Shell, which this file does not
         use; it could be "uses {FS.Write}"
```

Permitting more than you need is the safe direction, and a build that failed
over it would punish caution — so it is advisory, and `--strict` leaves it
alone.

### Performing effects without saying so is a warning

```
warning: 1:1: A-USES2: this file performs Shell, FS.Write and does not say
         so; it could declare "uses {Shell, FS.Write}"
```

A file without a manifest is legal and always will be — a casual script
should not have to pay for a feature it did not ask for, so this never
fails a build. But a manifest is only worth writing if it makes the file
better to read, and the effects have already been inferred, so the linter
hands over the exact line rather than only noting its absence.

### `Raise` is not part of a manifest

A manifest bounds what a file can do to the machine. `Raise` is control
flow: it is already visible in a `!` name and in every signature, and
including it would put `Raise` in almost every manifest while saying nothing
about blast radius.

---

## Effect handlers

`handle` intercepts the effects an expression performs. Its purpose is testing
and interception at boundaries — most usefully, running a script that shells
out or writes files without letting it touch anything:

```
test "deploy pushes once" (fn t ->
  let outcome =
    handle deploy () with
    | Shell!run _ k -> k "mocked output"
  in t.eq outcome "done")
```

A case names the operation it intercepts. The name is the call you would
otherwise make, with a `!` where its dot goes — you call `FS.read_file`, you
intercept `FS!read_file`:

```
| FS!read_file path k   -> k "fake contents"
| Shell!run cmd k       -> k "mocked output"
| Env!get name k        -> k "value"
| IO!println text k     -> k ()
```

The part before the `!` is the effect family, which is why `$()` is
`Shell!run` even though there is no `Shell` module: families are the same
words that appear in a signature's row.

Several functions can share one operation. `FS.read_file` and
`FS.read_file!` both perform `FS!read_file`, so a test mocks reading a file
once rather than once per wrapper.

A case binds the operation's argument and a continuation
(`k`) that resumes the intercepted code with a value you supply. Both are
checked against the operation, so a case cannot read a path as a `String` or
resume a read with an `Int`:

```
| FS!write_file (path, _) k -> path ++ "!" ++ k ()
-- cannot unify Path with String

| FS!read_file _ k -> k 42
-- cannot unify String with Int
```

`Shell!run` and `Shell!capture` are the exception. Each carries either a
command, or a command and the stdin threaded into it, so there is no single
payload type to check a case against and theirs are left open.

A `return` case transforms the result when the body finishes normally:

```
handle
  let () = FS.write_file! /etc/hosts "..." in
  "done"
with
| FS!write_file (path, _) k -> k ()
| return s -> s
```

A case that answers on its own, without resuming, writes `_` for the
continuation:

```
| Shell!run _ _ -> "mocked"
```

The intercepted code stops there, and whatever it was holding is released —
a `with` inside it runs its cleanup on the way out, so a mock cannot leak
the resources of the code it stands in for.

The interceptable operations are the builtins that touch the outside world.
Each is named `Family!verb`, and the family is the same one that appears in
an effect row:

| Family | Operations |
|---|---|
| `Shell` | `run`, `run_quiet`, `capture`, `exit_code` |
| `FS` | `read_file`, `write_file`, `append`, `create_file`, `delete`, `copy`, `rename`, `mkdir`, `list_dir`, `glob`, `exists`, `file`, `dir`, `size`, `mtime`, `cwd`, `temp_file` |
| `Env` | `get`, `set`, `clear`, `all`, `args`, `home`, `user`, `parse_dotenv` |
| `IO` | `print`, `println`, `print_err`, `println_err`, `read_line`, `read_all`, `flush` |
| `Proc` | `exit` |

There is no `perform` keyword — a script cannot define its own effect
operations, only intercept the built-in ones.

Use `handle` to intercept at a boundary — mocking in tests, auditing what a
third-party module attempts, retrying. Error handling belongs to `try` and
`Result`; `handle` is not a control-flow construct.

---

## Resource brackets

Some things have to be given back: a temp file, a lock, a directory you
changed into. `with` acquires one, binds it, runs a body, and releases it:

```
with FS.temp_file "build_" ".tar" as archive ->
  let () = FS.write_file! archive contents in
  publish! archive
```

**A `with` always releases, however the script ends** — returning, raising,
`Proc.exit`, a handler that answers without resuming, Ctrl-C, or a `kill`.
There
is no `defer`, no `trap`, and nothing to remember at each exit.

The one exception is a process that is destroyed rather than stopped:
`kill -9` and a machine losing power take the program away without giving it
the chance to run anything. Nothing can cover that.

`Proc.exit n` still exits with `n` — it releases first, then stops. An interrupt
exits 130 and a `kill` exits 143, as a shell reports them, so nothing
downstream has to learn a wand-specific code.

Brackets nest, and release innermost-first:

```
with FS.temp_file "wand_" ".txt" as scratch ->
with FS.temp_file "wand_" ".log" as log ->
  ...
```

### A resource is a description

`FS.temp_file "wand_" ".txt"` does not create a file. It describes how to
create one and how to remove it, so it can be named, passed to a function,
and used more than once — each `with` acquires again:

```
let scratch = FS.temp_file "wand_" ".txt"

let first  = with scratch as p -> Path.to_string p
let second = with scratch as p -> Path.to_string p   -- a different file
```

Build your own with `Resource.make`, giving the two halves in one place so
they cannot drift apart:

```
import Resource

let table name =
  let acquire = fn () -> let () = create_table! name in name in
  let release = fn n -> drop_table! n in
  Resource.make acquire release
```

### A bracket does not hide what it costs

The effects of acquiring and releasing are part of the resource's type, and
`with` folds them into the enclosing signature. A body that does nothing
still reports what holding the resource does:

```
let f () = with FS.temp_file "wand_" ".txt" as _ -> 1
-- f : Unit -> Int ! {FS.Read, FS.Write, Raise}
```

A bracket guarantees the release runs. It does not make the file disappear
from the signature.

---

## Decoders

Data that arrives from outside a script — a JSON document, a config file, a
command's output — arrives untyped. A `Decoder a` says how to read an `a` out
of it:

```
import Decode
import JSON

let pod =
  (Decode.map2 (fn n r -> Pod (name = n, restarts = r))
     (Decode.field "name" Decode.string)
     (Decode.field "restarts" Decode.int))

JSON.decode pod (JSON.parse! out)   -- Result String Pod
```

A decoder is a value. Naming one reads nothing, and the same decoder can be
run against several documents.

### Failure names the field

```
.items[3].metadata.name: expected String, got Int
.spec.replicas: no such field
```

The path is the point. Reading fields one at a time gets a null when the
name is wrong and carries on, so the run fails somewhere else, later; a
decoder stops at the field that was wrong and says which one it was.

### The combinators

```
Decode.int  Decode.float  Decode.string  Decode.bool
Decode.field name inner        -- read one field
Decode.optional name inner     -- read one field that may not be there
Decode.list inner              -- read every element
Decode.dict inner              -- read an object whose keys are data
Decode.nullable inner          -- read a value that may be null
Decode.map f d                 -- change what came back
Decode.map2 f a b              -- read two things and combine them
Decode.and_then f d            -- choose what to read next from what was read
Decode.succeed v  Decode.fail msg
Decode.one_of [a, b, ...]      -- the first that works
```

`map2` covers a two-field record. Wider ones chain through `and_then`, which
is also where validation goes:

```
let pod =
  (Decode.and_then (fn n ->
     Decode.and_then (fn r ->
       if r < 0 then Decode.fail "restarts cannot be negative"
       else Decode.succeed (Pod (name = n, restarts = r)))
       (Decode.field "restarts" Decode.int))
     (Decode.field "name" Decode.string))
```

`one_of` reports every alternative's complaint when none of them works, since
which one was the real reason is not the decoder's to guess.

### A field that may not be there

`Decode.optional` reads a field as an `Option`. A field that is absent, or
written as null, is `None`:

```
Decode.optional "restarts" Decode.int    -- Decoder (Option Int)

{"restarts": 4}      -- Ok (Some 4)
{}                   -- Ok None
{"restarts": null}   -- Ok None
{"restarts": "many"} -- Error .restarts: expected Int, got "many"
```

The last line is the point. `optional` says the field may be *missing*, not
that its contents may be anything — a field that is there and will not decode
is a failure, exactly as it is under `field`. The version that writes itself,
`one_of [field name inner, succeed None]`, gets this wrong: it turns a renamed
or retyped field into `None` as readily as a missing one, which is the silent
null the whole layer exists to replace.

### Keys that are data, and values that are null

`Decode.field` wants a name the program knows in advance. When the keys *are*
the data — a label map, per-host counts — `Decode.dict` reads the object into
a `Map`, and a failure names the key it was under:

```
{"web-01": 3, "db-01": 12}   Decode.dict Decode.int   -- Ok (Map of 2)
{"a": 1, "b": "x"}           Decode.dict Decode.int   -- Error .b: expected Int, got "x"
```

`Decode.nullable` is `optional`'s value-level sibling. `optional` asks whether
a *field* is there, which only a lookup can ask; `nullable` asks whether a
value is null, which is the question an element of a list raises:

```
[1, null, 3]   Decode.list (Decode.nullable Decode.int)   -- Ok [Some 1, None, Some 3]
```

### Domain literals decode as themselves

```
Decode.path  Decode.duration  Decode.url   Decode.size  Decode.version
Decode.date  Decode.time      Decode.datetime  Decode.ipv4  Decode.cidr  Decode.port
```

`"30s"` in a document lexes exactly as `30s` in a script, so the boundary
produces the type the rest of the program is written against rather than a
`String` to convert later. All twelve domain types have a decoder.

Each reads exactly what could have been written in the source, and nothing
the source would have rejected — the same lexer decides both. `port` is the
one that shows it, since a script writes `:8080` but a document usually holds
the bare number: `8080`, `"8080"` and `":8080"` all read. A port is 0 to
65535, so `65536` and `-1` do not — and the failure gives the rule rather
than only the refusal:

```
.port: invalid port :65536: must be 0-65535
```

That sentence comes from the lexer, which is the only place that knows it.
`String.to_port` and `String.to_ipv4` report it the same way, and
`String.to_port` accepts the same two spellings.

### Text is read, never written

A backend that carries types hands over an `Int` as an `Int`. A backend that
does not — a CSV cell, a line of output — hands over the text, and
`Decode.int` reads it exactly as `String.to_int` would. So one decoder serves
a document and a command's output both:

```
{"restarts": 4}     Decode.int   -- Ok 4
{"restarts": "4"}   Decode.int   -- Ok 4
```

The reverse never happens. `Decode.string` does not accept a number and
stringify it, because a `string` that accepts anything is the scrape it
exists to replace:

```
{"restarts": 4}     Decode.string   -- Error .restarts: expected String, got Int
```

### Running one

Every backend presents what it read in the same shape, so the combinators
above are the whole surface — what changes is only where the data came from:

```
JSON.decode  : Decoder 'a -> JSON   -> Result String 'a
TOML.decode  : Decoder 'a -> TOML   -> Result String 'a
CSV.rows     : Decoder 'a -> String -> Result String (List 'a)
Shell.decode : Decoder 'a -> String -> Result String 'a
Shell.lines  : Decoder 'a -> String -> Result String (List 'a)
```

A CSV's first row names its columns, so a row is read by field name like any
other record; a file without a header row is what `CSV.parse` is for. For
`Shell.lines`, `$()` strips the trailing newline, so a capture with nothing
in it is no lines rather than one empty line.

Backends that read one record per row or per line say which one failed
before saying what was wrong with it:

```
[2].restarts: expected Int, got "many"
```

### A type is its own decoder

A type with one constructor and named fields already says what a decoder for
it would do, so it has one:

```
type Pod (name : String, restarts : Int, timeout : Duration)

JSON.decode Pod.decoder (JSON.parse! out)   -- Result String Pod
```

`Pod.decoder : Decoder Pod` reads each field by its own name. Add a field to
the type and it is read; there is no second copy to keep in step.

A field whose type is an `Option` may be absent, and every other field may
not — which is what the type already says:

```
type Job (name : String, owner : Option String)

{"name": "build"}                  -- Ok (Job (name = "build", owner = None))
{"name": "build", "owner": 3}      -- Error .owner: expected String, got Int
```

Fields may hold lists, other derivable types, and the type being defined:

```
type Node (label : String, children : List Node)
```

A type with parameters takes one decoder for each, in the order it declares
them:

```
type Paged 'a (items : List 'a, total : Int)

Paged.decoder : Decoder 'a -> Decoder (Paged 'a)
Paged.encoder : ('a -> JSON) -> Paged 'a -> JSON

JSON.decode (Paged.decoder Pod.decoder) doc
```

Derivation covers the flat record whose keys are its field names. A document
with nested keys, different names, or values needing validation is what a
hand-written decoder is for — deriving removes the boilerplate ones, not the
interesting ones, and the two mix freely:

```
Decode.field "items" (Decode.list Pod.decoder)
```

`T.encoder` is derived from the same fields, so a type states its shape once
and both directions follow.

A type that is not a single-constructor record has neither, and naming one
says which:

```
type Shape = Circle Int | Rect Int Int
Shape.decoder
-- type 'Shape' has no derived decoder: it has more than one constructor
```

### Writing it back out

The same type gives an encoder, and it is an ordinary function rather than a
type of its own — encoding cannot fail, so there is nothing for one to carry:

```
Pod.encoder : Pod -> JSON

JSON.stringify (Pod.encoder p)
JSON.of_list (List.map Pod.encoder ps)
```

So a script can read a document, change one thing, and write back what it
read:

```
{"name": "api", "port": 8080, "timeout": "30s", "replicas": 2}   -- in
{"name":"api","port":8080,"timeout":"30s","replicas":4}          -- out
```

A field holding `None` is left out rather than written as null. Both read
back as `None`, and a config is tidier without the empty keys.

### Decoding is pure

The functions a decoder is built from carry the empty effect row, so a
decoder cannot read a file or run a command on the way past. Getting the data
is the caller's job, and already says so in the caller's signature.

```
Decode.map2 (fn a b -> let _ = $(echo hi) in a) Decode.int Decode.int
-- type error: cannot unify effects {} with {Shell, Raise | ..}
```

---

## Contracts

A function body may state preconditions and postconditions. They are checked
at runtime, and `result` is bound in a postcondition:

```
let half n =
  requires n % 2 == 0
  ensures result * 2 == n
  n / 2
```

A violated contract raises, reporting the clause that failed:

```
half 7   -- precondition failed: ((n % 2) == 0)
```

Contracts come after the `=`, before the body, and there may be several of
each. A broken contract is a bug rather than a fallible operation, so state
them for what must be true, not for input you expect to be invalid — validate
that and return a `Result`.

---

## Typed holes

`?` stands in for an expression you have not written yet. A program containing
a hole typechecks but does not run; `wand t` and `wand e` report what type
belongs there:

```
$ wand t 'List.fold_left ? 0 [1, 2, 3]'
Hole: Int -> Int -> Int ! 'e
```

The hole is inferred from how it is used, so the type system answers with the
signature to write rather than only reporting what is wrong. Holes are how you
sketch a solution and ask what fills it.

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

Parentheses group a tuple, and several arguments are written by
juxtaposition — `Rect 3 4`, not `Rect (3, 4)`. So `Some (1, 2)` is `Some`
applied to one pair, whatever file the type was declared in.

```
type Wrap = Wrap (List Int)     -- one field, type List Int
type Pair = Pair (Int, Int)     -- one field, tuple type (Int, Int)
```

### Single-constructor shorthand (named fields)

`type Point (x : Int, y : Int)` is shorthand for
`type Point = Point (x : Int, y : Int)`.

A named field's type may be an application — `children : List Node`,
`owner : Option String` — written without parentheses. A positional field may
not: `Pair Int Int` is two fields, not one type applied to another.

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
exception: they preload every stdlib module for convenience — `List`,
`String`, `Path`, `FS`, `IO`, `Duration`, `Env`, `Map`, `Regex`, `JSON`,
`TOML`, `CSV`, `Option`, `Par`, `Resource` and `Proc`.

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
let [foo = bar]            = import ./utils   -- bind utils.foo as bar
let [foo = a, bar = b]     = import ./utils   -- and utils.bar as b
```

The name on the left of the `=` is the module's; the name on the right is
what it is called here.

Or bind names under their own names:

```
let [foo, bar] = import ./utils         -- bind foo and bar
```

One form or the other — renaming and plain names cannot be mixed in a
single destructure.

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
`head`, `head!`, `tail`, `tail!`, `empty?`, `any`, `all`, `find`, `zip`, `take`, `drop`,
`take_while`, `drop_while`, `each`, `sort`, `sort_by`, `unique`, `range`,
`flatten`, `concat`, `get`, `get!`

### `String`

`length`, `empty?`, `upper`, `lower`, `trim`, `trim_left`, `trim_right`,
`slice`, `split`, `contains?`, `starts_with?`, `ends_with?`, `replace`,
`repeat`, `reverse`, `chars`, `join`, `lines`, `words`, `of_int`, `to_int`,
`to_float`, `to_bool`, `to_path`, `to_url`, `to_ipv4`, `to_cidr`, `to_port`,
`to_version`, `to_size`, `to_date`, `to_time`, `to_datetime`, `to_duration`

Each reads the value as it would be written in a script, and returns a
`Result` naming the rule that was broken:

```
String.to_duration "30s"      -- Ok 30s
String.to_ipv4 "256.0.0.1"    -- Error (invalid IPv4 address: each octet must be 0–255)
String.to_port ":99999"       -- Error (invalid port :99999: must be 0-65535)
```

`to_port` also takes the bare number — `"8080"` and `":8080"` both read —
since that is what an environment variable, a config file or a flag holds,
and `Decode.port` accepts both for the same reason.

### `Regex`

`compile`, `match?`, `capture`, `replace`, `replace_all`, `split`, `match_all`

### `Map`

`empty`, `get`, `get!`, `set`, `delete`, `has?`, `keys`, `values`, `size`,
`to_list`, `from_list`, `merge`, `map`, `filter`

### `FS`

`read_file`, `write_file`, `append`, `create_file`, `mkdir`,
`delete`, `rename`, `copy`, `list_dir`, `mtime`, `size` — each with a `!`
sibling that raises instead of returning a `Result`. Every one names its file
with a `Path`.
`exists?`, `file?`, `dir?`, `glob`, `glob_in`, `cwd`

`temp_file prefix suffix` is a resource rather than a plain call, so the
file it creates is removed when the bracket holding it ends:

```
with FS.temp_file "wand_" ".txt" as p ->
  FS.write_file! p contents
```

Release tolerates the file already being gone, so a body may rename it into
place — how an atomic write publishes its result — without cleanup failing
on the way out.

`temp_dir prefix` is the same for a directory, and removes it with
everything in it:

```
with FS.temp_dir "build_" as dir ->
  ...
```

A scratch directory exists to be filled, so release takes the tree rather
than requiring the body to empty it first.

### `Resource`

`make`

A resource pairs an acquire with a release, and `with` is the only thing
that runs one. See [Resource brackets](#resource-brackets).

### `Path`

`join`, `parent`, `basename`, `dirname`, `extension`, `with_extension`,
`absolute?`, `relative?`, `normalize`, `to_string`, `of_string`,
`components`

### `IO`

`print`, `println`, `print_err`, `println_err`, `read_line`, `read_all`, `flush`

### `Proc`

`exit`

```
Proc.exit : Int -> 'a ! {Proc}
```

Ends the program with the given code, running the cleanup of every `with`
still holding something on the way out. Its result type is whatever the
caller needs, since nothing follows it:

```
if broken? then Proc.exit 1 else continue! ()
```

### `Env`

`get`, `get!`, `set`, `clear`, `all`, `args`, `home`, `user`, `read`, `load`

### `CSV`

`parse`, `parse_with`, `stringify`, `stringify_with`, `read_file`, `read_file!`,
`rows`

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
`null?`, `get_bool`, `get_int`, `get_float`, `get_string`, `get_array`,
`get_object`, `field`, `field!`, `decode`

`JSON` is an opaque type.  `parse` / `read_file` return `Result String JSON`;
the `!` variants raise on error.  Typed extractors each return `Result`.

`of_map` is the inverse of `get_object`, writing keys in the order the `Map`
holds them — which is what makes output diff-friendly. A key the `Map` holds
twice is written once, at its first position, since that is the one `Map.get`
finds and a document naming a key twice is read differently by different
parsers.

```
import JSON

let j = JSON.parse! "{\"name\":\"Alice\",\"age\":30}"

match JSON.field "name" j with
| Ok v  -> JSON.get_string v    -- Ok "Alice"
| Error _ -> Error "missing"

-- Building JSON
let arr = JSON.of_list [JSON.of_int 1, JSON.of_int 2]
JSON.stringify arr    -- "[1,2]"

JSON.of_map [name = JSON.of_string "web", "content-type" = JSON.of_string "json"]
                      -- {"name":"web","content-type":"json"}

match JSON.read_file ./config.json with
| Ok cfg -> JSON.field! "host" cfg
| Error msg -> JSON.of_string "localhost"
```

### `TOML`

`parse`, `parse!`, `stringify`, `read_file`, `read_file!`,
`table?`, `array?`, `get_bool`, `get_int`, `get_float`, `get_string`,
`get_array`, `get_table`, `field`, `field!`, `decode`

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

### `Par`

`map`, `each`

Fork-join parallelism, and nothing else:

```
Par.map  : Int -> ('a -> 'b ! 'e) -> List 'a -> List (Result String 'b) ! 'e
Par.each : Int -> ('a -> Unit ! 'e) -> List 'a -> Unit ! 'e
```

The first argument is the most workers to run at once — stated, because how
much a script may do at the same time is a decision about the machine it runs
on. Results come back in the list's order, not the order they finished, and
an element whose work raises comes back as an `Error` in its place rather
than failing the others.

```
Par.map 4 (fn x -> x * 2) [1, 2, 3]        -- [Ok 2, Ok 4, Ok 6]
Par.map 4 (fn m -> Map.get! "k" m) [[k = 1], Map.empty]
                                           -- [Ok 1, Error "map key not found: k"]
```

Workers never outlive the call, there is no handle to a running one, and
these two functions are the only way to start any — so there is nothing to
await and no function needs a different colour for being called from one.

**A worker is never outside a handler's reach.** When nothing is watching, a
worker performs its own effects and twenty slow commands really do overlap.
When a handler is in scope — a mock, a `--dry-run`, a `--trace` — effects are
carried out on the calling side instead, one at a time, because that is where
the handler lives. So moving work into `Par` can never quietly escape a test:
being watched costs the overlap, and nothing rehearses for speed.

---

### `Shell`

`decode`, `lines`

Reading what a command wrote. See [Decoders](#decoders).

```
let ahead = Shell.decode Decode.int $(git rev-list --count HEAD)
```

### `Decode`

`int`, `float`, `string`, `bool`, `field`, `optional`, `list`, `dict`,
`nullable`, `map`, `map2`, `and_then`, `succeed`, `fail`, `one_of`, `path`,
`duration`, `url`, `size`, `version`, `date`, `time`, `datetime`, `ipv4`,
`cidr`, `port`

`Decoder a` is an opaque type. Running a decoder is a backend's job:

```
JSON.decode : Decoder 'a -> JSON -> Result String 'a
```

See [Decoders](#decoders).

### `Test`

`test`, `with_shell`, `shell_calls`, `without_writes`, `writes`

The module a test file imports. See [Testing](#testing).

### `Option`

`some?`, `none?`, `map`, `and_then`, `or_else`, `default`, `get!`,
`to_result`

`Option 'a` is a generic type (`type Option 'a = None | Some 'a`) — see
"Generics" above.

`Option` says a value may be absent; `Result` says an operation was attempted
and may have failed, and carries the reason. They do not mix: piping one into
something expecting the other is a type error.

```
Map.get "k" m |> unwrap        -- cannot unify Result 'a Int with Option 'a
```

`Option.to_result` is the bridge, and writing it is how a script states that
absence should now count as failure:

```
Map.get "k" m |> Option.to_result "no such key"   -- Result String 'a
```

---

## Testing

The `Test` module gives each test a handle (`t`) exposing `ok`, `eq`, and
`raises`:

```
let [test] = import Test

test "add" (fn t -> t.eq 4 (2 + 2))
test "some" (fn t -> t.ok (Option.some? (Some 1)))
test "get! out of bounds raises" (fn t -> t.raises (fn () -> List.get! 9 [1, 2, 3]))
```

- `t.eq expected actual` — pass if they are equal. The value under test goes
  last, as it does in every wand function, so it pipes:

  ```
  t.eq 4 (2 + 2)
  (2 + 2) |> t.eq 4
  ```

  Either way a failure reads `expected 4, got 5`, with `got` naming the code
  under test.
- `t.ok cond` — pass if `cond` is `true`.
- `t.raises thunk` — pass if calling `thunk ()` raises. `thunk` must be a
  zero-argument function (`fn () -> ...`), not the expression directly —
  wand evaluates arguments eagerly, so `t.raises (List.get! 9 xs)` would
  raise while evaluating the argument itself, before `t.raises` ever runs.

`let [test] = import Test` binds the one name the file uses unqualified;
`import Test` alongside it gives the module's other helpers under `Test.`.
Like every import, it brings in what it names and nothing more.

Each `test` call needs explicit parens around its `fn` argument
(`test "x" (fn t -> ...)`) — wand doesn't currently allow a bare `fn` as
a trailing application argument.

Run test files with `wand test`:

```
wand test                    # every test_*.wand at or below the current directory
wand test scripts/           # every test_*.wand under scripts/
wand test test_deploy.wand   # just this one
```

A test file is named `test_*.wand`, and a script's tests belong beside the
script — `deploy.wand` and `test_deploy.wand` in one directory, where the
prefix sorts every test together and away from the things being tested.
With no argument `wand test` searches from where you are standing, so
editing a script and running its tests takes no path. `_build`, `_opam`,
`.git` and `node_modules` are not searched. A file named on the command
line runs whatever it is called.

Each call to `test` is printed as `ok   <label>` or `FAIL <message>`; a
test whose body raises outside of `t.raises` is reported as a failure
without stopping the rest of the file. `wand test` exits nonzero if any
test failed or any file had a lex/parse/type error.

---

### Testing code that touches the outside world

The risky part of a script is what reaches outside it, which is exactly what
a handler can stand in for. `Test` covers the common cases so a test does not
have to write one by hand:

```
Test.with_shell [(fragment, output), ...] thunk   -- answer commands from a table
Test.shell_calls thunk                            -- the commands it would run
Test.without_writes thunk                         -- swallow writes, keep the result
Test.writes thunk                                 -- the paths it would write
```

Given a deploy that pushes and rewrites a config:

```
let deploy () =
  let version = $(git describe --tags) in
  let () = FS.write_file! /etc/app/config.toml "version = \"${version}\"\n" in
  let _ = $(rsync -a ./build/ web@host:/srv/app) in
  "deployed ${version}"
```

Handlers compose, so a script touching two families needs both, nested:

```
let sealed thunk =
  Test.with_shell [("git describe", "v2.1.0")] (fn () -> Test.without_writes thunk)

test "runs to completion without the network" (fn t ->
  t.eq (sealed deploy) "deployed v2.1.0")

test "pushes exactly once" (fn t ->
  let cmds = Test.shell_calls (fn () -> Test.without_writes deploy) in
  t.eq (List.length (List.filter (fn c -> String.contains? "rsync" c) cmds)) 1)

test "the config was never written" (fn t ->
  let _ = sealed deploy in
  t.eq (FS.exists? (Path.of_string "/etc/app/config.toml")) false)
```

The last one is the point: the script ran, and nothing happened.

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

A script can also run itself, with a shebang line and the executable bit:

```
#!/usr/bin/env wand
println "hello"
```

```
chmod +x deploy.wand
./deploy.wand
```

#### The compile cache

Loading a module is mostly type inference — on a 200-definition module,
5.7ms of 7.2ms — so what a module's types came out as is kept between runs
in `~/.cache/wand` (or `$XDG_CACHE_HOME/wand`).

An entry is keyed by the hash of the module's source *and* of everything it
imports, transitively, so an entry inferred against a file that has since
changed is unreachable rather than merely out of date. Nothing needs
clearing, and there is no timestamp to be wrong about. An unreadable entry
is a miss, not an error.

```
WAND_NO_CACHE=1 wand script.wand    # ignore it, and write nothing
```

Caching costs the first run of a script a little and saves every run after
it: a script importing six stdlib modules goes from 16.2ms to 12.1ms, and
one importing a 200-definition module from 16.5ms to 10.9ms.

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
wand test                             # run every test_*.wand from here down
wand test test_deploy.wand            # run named test files
wand h                                # show all commands
wand h e                              # help for a specific command
```

Each subcommand has a full-word alias: `i`/`interactive`, `e`/`eval`, `t`/`type`, `d`/`doc`, `fmt`/`format`, `h`/`help`.

### Lints

`wand t` reports lint findings alongside the type. Each carries a rule ID
whose prefix says what it will do to your build: `M-` rules must be fixed,
and `--strict` promotes them to errors; `H-` rules are advisory and stay
warnings however wand is run.

A rule has to be decidable to be must-fix, but being decidable does not make
it one — a rule can be exact and still be advisory, when failing a build over
it would punish the safer choice.

| Rule | Fires when |
|---|---|
| `V-PRED1` | a `?`-named function returns something other than `Bool` |
| `V-PRED2` | a `?`-named function also carries an `is_` prefix, which says predicate twice |
| `V-OR1` | a `Result`'s error side is `Unit`, so a failure reports no reason |
| `V-BANG1` | a function that can raise is not named with `!` |
| `V-BANG2` | a `!`-named function cannot raise |
| `V-NAME1` | a signature exposes a parameter whose name ends in `_` |
| `A-SHELL1` | a `$()` holds a shell pipeline of three or more operators |
| `A-USES1` | a manifest permits an effect the file does not use |
| `A-USES2` | a file performs effects and declares no manifest |

```
wand t --strict "..."     # violations become errors (exit 1)
wand t --json "..."       # findings as JSON, for tools
```

### Formatter

`wand fmt <file>...` formats one or more `.wand` files in place (each
file is overwritten with its formatted contents; a confirmation line is
printed per file). Shell globs work as expected: `wand fmt stdlib/*.wand`
reformats every file in `stdlib/`.

Comments (`-- ...`, `(* ... *)`, and doc `(** ... *)`) are always preserved —
never silently dropped, and never rewritten from one style into the other. Multi-equation function definitions
(`let f 0 = ... / let f n = ...`) are reconstructed as separate clauses
rather than left as the desugared `match`.

Lines are wrapped to fit 92 columns — chosen for the pane code is *read* in
rather than the one it is written in. A split diff gives each side around
ninety columns, and a line past that scrolls sideways exactly where code is
looked at hardest; the same width holds for wand shown next to bash in a
README or a terminal recording.

An item with a comment inside it is re-emitted exactly as written.
Formatting it would mean deciding which expression the comment now belongs
to, and a comment moved to the wrong one is worse than a comment left where
its author put it. Everything else has a formatting rule.

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

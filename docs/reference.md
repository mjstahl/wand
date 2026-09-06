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
  - [List](#list) · [String](#string) · [Regex](#regex) · [Map](#map) · [FS](#fs) · [Resource](#resource) · [Stream](#stream) · [Path](#path) · [IO](#io) · [Float](#float) · [Int](#int) · [Ord](#ord) · [DateTime](#datetime) · [Clock](#clock) · [Random](#random) · [Proc](#proc) · [Env](#env) · [CSV](#csv) · [JSON](#json) · [TOML](#toml) · [Duration](#duration) · [Size](#size) · [Port](#port) · [Version](#version) · [Glob](#glob) · [IPv4](#ipv4) · [CIDR](#cidr) · [URL](#url) · [Par](#par) · [Shell](#shell) · [Decode](#decode) · [Args](#args) · [Hash](#hash) · [Digest](#digest) · [Base64](#base64) · [Test](#test) · [Option](#option) · [Result](#result)
- [Testing](#testing)
- [Comments](#comments)
- [Style for scripts](#style-for-scripts)
- [REPL and CLI](#repl-and-cli)
- [Building](#building)

---

## Quick start

```sh
wand script.wand        # run a script
wand --dry-run deploy.wand   # report what it would change, without doing it
wand --trace deploy.wand     # run it, reporting each effect as it happens
wand i                  # interactive session
wand -e "1 + 2"         # evaluate an expression
wand t script.wand      # typecheck a file without running it
wand d "List.map"       # show doc string
wand d                  # list all names in scope
wand f script.wand      # format a file in place
wand s                  # run every test_*.wand from here down
wand h                  # help
wand v                  # print the version
```

---

## Primitives

```ocaml
42          -- Int
3.14        -- Float
"hello"     -- String
true        -- Bool
()          -- Unit
```

`Int` is a machine word. It holds `-4611686018427387904` to
`4611686018427387903`. A literal outside that range is a lex error.
Arithmetic that goes outside it is a runtime error. The value does not wrap
around:

```ocaml
4611686018427387903 + 1
-- runtime error: integer overflow in '+':
--   Int holds -4611686018427387904 to 4611686018427387903
```

This is a runtime error, not the `Raise` effect. Division by zero is the
same. Any `+` can overflow. To track it, wand would put `Raise` on every
function that adds two numbers.

Arithmetic (`+ - * /` and unary `-`) has one spelling for `Int` and for
`Float`. An expression holds one numeric type. wand never mixes the two for
you. `1.5 + 1` is a type error, and the error names the functions that
convert. [`Float`](#float) holds them. `%` accepts `Int` only. A function
that does not pin its numbers accepts both:

```ocaml
let square x = x * x     -- square : Num -> Num
(square 2, square 1.5)   -- (4, 2.25) : (Int, Float) — each call picks its type
```

`Num` in a signature means `Int` or `Float`. The use site decides which.
It appears in [Type annotations](#type-annotations) like any type name.
Float division does not raise: `1.0 / 0.0` is infinity, as IEEE 754 says.
Int division keeps its check.

### Adding and `Add`

`+` and `-` take one more constraint than `*` and `/` do. A `Size` and a
`Duration` are quantities: two of them add to a third of the same type.

```ocaml
100MB + 4KB     -- 100004000B : Size
1h + 30min      -- 1h30m : Duration
let sum a b = a + b     -- sum : Add -> Add -> Add
```

`Add` is `Int`, `Float`, `Size` or `Duration`, and every `Num` is an `Add`.
Multiplication is not in it: a `Size` times a `Size` is not a `Size`, and
scaling one by a number is a third type in the operator, which
[`Duration.scale`](#duration) does under a name instead.

A sum of sizes is written in bytes, because a `Size` holds one unit and
`100MB + 4KB` fills two. [`Size.format`](#size) is the readable spelling.
Neither type has a value below zero, so a subtraction that would go under
floors there: `5s - 10s` is `0s`, the answer
[`Duration.sub`](#duration) already gives.

### Comparison and `Ord`

`==` and `!=` compare any two values of one type. `<`, `>`, `<=` and `>=`
take an `Ord`, short for ordered: a type that wand orders. These ten are
ordered:

```text
Int   Float   String
Duration   DateTime
Size   Version   Port   IPv4   CIDR
```

A type outside that set is a type error where it is written, not a failure
during the run:

```ocaml
r/a/ < r/b/
-- type error: Regex is not ordered, so it cannot be compared with < > <= >=
```

`Ord` is a constraint, as `Num` is, so a function that only compares stays
polymorphic:

```ocaml
let later a b = if a < b then b else a     -- later : Ord -> Ord -> Ord
```

That one is already written, and [`Ord`](#ord) is where it lives: `Ord.max`,
`Ord.min`, `Ord.clamp` and `Ord.between?` are one definition each, serving
all ten types.

The constraints nest: every `Num` is an `Add`, and every `Add` is an `Ord`.
A variable that is more than one of them is the narrowest.

**`List.sort` orders more than `<` does.** It takes a list of any type, so
sorting is available where the operator is not:

```ocaml
List.sort [(2, "a"), (1, "b")]      -- [(1, "b"), (2, "a")]
(1, "b") < (2, "a")                 -- type error: not ordered
```

Where a type is one of the ten, sorting reads the value, exactly as `<`
does. Everything else sorts by its shape: a tuple and a list read left to
right, and **a variant sorts by its declaration** — a constructor sorts
where it was written, not where its name falls in the alphabet.

```ocaml
type Prio = Low | Medium | High
List.sort [High, Low, Medium]       -- [Low, Medium, High]
```

So renaming a constructor does not move values, and the order a reader sees
in the declaration is the order they come back in. `Option` and `Result`
declare their absent and failed cases first, so `None` sorts before `Some`
and `Error` before `Ok`. Two functions have no order and say so.

For an order the shape does not give, `List.sort_by` takes the key.

**A comparison is on the value, not on the text it was written as.** A
`Duration` is a sum of units, and a `DateTime` carries an offset, so one
value has more than one spelling. Equality reads it the same way:

```ocaml
90s > 1min                                        -- true
60s == 1min                                       -- true
2024-01-15T20:00:00+05:30 == 2024-01-15T14:30:00Z -- true, one instant
```

A `DateTime` with no offset is read as UTC.

The other three read the same way, and each is a case where the text order
is wrong:

```ocaml
1GB > 999MB                       -- true; a KB is 1000 bytes, as SI says
1.10.0 > 1.9.0                    -- true; the numbers are numbers
10.0.0.10 > 10.0.0.9              -- true; the address is its 32 bits
1000B == 1KB                      -- true
```

`Version` follows [semver precedence][semver]: a version with a prerelease
is below the same version without one, and two prereleases compare
identifier by identifier, a number against a number numerically and a
number below a word. So
`1.2.3-alpha.1 < 1.2.3-alpha.2 < 1.2.3-beta < 1.2.3`.

`List.sort` reads a value the same way, so sorting these types answers with
the order above rather than with the order of their text.

Not ordered: `Path` and `Glob`, because text order reads as tree order and
is not; `URL`, which has no natural one; `Regex`; `Bool`; and the
containers.

[semver]: https://semver.org/spec/v2.0.0.html

String interpolation with `%{...}`, which takes any expression:

```ocaml
let name = "world"
"hello, %{name}!"        -- "hello, world!"
"1 + 1 = %{1 + 1}"       -- "1 + 1 = 2"
"home is %{$HOME}"       -- reads the environment, like any other expression
```

`$` is not special in a string. A string that holds shell or Make source
keeps it. This is what you want when something else expands the string:

```ocaml
"export PATH=$HOME/bin:$PATH"   -- exactly those characters
```

For the literal text `%{`, escape the percent: `"\%{not an interpolation}"`.

String concatenation with `++`:

```ocaml
"foo" ++ "bar"           -- "foobar"
```

### Backtick strings

Between backticks each character is itself. There are no escapes. A quote
is a quote, and a backslash is a backslash. Use this form for text written in
another language:

```ocaml
`{"hello": "world"}`
`\d+\s*(\w+)`
`C:\Users\ada`
```

A backtick string spans lines, and the layout is the text. A newline
directly after the opening backtick is not part of it, so a literal can start
on the line below. wand trims nothing else. Indentation and the final newline
stay:

```ocaml
`
Hello World
This was a line break
`
```

is `"Hello World\nThis was a line break\n"`.

`%{...}` still interpolates, so a backtick string is a template like any
other:

```ocaml
let user = "ada"
`{"name": "%{user}", "role": "admin"}`
```

So `%{` is the one sequence a backtick string cannot hold. Write that text
in an ordinary string and escape the percent: `"\%{literal}"`.
[Primitives](#primitives) lists the same escape. If a `%{` in a backtick
string never closes, lexing fails, and the error names this workaround.
Generated shell and template text usually fails this way.

A backtick string is an ordinary `String`. The syntax changes how you write
it, not what it is. It concatenates, interpolates and matches like any other
string:

```ocaml
`ab` ++ `c`                    -- "abc"

match answer with
| `yes` -> 1
| _     -> 0
```

### A `String` is bytes

There is no encoding layer. A `String` holds bytes, `String.length` counts
them, and nothing validates that they are UTF-8.

That is the right model for what wand does. It reads log files, shell
output, filenames and configuration, and all of those are bytes. A log with
one badly-encoded line is an ordinary thing to have to summarise, and a
`String` that validated UTF-8 would refuse to open the file. Paths are
byte-oriented for the same reason: the operating system takes bytes, and
inventing an encoding on the way through would break the one job the value
has.

Most of the module is correct on any input without knowing about encodings,
because a UTF-8 continuation byte can never be mistaken for an ASCII
character. Splitting on an ASCII delimiter is safe by construction:

```text
==  !=  <  >          split   lines   words   join
contains?   starts_with?   ends_with?   empty?
trim   trim_left   trim_right   repeat   replace (ASCII needles)
```

These read bytes where a reader might expect characters. The answers are
for `"café"`, which is five bytes and four characters:

| written | answers | reads |
|---|---|---|
| `String.length "café"` | `5` | bytes, not characters |
| `String.bytes "café"` | five strings | the é comes back as its two bytes |
| `String.upper "café"` | `"CAFé"` | ASCII only; the é is untouched |
| `String.slice 0 4 "café"` | `caf` and half the é | a cut can land inside a character |
| `String.reverse "café"` | mojibake | the é is reversed byte by byte |

`upper` and `lower` are the ones to watch, precisely because they *work* for
the ASCII cases that make up almost every use — a header name, an
environment variable, a command word. The failure only shows when user data
is case-folded, by which time the code has shipped and looks fine.

`Regex` matches bytes on the same terms. `.` is one byte:

```ocaml
Regex.match? r/^.$/ "é"      -- false
Regex.match? r/^..$/ "é"     -- true
```

Cutting text down for display is the case where that matters, and
`String.truncate` is the one function here that knows about UTF-8. It takes
at most n bytes and never ends inside a character:

```ocaml
String.slice 0 4 "café"       -- four bytes, the last one half of the é
String.truncate 4 "café"      -- "caf"
String.truncate 5 "café"      -- "café"
```

The budget is bytes, as every other `Int` in the module is, so
`String.length (String.truncate n s)` is never above `n`. It is not a
display width, for the reason below. Bytes that are not UTF-8 are cut at
`n`, because there is no character there to keep whole.

**`length` counts bytes and keeps the name on purpose.** The question people
reach for it with is a width or an alignment check, and a character count
would not answer that either: a CJK character occupies two terminal columns
and a combining mark occupies none. Display width is a third quantity.
Counting characters instead would swap one wrong answer for a different
wrong answer while implying the question had been settled.

The boundary is not a problem. `JSON`, `TOML` and `Decode` turn a document's
escapes into UTF-8 bytes, so text read from a manifest compares and matches
against a literal in the source:

```ocaml
let doc = JSON.parse! `{"who": "caf\u00e9"}`
JSON.decode (Decode.field "who" Decode.string) doc == Ok "café"    -- true
```

---

## Lexical domain types

wand has literal syntax for the values a script uses most. Each one is a
type of its own, not a string. So the type checker catches a `DateTime` that
you gave where a `Duration` belongs.

| Type | Example literals |
|---|---|
| `Path` | `/etc/hosts` `/home/user/file.txt` `./relative` |
| `Glob` | `*.wand` `./**/*.ml` `**.wand` |
| `DateTime` | `2024-01-15T14:30:00Z` `2024-01-15T09:00:00+05:30` `2024-01-15` |
| `Duration` | `5min` `1h30m` `2d` `500ms` `1w` |
| `URL` | `https://example.com` `http://localhost:8080/api` |
| `IPv4` | `192.168.1.1` `10.0.0.1` |
| `CIDR` | `192.168.0.0/24` `10.0.0.0/8` |
| `Port` | `:80` `:8080` `:443` — 0 to 65535; outside that is a lex error naming the rule |
| `Version` | `1.2.3` `0.1.0` `1.2.3-alpha.1` |
| `Size` | `10MB` `512KB` `1.5GB` `100B` |

```ocaml
let deadline = 2024-12-31
let server   = https://api.example.com
let log_dir  = /var/log/app
let timeout  = 30s
let limit    = 100MB
```

---

## Let bindings

```ocaml
let x = 42
let greeting = "hello"
```

With a type annotation:

```ocaml
let x : Int = 42
let name : String = "wand"
```

---

## Functions

```ocaml
let double x = x * 2
let add x y  = x + y
```

Anonymous functions with `fn`:

```ocaml
fn x -> x + 1
fn x -> fn y -> x + y
```

Recursive functions reference themselves by name:

```ocaml
let fact n = if n <= 0 then 1 else n * fact (n - 1)
```

With a return type annotation:

```ocaml
let double x : Int = x * 2
```

Multi-equation functions — pattern match directly in the definition:

```ocaml
let fib 0 = 0
let fib 1 = 1
let fib n = fib (n - 1) + fib (n - 2)
```

The equations are one definition. Write them on consecutive lines. Give
each one the same number of parameters. wand tries them in the order you wrote
them. If an earlier equation already covers a later one, that is an error:

```ocaml
let f _ = 0
let f 1 = 1     -- error: equation 'f 1' is unreachable
```

Together, the equations must also cover every case. wand checks this as it
checks a `match`.

A file declares definitions. The REPL edits them. So neither check applies
in the REPL. A second `let` for a function that exists adds a clause to it,
and the REPL reports `f : Int -> Int, 2 equations`. The merged function tries
specific patterns before catch-alls, whatever order you entered them in. A
base case that you add after a catch-all still fires. If two clauses have the
same pattern, the newer one wins. The REPL also accepts equations that do not
yet cover every case. The gap shows as `{Raise}` in the reported type, and a
call that lands in the gap raises a pattern-match failure.

Works locally too, with `in` — repeating `let` on each equation or not:

```ocaml
let answer =
  let fib 0 = 0
  let fib 1 = 1
  let fib n = fib (n - 1) + fib (n - 2)
  in fib 10

let answer =
  let fib 0 = 0
  fib 1 = 1
  fib n = fib (n - 1) + fib (n - 2)
  in fib 10
```

The second form works only in a local definition. At the top level each
equation needs its own `let`, because there is no `in` to end the
definition.

Mutually-recursive functions — chain definitions with `and`:

```ocaml
let is_even n = if n == 0 then true else is_odd (n - 1)
and is_odd n = if n == 0 then false else is_even (n - 1)
```

Works the same way locally, with `in`:

```ocaml
let answer =
  let is_even n = if n == 0 then true else is_odd (n - 1)
  and is_odd n = if n == 0 then false else is_even (n - 1)
  in is_even 7
```

In the REPL, enter a group as one entry. The first line alone does not
typecheck, because its partner is unbound. So put the `and` at the end of the
line. Do not start the next line with it:

```text
>> let is_even n = if n == 0 then true else is_odd (n - 1) and
   .. is_odd n = if n == 0 then false else is_even (n - 1)
   ..
is_even : Int -> Bool
is_odd : Int -> Bool
```

A blank line ends the group. In a file the `and` can sit at either end of
the line break, because you see the whole definition at once.

Each member of an `and` group must be a function with at least one
parameter. wand evaluates eagerly, so a plain value cannot use a sibling that
does not exist yet. Only the body of a function waits for a call.

### A call in tail position

A call is in tail position when its value is the value of the body around
it. That is the last statement of a block, either branch of an `if`, the
body of a match arm, and the body of a `let ... in`.

A tail call does not grow the stack, so a loop written as one runs to any
depth:

```ocaml
let sum 0 acc = acc
let sum n acc = sum (n - 1) (acc + n)     -- tail: nothing waits on it

sum 10000000 0
```

A call that is not in tail position leaves work behind it, so it keeps a
frame per level and its depth is bounded by memory:

```ocaml
let sum 0 = 0
let sum n = n + sum (n - 1)               -- not tail: the `+` waits
```

Both compute the same answer. The first is the one to write for a list or a
count that is not small.

---

## If expressions

```ocaml
if x > 0 then "positive" else "non-positive"
```

An `if` with nothing to do when the condition is false leaves the branch out:

```ocaml
if stashes > 0 then IO.println "Stashes: %{stashes} saved"
```

This is the same expression as `else ()`. It is not a second kind of
conditional. The branch must be `Unit`, because a branch that is not there can
only be `()`:

```ocaml
if ready then 1
-- an `if` with no `else` does nothing when the condition is false,
--   so its branch must be Unit -- this one is Int
```

`wand f` removes an empty `else`: `if c then f () else ()` comes back as
`if c then f ()`.

---

## Pipeline

The pipeline operator `|>` has two meanings. The shape of the right operand
decides which one. This is the only operator in wand that the parser decides,
rather than the value. To know which meaning applies, read the right side. You
never need a value from the run.

**Form 1 — application.** When the right operand is any ordinary expression,
`x |> f` is exactly `f x`:

```ocaml
[1, 2, 3] |> List.map double |> List.filter (fn x -> x > 2)
$(git log --oneline) |> String.lines |> List.length
```

**Form 2 — stdin threading.** The right operand is literally a `$()` or a
`$?()` form. Then `|>` sends the left value, a `String`, to the standard input
of the command:

```ocaml
$(git log --oneline) |> $(grep "fix") |> $(wc -l)
report |> $?(mail -s "nightly" ops@example.com)
```

The stdout of each stage becomes the stdin of the next stage. `|>`
associates to the left, so a chain reads like a shell pipeline. A `$?()` stage
gives a `ShellResult`, so it ends the chain. To continue, pipe its `.stdout`
yourself.

**The difference is syntactic, and that is the point.** `$()` is not a
function value. `let g = $(grep foo)` runs `grep` immediately and binds its
output. It does not make a stage that you can pipe into. wand sends stdin only
when `$()` or `$?()` comes directly after `|>`. You can decide the meaning from
the text, with no type information: if the right side starts with `$`, wand
runs a process; if it does not, wand applies a function.

**Choosing between wand pipes and shell pipes.** Both of these are idiomatic:

```ocaml
$(git log --oneline | grep fix | wc -l)          -- one shell pipeline
$(git log --oneline) |> $(grep fix) |> $(wc -l)  -- three wand stages
```

Use a **shell pipe** in three cases: you copy an existing one-liner, the
pipeline is one idiom, or only the last output matters. wand sees one
operation. Use **wand stages** in three cases: you want a typed function
between two commands, you want `$?()` to handle the failure of one stage, or
you want to see each stage. Put the boundary where you want types, errors or
an audit trail to start.

---

## Sequencing

Expressions evaluated for their effects are separated with `;`; the value of
the sequence is the last expression:

```ocaml
IO.println "starting";
IO.println "working";
42
```

A newline alone ends a statement. So at the top level of a file you need `;`
in two cases only: to put several statements on one line, or to make the
sequence explicit.

A newline does not end a statement if the next line is indented past the
statement it follows. That line continues it:

```ocaml
let names =
  List.filter
    short?
    everyone
```

Indentation is the whole of the rule. A line back at the statement's own
column starts a new statement; a line further in continues the one above.
A file indented consistently is a layout choice, not one long expression.

A newline does not end a statement if the next line starts with an operator
either. A pipeline that leads with `|>` needs this:

```ocaml
let count =
  names
    |> List.filter short?
    |> List.length
```

`-` follows the same rule, and there it can surprise you. These two lines
are one statement, and `a` is `-1`:

```ocaml
let a = 1
-2
```

Write `let b = -2` if you want a second statement.

A newline ends a binding inside a block, exactly as it does at the top
level:

```ocaml
let deploy! target = (
  let config = Path.of_string "%{target}/config.toml"
  FS.write_file! config "version = \"1\"\n"
)
```

`;` still works, and so does `in`. All three say the same thing, and `wand f`
writes one of them: the `;` of the block the binding is in, and `in` where
there is no block. So the newline is a way to write a binding, not a third
form to read.

Inside a bracket that a statement opened, a newline is formatting again and
an application continues across it. That is what lets an argument list run
down the page:

```ocaml
let deploy! target = (
  FS.mkdir! (Path.of_string target);
  FS.write_file! (Path.of_string "%{target}/config.toml") "version = \"1\"\n";
  "deployed"
)
```

The `;` form, spelled out:

```ocaml
let deploy! target = (
  FS.mkdir! (Path.of_string target);
  FS.write_file! (Path.of_string "%{target}/config.toml") "version = \"1\"\n";
  "deployed"
)
```

The value of the sequence is the last expression. A `;` before the `)` is
allowed. wand discards each statement before the last one. So `V-DROP1` reports
a discarded `Result` here, as it does for a top-level statement. Match it, call
the `!` sibling, or bind it to `_` to say that the failure does not matter.

### A binding in a block

A `let` in a block binds for the rest of that block:

```ocaml
let deploy! release work = (
  let stage = Path.join work (Path.of_string "pkg");
  let archive = Path.of_string "./dist/%{release}.tar.gz";
  FS.mkdir! stage;
  FS.copy! archive stage;
  "deployed"
)
```

`;` ends the binding's right-hand side, exactly as a newline does at the top
level of a file. So a block and a file read the same way, and naming two
values costs no indentation.

A block cannot end with a binding. Nothing would read the name, so it is a
parse error:

```ocaml
(f (); let x = 1)
-- parse error: this binding has no body: a block cannot end with a `let`,
--   because nothing would read the name
```

`let ... in` keeps its own meaning: it names a value for one expression, and
a `;` after that expression starts the next statement. In
`(let x = 1 in x + 1; 9)` the `x` belongs to `x + 1` and to nothing else.

`let () = e1 in e2` still works and means the same thing. It also guarantees
that `e1` is `Unit`.

`wand f` writes back `;` or `in`, whichever the binding's position calls for.
A binding inside a block gets the `;`; one that names a value for a single
expression gets `in`. A binding written with neither — joined to its body by
the newline alone — comes back as one of those two. So one function is never
printed two ways, and `(let x = 1; x + 2)` and `let x = 1 in x + 2` each stay
as they are: the first is in a block, the second is not.

A binding written `in` ahead of a `;` is left alone, because there the `in` is
what keeps the name off the statements below it — `(let x = 1 in x + 1; 9)`
again. That is a difference in meaning, so the formatter does not remove it.

---

## Pattern matching

```ocaml
match x with
| 0 -> "zero"
| 1 -> "one"
| n -> "other: %{n}"
```

With guards:

```ocaml
match n with
| x when x < 0  -> "negative"
| x when x == 0 -> "zero"
| _             -> "positive"
```

### Exhaustiveness checking

`wand t` checks that each `match` covers every case. A case that is missing
is a type error, not a surprise during a run:

```ocaml
let f x = match x with | 0 -> "zero"
-- wand t: type error: non-exhaustive match: missing case, e.g. _
```

A guard (`when`) can fail to fire, so a guarded case never covers anything
by itself. It always needs a plain case beside it.

Some types hold too many values to list: `Int`, `Float`, `String` and the
other lexical domain types. Only a wildcard or a variable pattern covers one
of these. wand checks the rest against their constructors: `Bool`, tuples,
lists, `Result`, and the variant types you define, which include generic ones
like `Option`.

A map pattern is partial by design. wand never reports one.

---

## Tuples

```ocaml
let pair   = (1, 2)
let triple = (true, "hello", 42)

let (a, b) = pair      -- destructure
```

---

## Lists

```ocaml
let xs    = [1, 2, 3]
let empty = []

1 :: [2, 3]            -- cons: [1, 2, 3]
1 :: 2 :: 3 :: []      -- [1, 2, 3]
```

List patterns:

```ocaml
match xs with
| []        -> "empty"
| [x]       -> "one element: %{x}"
| [x, y]    -> "exactly two"
| [h :: t]  -> "head %{h}, tail %{t}"
```

Cons patterns chain, matching several leading elements at once:

```ocaml
match xs with
| [a : b : c : t] -> "first three: %{a}, %{b}, %{c}, rest: %{t}"
| _               -> "fewer than three elements"
```

The same patterns work in a `let`, with one difference. A `match` arm gives
the whole shape, because a longer list belongs to another arm. A `let` has no
other arm. It only binds. So in a `let` a list pattern names the first
elements and ignores the rest. A map pattern behaves the same way with
keys:

```ocaml
let xs = [1, 2, 3]

let [a, b, c] = xs      -- a = 1, b = 2, c = 3
let [a, b]    = xs      -- a = 1, b = 2, the 3 is not consulted
let [h :: t]  = xs      -- h = 1, t = [2, 3]
```

The shape of a tuple is part of its type. So a wrong pattern for a tuple is
a type error. The length of a list is not part of its type. So a `let` that
names more elements than the list holds is accepted, and it fails during the
run:

```ocaml
let [a, b] = [1]
-- runtime error: pattern match failure
```

Use `match` when even the elements you name may not be there.

Multi-equation over lists:

```ocaml
let sum []      = 0
let sum [h :: t] = h + sum t
```

---

## Maps

String-keyed, homogeneous maps. The type is `Map T` where `T` is the value type.

```ocaml
let m = {x = 1, y = 2, z = 3}   -- Map Int
```

A key is any string. Put quotes around a key that is not an identifier.
Most keys in a document from elsewhere need them:

```ocaml
{"content-type" = "application/json", "@type" = "Pod", name = "web"}
```

Quoted keys work in patterns too: `| {"content-type" = v} -> v`.

A map holds a key once. Give a key twice, and the last value wins. The key
keeps the position where it first appeared. That is what an assignment means.
It also writes a document back in the order it arrived:

```ocaml
{a = 1, b = 2, a = 9}        -- {a = 9, b = 2}
Map.set "b" 99 {a = 1, b = 2, c = 3}   -- {a = 1, b = 99, c = 3}
Map.merge {a = 1, b = 2} {b = 9}       -- {a = 1, b = 9}
```

A JSON document can name a key twice, but a `Map` cannot hold one twice.
Each reader takes the later value: `JSON.field`, `Decode.field`, and the `Map`
from `JSON.get_object`. So two readers of one document always agree.

Using the `Map` module:

```ocaml
Map.get  "x" m     -- Some(1)
Map.get! "x" m     -- 1  (raises on missing)
Map.has? "x" m     -- true
Map.set  "w" 4 m   -- {w = 4, x = 1, y = 2, z = 3}
Map.delete "x" m   -- {y = 2, z = 3}
Map.keys   m       -- ["x", "y", "z"]
Map.values m       -- [1, 2, 3]
Map.size   m       -- 3
Map.to_list m      -- [("x", 1), ("y", 2), ("z", 3)]
Map.from_list [("a", 1), ("b", 2)]   -- {a = 1, b = 2}
Map.map    (fn x -> x * 2) m         -- {x = 2, y = 4, z = 6}
Map.filter (fn x -> x > 1) m        -- {y = 2, z = 3}
Map.merge m1 m2                      -- keys in m2 take precedence
```

A map pattern is partial. Name only the keys you need. A bare identifier is
short for the key and a variable of the same name. `key = pat` matches a
subpattern, or gives the value another name. A quoted key always takes that
form, because it has no identifier to shorten:

```ocaml
match m with
| {x, y} -> x + y            -- binds x and y by name
| {x = a, y = b} -> a + b    -- the rename form

let {x} = m in x             -- extract just x; other keys ignored
```

A key that the map does not hold fails during the run. A list of the wrong
length fails the same way. The keys of a map are not part of its type.

An empty map is `Map.empty`, and `{}` is the same value written as a
literal.

Brackets mean lists and nothing else. `[x = 1]` and `[x = a]` are refused,
and the error names the brace spelling.

---

## Shell execution

Run a shell command and get its stdout as a `String`. Raises on non-zero exit.

```ocaml
$(git status)
$(ls -la)
$(git log --oneline -%{count})      -- values go in with %{...}
```

Get full output without raising using `$?()`, which returns a `ShellResult`:

```ocaml
let r = $?(git status)
r.stdout   -- String
r.stderr   -- String
r.code     -- Int
```

### Interpolation: `%{...}` quotes, `%!{...}` splices

A command line is a sequence of arguments. A value that goes into one must
say which argument it is. There are two forms.

**Quote interpolate — `%{x}`.** The value becomes one argument, whatever it
holds. A space does not split it. `*` does not expand. `;`, `|`, a backtick
and `$(...)` are text:

```ocaml
let f = "two words.txt"
$(ls %{f})                  -- runs: ls 'two words.txt'

let p = "*.txt"
$(ls %{p})                  -- runs: ls '*.txt'        (one literal argument)

let n = "x; rm -rf /tmp/z"
$(echo %{n})                -- runs: echo 'x; rm -rf /tmp/z'
```

Write `%{x}` between quotes of your own, and it becomes part of that word.
It is not an argument of its own. wand escapes it for the quote it sits in.
The shell reads nothing in the value as syntax:

```ocaml
let name = "$(whoami)"
$(echo "hi %{name}")        -- runs: echo "hi \$(whoami)"    (one argument)
$(grep "^%{name}" log)      -- the value is part of the pattern
```

**Raw interpolate — `%!{x}`.** wand puts the value into the command as shell
source, and the shell reads it. Use this form for a value that holds several
arguments, a pattern to expand, or a whole command:

```ocaml
let flags = "-l -a"
$(ls %!{flags} %{f})        -- runs: ls -l -a 'two words.txt'

let pattern = "./logs/*.log"
$(wc -l %!{pattern})        -- runs: wc -l ./logs/*.log   (the shell expands)

let cmd = "echo hello"
$(%!{cmd})                  -- runs: echo hello
```

Both work the same way in `$?()`.

**Which one to use.** Use `%{...}` for data: a path, a filename, an
argument. Use `%!{...}` for text that you wrote or built to be shell syntax.
`%!{...}` lets the value decide what runs:

```ocaml
let name = "x; rm -rf /tmp/z"
$(echo %!{name})            -- runs: echo x; rm -rf /tmp/z
```

That is why there are two spellings. Under `%{...}` a value is only an
argument to the command you wrote. A value from a file, from an environment
variable, or from the output of another command cannot change what runs.
Under `%!{...}` it can. Sometimes that is what you want, and `grep` finds
every site. A manifest also limits which commands each spelling can reach:
`uses {Shell(git, curl)}`. See [Manifests](#manifests).

Raw interpolation works only in a command. A string literal has no argument
boundaries, so it has nothing to quote for. `%!{...}` in a string is a lex
error. It is not another spelling of `%{...}`.

`test/wand/test_shell_interpolation.wand` gives a case for each rule
above.

Pipeline with `|>` threads the left-hand string as stdin to the command:

```ocaml
$(git log --oneline)
  |> $(grep "fix")
  |> $(wc -l)
```

The stderr of a command is the stderr of the script. It appears as the
command writes it. `$?()` captures it instead. Stdin changes neither
form.

Combined with regex:

```ocaml
$(git log --oneline)
  |> String.lines
  |> List.filter (Regex.match? r/fix|bug/i)
```

---

## Glob

`Glob` is a type of its own, not a `Path`. It is a pattern for a set of
files. A glob literal uses `*`, `**`, `?` or `[...]`:

```ocaml
*.wand              -- Glob
./**/*.ml           -- Glob (relative paths need ./ prefix)
**.wand             -- Glob (recursive, any depth)
/var/log/*.log      -- Glob
./file?.txt         -- Glob (? matches exactly one character)
./file[12].txt      -- Glob ([...] matches one of the characters listed)

./utils.wand        -- Path (no wildcards — unchanged)
```

A pattern that starts with a bare word needs the `./` prefix. Each relative
path does. Write `./file*.txt`, not `file*.txt`. Without the prefix, `file` is
a name and `*.txt` is a glob literal. The line then means "apply `file` to
this glob". So wand answers:

```text
'file*.txt' should be written as './file*.txt'
```

`FS.glob` accepts a `Glob`, not a `Path`. Give it a `Path` and you get a
type error:

```ocaml
import FS

FS.glob    *.wand            -- List Path, relative to cwd
FS.glob_in ./**/*.ml ./src   -- List Path, relative to ./src
```

Both always return a list. The list is empty if nothing matches. Neither
raises. The results are sorted by name.

wand matches a symlink like any other entry, and answers with the symlink
itself. The walk does not go through it. So each answer is under the directory
you named. A link out of that directory would add files that the directory
does not hold. A link back into it would send the walk round in a circle.

---

## Regular expressions

Regex literals use the `r/pattern/` syntax with optional flags `i`, `m`, `s`:

```ocaml
r/\d+/          -- one or more digits
r/foo/i         -- case-insensitive
r/^\w+/m        -- match at start of each line
```

```ocaml
Regex.match?      r/\d+/ "abc123"          -- true
Regex.capture     r/(\w+)@(\w+)/ "a@b"     -- ["a@b", "a", "b"]
Regex.replace     r/\d+/ "X" "a1b2"        -- "aXb2"
Regex.replace_all r/\d+/ "X" "a1b2"        -- "aXbX"
Regex.split       r/\s+/ "a  b   c"        -- ["a", "b", "c"]
Regex.match_all   r/\d+/ "a1b22c333"       -- ["1", "22", "333"]
```

`match_all` returns each match in order. The matches do not overlap. Use it
with an alternation pattern to make a simple tokenizer:

```ocaml
Regex.match_all r/[a-zA-Z_]\w*|[{}=,]|"[^"]*"|\d+/ "block{x=\"1\"}"
-- ["block", "{", "x", "=", "\"1\"", "}"]
```

Compile a pattern during the run, for example a pattern from the user:

```ocaml
match Regex.compile pattern with
| Ok re  -> Regex.match? re input
| Error e -> false
```

---

## Errors and `try`

An operation that can fail returns a `Result`. Its `!` sibling raises
instead. `try` runs an expression and turns a raise back into a `Result`. So
you choose the place where raising code becomes a value again:

```ocaml
try (FS.read_file! ./config.toml)   -- Result String String
try (1 + 1)                          -- Ok(2)
```

The error holds the message from the raise, and no source position. It says
what went wrong, not where.

`try` is the only form that captures a raise. It is a fixed handler over the
machinery that `handle` opens up.

---

## Effects

A signature says what a function does to the machine. It does not stop at
what the function does to its arguments. The effects come after `!`:

```ocaml
FS.read_file!   Path -> String ! {FS.Read, Raise}
FS.exists?      Path -> Bool ! {FS.Read}
Map.get!        String -> Map 'a -> 'a ! {Raise}
String.upper    String -> String
```

### What you write, and what you only read

| | |
|---|---|
| Effect labels — `{FS.Write, Shell}` | **Rarely written.** They are inferred from the builtins your code reaches, and a script normally writes none. Written, they are checked rather than assumed — see below. |
| Operation names — `FS!read_file` | **Written only in a handler case**, when intercepting that operation in a test. |
| Everything else | Ordinary wand. Effects follow from the builtins your code reaches. |

So writing a script means writing no effects at all. You read them back from
`wand t`, `wand d`, and the interactive session.

### Writing them down

A written type can carry effects. The printer emits four shapes, so a
signature from `wand t` pastes back as an annotation:

```ocaml
Unit -> String ! {Shell}          exactly these
Unit -> String ! {Shell | 'e}     at least Shell, plus whatever 'e is
'a -> 'a ! 'e                     a variable, and nothing known
Int -> Int                        nothing written: inferred, as usual
```

Only the innermost arrow of a curried type carries them. An inferred type
does the same. One argument of several does nothing until the last one
arrives.

wand **checks** written effects. It does not assume them. Declare fewer
effects than the body performs, and you get a type error. An annotation cannot
narrow what a function does:

```ocaml
let f : Unit -> String ! {Shell} = fn () -> $(git status)
-- type error: the type allows {Shell}, but the body performs Raise
```

Use this in one case: the type must say that the effects of one part are the
same as the effects of another part. To say that, name the same variable
twice. There is no other way. Inference cannot see a relationship that the
type does not mention. A field that holds a function is the case that needs
it. See
[A function kept in a field keeps its effects](#a-function-kept-in-a-field-keeps-its-effects).
Everywhere else, write no effects and let wand infer them.

### The labels

Nine, and a script cannot define more:

| Label | Means |
|---|---|
| `Clock` | waits; how long the call takes depends on wall-clock time |
| `Shell` | runs a subprocess — including anything reaching the network, since it does so through a command |
| `FS.Read` | reads from the filesystem |
| `FS.Write` | creates, changes or removes something on disk |
| `Env` | reads or changes environment variables |
| `IO` | reads or writes the program's own streams |
| `Proc` | ends the process; nothing catches this |
| `Random` | draws from entropy; will not answer the same twice unless the seed is pinned |
| `Raise` | can raise instead of returning |

A label answers one question: what can this touch? So a label is coarse. It
must fit in a signature, and you must be able to hold all nine in your
head.

### What earns a label

Three things justify one, and the nine divide between them:

| Justification | Labels |
|---|---|
| Reach — the call touches something outside the program | `Shell`, `FS.Read`, `FS.Write`, `Env`, `IO`, `Proc` |
| Non-determinism inside one run — two calls can disagree | `Clock`, `Random` |
| Control flow | `Raise` |

The third row is why `Raise` appears in a signature and never in a manifest.
See [`Raise` is not part of a manifest](#raise-is-not-part-of-a-manifest).

A call that fits none of the three carries no effect, however far outside the
language the value came from. `Proc.args` and `Proc.pid` are the cases:
argv and the pid are handed to the process before it starts and never
change. Reading either touches nothing, and two reads in a run cannot
disagree, so neither is an effect and neither belongs in a manifest — a
manifest that named them would bound nothing.

"Never changes" is the whole of it, and it is a claim about *this* run. The
environment fails it because `Env.set` exists, so `Env.get` stays an effect
even though a script may only ever read. A `Par` worker is a domain rather
than a second process, so `Proc.pid` holds across branches; were wand to
fork, it would not, and `pid` would earn a label under the second row.

### They are inferred, however deep

```ocaml
let fetch () = $(curl https://example.com)
let sync ()  = fetch ()

sync            -- Unit -> String ! {Raise, Shell}
```

Nothing above is annotated. `$()` runs a command, and it raises if the
command exits non-zero. So it carries `{Raise, Shell}`. `$?()` returns a
`ShellResult` instead, so it carries `{Shell}` only. `$NAME` reads the
environment, so it carries `{Env}`. In a string, write it `%{$NAME}`, because
a `$` in a string is text.

This holds through a function that calls itself, and around a group of
functions that call each other:

```ocaml
let countdown n =
  if n == 0 then () else let () = IO.println "%{n}" in countdown (n - 1)

countdown       -- Int -> Unit ! {IO}
```

### `try` and `handle` take effects away

`try` converts a raise into a `Result`, so `Raise` does not escape it:

```ocaml
fn () -> $(git status)          -- Unit -> String ! {Raise, Shell}
fn () -> try ($(git status))    -- Unit -> Result String String ! {Shell}
```

This is why an operation and its `!` sibling differ by one effect. The plain
one is `try` over the raising one:

```ocaml
FS.read_file!   Path -> String ! {FS.Read, Raise}
FS.read_file    Path -> Result String String ! {FS.Read}
```

A handler removes an effect when its cases cover **every operation that
effect carries**:

```ocaml
fn () -> handle (Proc.exit 1) with
         | Proc!exit _ k -> k 0        -- Unit -> 'a
```

`Proc` is gone. It carries one operation, so one case covers it. Nothing
left in the body can end the process.

Covering some of them is not enough:

```ocaml
fn () -> handle $(git push) with
         | Shell!run _ k -> k "ok"     -- Unit -> String ! {Raise, Shell}
```

`Shell` stays. It carries four operations: `run`, `run_quiet`, `capture` and
`exit_code`. The three that this handler does not name still reach the real
shell. A signature without `Shell` would describe a program that does not
exist.

[Effect handlers](#effect-handlers) lists each operation. That list groups
them by family, not by effect. The `FS!` operations belong to `FS.Read` and to
`FS.Write`. Cover every operation of one effect to discharge that effect.

`Raise` stays for the same reason, on a smaller scale. An effect set records
which effects happened, not which operation caused them. So wand cannot tell
the raise of `$()` from the raise of another call in the same body. To remove
one is to remove both.

Both cases err in the same direction. To keep an effect that cannot happen
is imprecise, and the manifest says so. To drop an effect that can happen is a
lie, and then the manifest means nothing. A handler that wants the effect gone
names each operation.

A case that names an operation which does not exist is a type error. The
error suggests the nearest real name. Without the check, a mock with a typo
intercepts nothing, and the real effect runs.

### A function kept in a field keeps its effects

A field can hold a function. The declaration does not say what that function
performs, because there is nowhere to write it:

```ocaml
type Action = Action (Unit -> String)

let a = Action (fn () -> $(git push))
let fire x = match x with | Action f -> f ()
```

wand takes the effects from the value that builds the field. So `fire`
performs `Shell`, and a file that calls it declares `Shell`. A named field
behaves the same way, through dot access or through a match.

A field can take a function and pass its effects on. To say so, name the
same variable twice. The effects of a written type are part of that type:

```ocaml
type Testing 'a 'b(
  raises: ((Unit -> 'b ! 'e) -> TestOutcome ! 'e),
  ...
)
```

A call to `t.raises` now performs what the thunk performs. A test whose
thunk runs a command declares `Shell`, like any other code. Without the `'e`
the two sides are unrelated, and the effects of the function stop at the
field.

### Effect variables

A function that passes effects through carries a variable, not a fixed set.
Write it `'e`. It ranges over effects, as `'a` ranges over types:

```ocaml
List.map   ('a -> 'b ! 'e) -> List 'a -> List 'b ! 'e
```

`List.map` performs what its function performs, and no more. Give it a shell
command and you get `{Raise, Shell}`. Give it arithmetic and you get
nothing.

An effect set can be partly known. `{Raise | 'e}` means "raises, and also
whatever `'e` becomes". The `|` separates what is known from the rest.

### What inference promises

A signature can name an effect that a function does not always perform. It
never leaves out one that the function does perform. Two calls in one body can
both have undetermined effects. They share the unknowns of the scope, so an
effect proved for one belongs to both. This is what makes a signature worth
reading. A missing effect is a lie. An extra effect is only imprecise.

---

## Manifests

A file may declare what it is allowed to do:

```ocaml
uses {FS.Write, Shell}
```

This is the one place where you write effect labels. The manifest goes
first, before everything but a shebang and comments. A reader sees the bound
without a search. A manifest that could be anywhere is worth no more than no
manifest.

A file without a manifest is unconstrained, so casual scripts pay nothing.

### Doing more than you declared is an error

wand checks the manifest against everything that the file defines. It does
not check only what a run performs. A function that runs a command still runs
it when another file imports it and calls it.

```console
$ wand t deploy.wand
Error: type error: 'publish' performs Shell, which the manifest does not allow.
       The manifest should be:  "uses {Shell(rsync), FS.Write}"
```

The error names the binding that introduced the effect. It also gives the
line to write, so you copy it instead of working it out. If every command word
in the file is literal, the suggested `Shell` names the binaries it saw. See
[Naming the binaries](#naming-the-binaries-shellgit-curl). If one word is not
literal, the suggestion is bare `Shell`.

### Declaring more than you use is a warning

```text
warning: 1:1: A-USES1: the manifest permits Shell, which this file does not
         use; it could be "uses {FS.Write}"
```

To permit more than you need is the safe direction. A build that failed here
would punish caution. So this stays advisory, and `--strict` leaves it
alone.

### Performing effects without saying so is a warning

```text
warning: 1:1: V-USES2: this file performs Shell, FS.Write and does not say
         so; it could declare "uses {Shell(rsync), FS.Write}"
```

A file without a manifest is legal, and it always will be. A casual script
must not pay for a feature that it did not ask for, so this never fails a
build. A manifest is worth writing only if it makes the file easier to read.
wand has already inferred the effects, so the linter gives you the exact line
instead of a note about its absence.

### `Raise` is not part of a manifest

A manifest bounds what a file can do to the machine. `Raise` is control
flow. A `!` name shows it, and so does each signature. To include it would put
`Raise` in almost every manifest, and it would say nothing about what a file
can reach.

### Naming the binaries: `Shell(git, curl)`

Bare `Shell` says that the file runs commands. It does not say which ones.
The manifest can narrow it to the binaries that the file may run:

```ocaml
uses {Shell(git, curl), FS.Write}
```

Write each name as it appears inside `$()`. `Shell(git, docker-compose,
node.js, g++, /opt/bin/deploy)` all work without quotes. Use quotes only for a
name that wand cannot lex as one name, such as `"7zip"` or a name with a
space. Bare `Shell` stays legal and means any binary. It is the honest
spelling for a script that is open-ended. `Shell()` is a parse error: a file
that runs nothing drops the label.

What is checked, and when:

- **`wand t` checks each literal command word.** A command word is the first
  word of a `$()` or a `$?()`. It is also the first word after a top-level
  `|`, `&&`, `||` or `;`. A word that the list omits is a type error. The
  error names the word and the manifest line that admits it. wand skips a prefix
  assignment, so `$(FOO=1 git status)` checks `git`. It skips a redirection
  and its target. It honours quoting, so a `|` inside an argument separates
  nothing. A subshell `(...)`, a substitution `$(...)` and a backtick span
  are command positions of their own, wherever they appear.
  `$(echo $(whoami))` needs `whoami` in the list, as much as it needs
  `echo`. `$((...))` is arithmetic. The shell runs nothing there, so wand
  checks nothing.
- **A command word that the run decides** — `$(%!{cmd} ...)` — is checked
  at the spawn. wand checks the resolved command line against the same
  list. A miss raises, and you can catch it. Nothing spawns. The check
  lives in the default handler, so a test mock never trips it, and neither
  does a `--dry-run` rehearsal. `V-SHELL1` reports each such site. It is a
  warning, and an error under `--strict`, for a repository that wants each
  command word readable from the text.
- **A command runs to the end of its line.** A newline inside `$()` starts a
  second command, as it does in a shell script, so a command broken over two
  lines for width runs as two. End the line with `\` to continue it, which
  is what a shell reads too. `V-SHELL2` reports the break, and `wand t --fix`
  writes the `\`.
- **You cannot narrow shell control flow.** A reserved word in command
  position is a type error under a narrowed manifest, as in
  `$(for f in *; do ...; done)`. Neither check can bound what the body runs.
  The message tells you to write the loop in wand, or to declare bare
  `Shell`.

What counts as the binary:

- **A wrapper is the thing you allow.** wand checks `env`, `xargs`,
  `sudo`, `sh -c` and `time` as themselves. It never looks past them. To
  allow `sh` is to allow anything, and the manifest shows that. That is the
  point.
- **An entry without a slash matches the word's final path component**
  (`git` admits `/usr/bin/git`); an entry with a slash matches exactly.
- **The bound is per file.** The manifest of a file governs the `$()` sites
  written in that file, however far a closure travels. The commands of an
  imported helper answer to the first line of the helper. A manifest is an
  audit surface against drift and accident. It is not a sandbox. Hostile
  code writes `Shell(sh)`, where you can see it.

`wand t` suggests the narrowed form when every command position in the file
is literal: `it could declare "uses {Shell(git, curl)}"`. If one position is
not literal, it suggests bare `Shell`. A listed binary that no command runs is
an `A-USES1` warning, with the trimmed line. wand judges that only in a file
where every position is literal. An interpolated site may be the place where
the unused binary runs.

The two checks cover every command that a script can express. `$()` and
`$?()` are the only spawn forms in the scope of a script. The raw process
builtins are reachable only from the module bodies of the standard library.
The `Shell` module parses output. It runs nothing.

---

## Effect handlers

`handle` intercepts the effects that an expression performs. Use it for
tests, and at a boundary. The most useful case is a script that runs commands
or writes files: `handle` runs it and lets it touch nothing:

```ocaml
test "deploy pushes once" (fn t ->
  let outcome =
    handle deploy () with
    | Shell!run _ k -> k "mocked output"
  in t.eq outcome "done")
```

A case names the operation that it intercepts. The name is the call you
would make, with a `!` in place of the dot. You call `FS.read_file`. You
intercept `FS!read_file`:

```ocaml
| FS!read_file path k   -> k "fake contents"
| Shell!run cmd k       -> k "mocked output"
| Env!get name k        -> k "value"
| IO!println text k     -> k ()
```

The part before the `!` is the effect family, which is why `$()` is
`Shell!run` even though there is no `Shell` module: families are the same
words that appear in a signature's effect set.

Several functions can share one operation. `FS.read_file` and
`FS.read_file!` both perform `FS!read_file`, so a test mocks reading a file
once rather than once per wrapper.

A name that is not an operation is a type error, with the nearest real one
suggested. A mistyped case would otherwise intercept nothing, and the effect
it was written to hold back would run for real.

To intercept an operation is not to remove its effect from the signature.
The mock above still reports `Shell`. It does not cover `Shell!run_quiet`,
`Shell!capture` or `Shell!exit_code`, and those three would reach the real
shell. [`try` and `handle` take effects away](#try-and-handle-take-effects-away)
says what a handler must cover to drop an effect.

A case binds two things: the argument of the operation, and a continuation
`k`. Call `k` with a value, and the intercepted code continues with it. wand
checks both against the operation. So a case cannot read a path as a `String`,
and it cannot resume a read with an `Int`:

```ocaml
| FS!write_file (path, _) k -> path ++ "!" ++ k ()
-- expected String, got Path

| FS!read_file _ k -> k 42
-- expected String, got Int
```

`Shell!run` and `Shell!capture` are the exception. Each one carries a
command, or a command and the stdin for it. There is no single payload type to
check a case against, so wand leaves these two open.

A `return` case transforms the result when the body finishes normally:

```ocaml
handle
  let () = FS.write_file! /etc/hosts "..." in
  "done"
with
| FS!write_file (path, _) k -> k ()
| return s -> s
```

A case that answers on its own, without resuming, writes `_` for the
continuation:

```ocaml
| Shell!run _ _ -> "mocked"
```

The intercepted code stops there, and it gives back what it holds. A `with`
inside it releases on the way out. So a mock cannot leak the resources of the
code that it replaces.

The operations you can intercept are the builtins that touch the world
outside. Each name has the form `Family!verb`. The family is the one that
appears in an effect set:

| Family | Operations |
|---|---|
| `Shell` | `run`, `run_quiet`, `capture`, `exit_code` |
| `FS` | `read_file`, `stream_lines`, `hash_file`, `write_file`, `append`, `create_file`, `delete`, `delete_tree`, `copy`, `copy_tree`, `rename`, `mkdir`, `list_dir`, `glob`, `exists`, `file`, `dir`, `size`, `mtime`, `cwd`, `temp_file`, `temp_dir` |
| `Env` | `get`, `set`, `clear`, `all`, `home`, `user`, `parse_dotenv` |
| `IO` | `print`, `println`, `print_err`, `println_err`, `read_line`, `read_all`, `flush`, `stdin_lines` |
| `Proc` | `exit` |
| `Clock` | `sleep`, `now`, `elapsed` |
| `Random` | `below`, `float`, `seed` |

Type `FS!` in an editor, and it lists them. Each entry says what the
operation carries and what performs it. The editor reads the table that the
typechecker reads. Nothing performs `Shell!run_quiet` or `Shell!exit_code`. A
case for either one is legal, and it never fires.

There is no `perform` keyword. A script cannot define an effect operation.
It can only intercept a built-in one.

Use `handle` at a boundary: to mock in a test, to audit what another module
attempts, or to retry. `try` and `Result` handle errors. `handle` is not a
control-flow form.

### What a handler discharges

An effect leaves the signature — and the manifest — only when **every**
operation carrying it is handled. A case intercepts one operation, and a
label covers several:

```ocaml
handle $(git push) with
| Shell!run _ k -> k "ok"          -- Shell stays: capture and exit_code still run
```

Erring this way over-reports. Erring the other way is what let a file whose
manifest was `uses {IO}` run any command it liked.

Handle all of them and the effect is gone, including when the body arrives
as a parameter — which is how a handler worth reusing is written:

```ocaml
let safely thunk =
  handle thunk () with
  | Proc!exit _ k -> k 0

-- safely : (Unit -> 'a ! {Proc | 'e}) -> 'a ! 'e
```

The argument asks for a thunk that *may* exit and answers one that cannot,
so the file needs no `Proc` in its manifest. Asking for the effect does not
turn a thunk that never performs it away: `safely (fn () -> 42)` typechecks,
for the same reason `Par.timeout 1s (fn () -> 42)` does.

A demand is not a deed. An effect that appears only on an argument's arrow
is something the caller may bring, so it does not reach the file's manifest.
An effect the file performs lands on an arrow the file returns, and those
always count.

---

## Resource brackets

You must give some things back: a temp file, a lock, a directory that you
changed into. `with` acquires one, binds it, runs a body, and releases it:

```ocaml
with FS.temp_file "build_" ".tar" as archive ->
  let () = FS.write_file! archive contents in
  publish! archive
```

**A `with` always releases, however the script ends.** It releases when the
script returns, when it raises, and when it calls `Proc.exit`. It releases when
a handler answers without resuming. It releases on Ctrl-C and on a `kill`.
There is no `defer`, no `trap`, and nothing to remember at each exit.

There is one exception: a process that is destroyed, not stopped. `kill -9`
and a power loss take the program away. It runs nothing on the way out.
Nothing can cover that.

`Proc.exit n` still exits with `n`. It releases first, then stops. An
interrupt exits 130. A `kill` exits 143. A reader that closes the output of
the script, as in `wand report.wand | head -3`, ends it with 141. A shell
reports the same codes, so nothing downstream learns a code that only wand
uses. A closed reader stops the script as the other two do. The brackets
around it release first.

Brackets nest, and release innermost-first:

```ocaml
with FS.temp_file "wand_" ".txt" as scratch ->
with FS.temp_file "wand_" ".log" as log ->
  ...
```

### A resource is a description

`FS.temp_file "wand_" ".txt"` creates no file. It describes how to create
one and how to remove it. So you can name it, pass it to a function, and use
it more than once. Each `with` acquires again:

```ocaml
let scratch = FS.temp_file "wand_" ".txt"

let first  = with scratch as p -> Path.to_string p
let second = with scratch as p -> Path.to_string p   -- a different file
```

Build your own with `Resource.make`. Give the two halves in one place, so
they cannot drift apart:

```ocaml
import Resource

let table name =
  let acquire = fn () -> let () = create_table! name in name in
  let release = fn n -> drop_table! n in
  Resource.make acquire release
```

### A bracket does not hide what it costs

The effects of the acquire and the release are part of the type of the
resource. `with` folds them into the signature around it. A body that does
nothing still reports what it costs to hold the resource:

```ocaml
let f () = with FS.temp_file "wand_" ".txt" as _ -> 1
-- f : Unit -> Int ! {FS.Read, FS.Write, Raise}
```

A bracket makes sure that the release runs. It does not hide the file from
the signature.

---

## Decoders

Data from outside a script has no type: a JSON document, a config file, the
output of a command. A `Decoder a` says how to read an `a` out of it:

```ocaml
import Decode
import JSON

let pod =
  (Decode.map2 (fn n r -> Pod (name = n, restarts = r))
     (Decode.field "name" Decode.string)
     (Decode.field "restarts" Decode.int))

JSON.decode pod (JSON.parse! out)   -- Result String Pod
```

A decoder is a value. To name one reads nothing. You can run the same
decoder against several documents.

### Failure names the field

```text
.items[3].metadata.name: expected String, got Int
.spec.replicas: no such field
```

The path is the point. Read fields one at a time, and a wrong name gives you
a null. The run continues and fails later, somewhere else. A decoder stops at
the field that was wrong, and it names that field.

### The combinators

```ocaml
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

`map2` covers a record with two fields. For a wider record, chain through
`and_then`. Validation also goes there:

```ocaml
let pod =
  (Decode.and_then (fn n ->
     Decode.and_then (fn r ->
       if r < 0 then Decode.fail "restarts cannot be negative"
       else Decode.succeed (Pod (name = n, restarts = r)))
       (Decode.field "restarts" Decode.int))
     (Decode.field "name" Decode.string))
```

If no alternative works, `one_of` reports the complaint of each one. The
decoder does not guess which one you meant.

### A field that may not be there

`Decode.optional` reads a field as an `Option`. A field that is absent, or
written as null, is `None`:

```ocaml
Decode.optional "restarts" Decode.int    -- Decoder (Option Int)

{"restarts": 4}      -- Ok (Some 4)
{}                   -- Ok None
{"restarts": null}   -- Ok None
{"restarts": "many"} -- Error .restarts: expected Int, got "many"
```

The last line is the point. `optional` says that the field can be missing.
It does not say that the contents can be anything. A field that is there and
does not decode is a failure, as it is under `field`. The obvious substitute,
`one_of [field name inner, succeed None]`, gets this wrong. It turns a renamed
field or a retyped field into `None`, as readily as a missing one. That is the
silent null that this layer replaces.

### Keys that are data, and values that are null

`Decode.field` needs a name that the program knows in advance. Sometimes the
keys are the data, as in a label map or a count for each host. Then
`Decode.dict` reads the object into a `Map`. A failure names the key it was
under:

```ocaml
{"web-01": 3, "db-01": 12}   Decode.dict Decode.int   -- Ok (Map of 2)
{"a": 1, "b": "x"}           Decode.dict Decode.int   -- Error .b: expected Int, got "x"
```

`Decode.nullable` is the sibling of `optional`, one level down. `optional`
asks whether a field is there. Only a lookup can ask that. `nullable` asks
whether a value is null. An element of a list raises that question:

```ocaml
[1, null, 3]   Decode.list (Decode.nullable Decode.int)   -- Ok [Some 1, None, Some 3]
```

### Domain literals decode as themselves

```ocaml
Decode.path  Decode.duration  Decode.url   Decode.size  Decode.version
Decode.datetime  Decode.ipv4  Decode.cidr  Decode.port
```

`"30s"` in a document lexes as `30s` in a script. So the boundary gives you
the type that the rest of the program uses. You do not convert a `String`
later. Each of the twelve domain types has a decoder.

Each decoder reads what the source could hold, and nothing that the source
would refuse. The same lexer decides both. `port` shows this best. A script
writes `:8080`, and a document usually holds the bare number. `8080`, `"8080"`
and `":8080"` all read. A port is 0 to 65535, so `65536` and `-1` do not. The
failure gives the rule, not only the refusal:

```text
.port: invalid port :65536: must be 0-65535
```

That sentence comes from the lexer. The lexer is the only place that knows
it. `String.to_port` and `String.to_ipv4` report it the same way, and
`String.to_port` accepts the same two spellings.

### Text is read, never written

A backend that carries types gives an `Int` as an `Int`. A backend without
types gives the text, as a CSV cell does, or a line of output. Then
`Decode.int` reads it as `String.to_int` reads it. So one decoder serves a
document and the output of a command:

```ocaml
{"restarts": 4}     Decode.int   -- Ok 4
{"restarts": "4"}   Decode.int   -- Ok 4
```

The reverse never happens. `Decode.string` does not take a number and make a
string of it. A `string` that accepts anything is the scrape that this layer
replaces:

```ocaml
{"restarts": 4}     Decode.string   -- Error .restarts: expected String, got Int
```

### Running one

Each backend presents what it read in the same shape. So the combinators
above are the whole surface. Only the source of the data changes:

```ocaml
JSON.decode  : Decoder 'a -> JSON   -> Result String 'a
TOML.decode  : Decoder 'a -> TOML   -> Result String 'a
CSV.rows     : Decoder 'a -> String -> Result String (List 'a)
Shell.decode : Decoder 'a -> String -> Result String 'a
Shell.lines  : Decoder 'a -> String -> Result String (List 'a)
```

The first row of a CSV names its columns. So you read a row by field name,
as you read any record. Use `CSV.parse` for a file with no header row. For
`Shell.lines`, `$()` removes the trailing newline. So a capture with nothing in
it gives no lines, not one empty line.

A backend that reads one record per row, or per line, first says which
record failed. Then it says what was wrong:

```text
[2].restarts: expected Int, got "many"
```

### A type is its own decoder

A type with one constructor and named fields already says what its decoder
does. So it has one:

```ocaml
type Pod (name : String, restarts : Int, timeout : Duration)

JSON.decode Pod.decoder (JSON.parse! out)   -- Result String Pod
```

`Pod.decoder : Decoder Pod` reads each field by its own name. Add a field to
the type, and the decoder reads it. There is no second copy to keep in
step.

A field whose type is an `Option` can be absent. Every other field must be
there. The type already says this:

```ocaml
type Job (name : String, owner : Option String)

{"name": "build"}                  -- Ok (Job (name = "build", owner = None))
{"name": "build", "owner": 3}      -- Error .owner: expected String, got Int
```

Fields may hold lists, other derivable types, and the type being defined:

```ocaml
type Node (label : String, children : List Node)
```

A type with parameters takes one decoder for each parameter, in the order
that the type declares them:

```ocaml
type Paged 'a (items : List 'a, total : Int)

Paged.decoder : Decoder 'a -> Decoder (Paged 'a)
Paged.encoder : ('a -> JSON) -> Paged 'a -> JSON

JSON.decode (Paged.decoder Pod.decoder) doc
```

Derivation covers a flat record whose keys are its field names. Write a
decoder by hand for a document with nested keys, with other names, or with
values to validate. Derivation removes the dull decoders, not the interesting
ones. The two mix freely:

```ocaml
Decode.field "items" (Decode.list Pod.decoder)
```

There is a worked example of each in `examples/`:

| | |
|---|---|
| `decode-renamed-keys.wand` | the document's keys are not the type's field names |
| `decode-nested-fields.wand` | the value is nested deeper than the type — mirror the shape, or reach through it |
| `decode-tagged-union.wand` | a `kind` field says which constructor to build |

`T.encoder` comes from the same fields. A type states its shape once, and
both directions follow.

`T.usage` and `T.parser` come from the same fields. They describe the
command line that reads the type. Neither takes an argument for a type
parameter.

```ocaml
type Opts(host : String, port : Port = :8080, verbose : Bool = false)

Opts.usage         -- "--host <String> [--port :8080] [--verbose]"
Opts.parser        -- CommandLine Opts
Opts.parser.spec   -- {verbose = "switch"}
```

`T.parser` holds the three things reading a command line takes: `spec`,
`reader` and `usage`. `CommandLine` is a built-in type, so a file may take
one apart and may build one.

Until 0.49.0 `spec` and `reader` were members of their own, and `Args.read`
took them side by side. Nothing said that they had to come from one type,
so one type's account of its flags could meet another type's reader, and
the run reported it as a fault in the arguments. They arrive together now.
Naming either says what to write instead.

`T.usage` prints one flag for each field. A field with a default prints in
brackets and shows the default. An `Option` field prints in brackets and
shows what the flag takes. A `Bool` field prints as a switch with no value
after it. A `Bool` field always prints in brackets, because an absent one
reads as `false`. Every other field is required and shows its type.

`T.parser.reader` is the decoder that reads a command line. `T.decoder`
reads a document. For a type that is all flags, the two are the same.

A type can also describe a whole command line. Such a type has two fields.
One field has a record type and holds the flags. The other field does not
have a record type. It holds what was written without a flag. The reader
maps both fields onto the flat object that `Args` builds.

```ocaml
type Flags(port : Port = :8080, verbose : Bool = false)
type Opts(flags : Flags, host : String)

Args.read Opts.parser (Proc.args ())
Opts.usage   -- "[--port :8080] [--verbose] <host>"
```

`usage` stays a member of its own as well, because `--help` is answered
before a command line is read. Nothing about that line is about parsing.

The types decide which field is which. The names do not. Call both fields
what you like.

The argument field's type says how many arguments there may be. The reader
refuses any other number. The message names the field.

| the field | arguments | usage |
|---|---|---|
| `host : String` | exactly one | `<host>` |
| `host : Option String` | one or none | `[<host>]` |
| `paths : List Path` | any number | `<paths>...` |

The reader reads each argument as its own type. An argument field of type
`Port` refuses `nope` at once.

Two shapes have no reading. The first has two record fields. The second has
no field left for the arguments. The error names the fields that made the
shape ambiguous.

`T.parser.spec` states what the text of a flag cannot state. A `Bool` field is a
`"switch"` and takes no value. A `List` field is `"repeated"` and collects
values instead of replacing them. A field that needs neither statement is
left out. The map is empty when every flag takes one value.

A type with more than one constructor has neither. Name one, and the error
says which:

```ocaml
type Shape = Circle Int | Rect Int Int
Shape.decoder
-- type 'Shape' has no derived decoder: it has more than one constructor
```

### Writing it back out

The same type gives an encoder. It is an ordinary function, not a type of
its own. Encoding cannot fail, so there is nothing to carry:

```ocaml
Pod.encoder : Pod -> JSON

JSON.stringify (Pod.encoder p)
JSON.of_list (List.map Pod.encoder ps)
```

So a script can read a document, change one thing, and write back what it
read:

```ocaml
{"name": "api", "port": 8080, "timeout": "30s", "replicas": 2}   -- in
{"name":"api","port":8080,"timeout":"30s","replicas":4}          -- out
```

A field that holds `None` is left out. It is not written as null. Both read
back as `None`, and a config file is tidier without the empty keys.

### Decoding is pure

The functions that build a decoder carry the empty effect set. So a decoder
cannot read a file, and it cannot run a command. The caller gets the data, and
the signature of the caller says so.

```ocaml
Decode.map2 (fn a b -> let _ = $(echo hi) in a) Decode.int Decode.int
-- type error: the parameter allows {}, but the function given performs
--   Raise, Shell
```

---

## Contracts

A function body can state preconditions and postconditions. wand checks them
during the run. In a postcondition, `result` is bound to the return value:

```ocaml
let half n =
  requires n % 2 == 0
  ensures result * 2 == n
  n / 2
```

A violated contract raises, reporting the clause that failed:

```ocaml
half 7   -- precondition failed: ((n % 2) == 0)
```

Contracts come after the `=` and before the body. You can write several of
each. A broken contract is a bug, not an operation that failed. So state what
must be true. For input that you expect to be wrong, validate it and return a
`Result`.

---

## Typed holes

`?` stands for an expression that you have not written yet. A program with a
hole typechecks, and it does not run. `wand t` and `wand e` report the type
that belongs there:

```console
$ wand t --expr 'List.fold_left ? 0 [1, 2, 3]'
Hole: Int -> Int -> Int ! 'e
```

wand infers the hole from the way you use it. So the type system gives you
the signature to write. It does not only report what is wrong. Use a hole to
sketch a solution and to ask what fills it.

---

## Type definitions

Each type that a definition names must exist. The order of declarations does
not matter. wand collects the types of a file before it reads any of them. So
a field can name a type from further down, and two types can name each
other:

```ocaml
type Pod  = Pod (metadata : Meta, status : Status)
type Meta = Meta (name : String, namespace : String)
type Status = Running | Pending
```

A name that nothing declares is an error. It is not a type of its own:

```ocaml
type Pod = Pod (metadata : Meta, status : Statsu)
-- type error: unknown type 'Statsu' in field 'status' of 'Pod'
--   (did you mean 'Status'?)
```

A type belongs to the module that declares it. Reach it through that module,
or name it in the import:

```ocaml
import Test
type Run = Run (outcome : Test.TestOutcome)

let {TestOutcome} = import Test
type Run = Run (outcome : TestOutcome)
```

A constructor is reached the same way: `Test.Pass "x"`, or `Pass "x"` after
naming `Pass` in the import. This holds in a pattern too.

Two modules may each declare a type called `Status`. They declare two types.
A file that imports both writes `one.Status` and `two.Status`, and mixing
them is an error that says which is which.

Built-in types are not from a module and need no import: `List`, `Map`,
`Result`, `Option` and the domain types are always in scope.

### Enum-style (no payload)

```ocaml
type Direction = North | South | East | West

let describe d = match d with
| North -> "up"
| South -> "down"
| East  -> "right"
| West  -> "left"
```

### Another name for a type

`type X = <a type>` is an alias: another name for a type that already
exists, rather than a new one.

```ocaml
type Point = (Int, Int)
type Ids   = List Int
type Name  = String
type F     = Int -> Int
type This  = That            -- That declared elsewhere
```

An alias is transparent — the two are one type, interchangeable in both
directions — so it buys a name to read and write, not a distinct type.
Nothing stops a `(width, height)` where a `Point` is meant. For a type the
checker keeps apart, declare a record: `type Point (x : Int, y : Int)`.

A type shows with the alias it was written as, so the name in the source is
the name in the message:

```ocaml
let p : Point = (1, 2)       -- p : Point (= (Int, Int))
```

An alias declares nothing at run time. It also declares no constructor of its
own, but it names whatever its target names. A type with one constructor
names that constructor, so an alias to one builds and matches:

```ocaml
type Conf(port : Port = :8080)
type MyConf = Conf

MyConf(port = :90)                       -- a Conf
match c with | MyConf(port = p) -> p     -- matches one
```

A type with several constructors has no single one to name, so an alias to
one is not a value:

```ocaml
type Shape = Circle Int | Rect Int Int
type S = Shape

S
-- 'S' is a type, not a value
```

An alias takes parameters like any other type, and they are bound to the
arguments at the use site:

```ocaml
type Pair 'a   = ('a, 'a)
type Many 'a   = List 'a
type Either 'a 'b = ('a, 'b)

let p : Pair Int = (1, 2)          -- p : Pair Int (= (Int, Int))
```

Applying one with the wrong number of arguments says so, and an alias's own
`'a` is its own — applying it twice in a definition does not tie the two
uses together.

Whether a lone name after `=` is a constructor or a type is settled after
every declaration has been read. `type Colour = Red` is a variant when no
`Red` type exists and an alias when one does, and a constructor saying its
own type's name — `type Wrap 'a = Wrap 'a` — is always the wrapper form.

### Variants with payloads

```ocaml
type Shape = Circle Int | Rect Int Int

let area s = match s with
| Circle r   -> r * r * 3
| Rect w h   -> w * h
```

Separate positional fields with a space. `Rect Int Int` is two `Int` fields.
Constructor application and function application work the same way, as in
`f x y`. Use parentheses to group the type of one field that needs its own
structure. Do not use them to list several fields:

Parentheses group a tuple. Write several arguments one after the other:
`Rect 3 4`, not `Rect (3, 4)`. So `Some (1, 2)` is `Some` applied to one pair,
in every file.

```ocaml
type Wrap = Wrap (List Int)     -- one field, type List Int
type Pair = Pair (Int, Int)     -- one field, tuple type (Int, Int)
```

That rule holds for a constructor with no fields too, so parentheses right
after one are read as a payload it cannot take. Bracket the constructor
where it is not the last argument:

```ocaml
t.eq (None) (usage row)     -- t.eq None (usage row) is t.eq (None (usage row))
```

`wand f` writes that bracket for you, and the checker names the constructor
when it is missing.

### Named fields

A field can have a name instead of a position. You then give it and read it
by name. A type with one constructor has a shorthand:
`type Point (x : Int, y : Int)` means `type Point = Point (x : Int, y : Int)`.
The shorthand is the canonical form. If the one constructor has the name of
the type, `wand f` writes the long spelling back to the short one.

The type of a named field can be an application, as in `children : List
Node` and `owner : Option String`. Write it without parentheses. A positional
field cannot do this: `Pair Int Int` is two fields, not one type applied to
another.

```ocaml
type Point  (x : Int, y : Int)
type Circle (radius : Int)

let p = Point  (x = 3, y = 4)
let c = Circle (radius = 5)

p.x        -- 3
c.radius   -- 5
```

#### Construction

Name each field, in any order. Give every one of them:

```ocaml
Point (x = 1, y = 2)
Point (y = 2, x = 1)    -- same thing

Point (x = 1)
-- type error: constructor 'Point' is missing field 'y'
```

#### Defaults

A field may declare what it holds when a construction leaves it out:

```ocaml
type Conf(host : String, port : Port = :8080, retries : Int = 3)

Conf(host = "example.com")     -- port :8080, retries 3
Conf(host = "x", port = :9000) -- retries 3
```

A field with no default is still required. Leaving one out is the same type
error as before. Where every field has a default, `Conf()` builds a value
from them.

A default is a value written out. Write a literal, or a constructor applied
to literals. wand reads a default with nothing in scope. A default therefore
holds the same value at every construction that omits the field. It performs
no effect, so a construction declares none. It also prints back as written.
`port : Port = pick ()` is a type error that says this.

A derived decoder reads defaults too. A field that the document does not
carry takes its default. A field that the document carries wins:

```ocaml
JSON.decode Conf.decoder (JSON.parse! `{"host": "a"}`)
-- Ok(Conf("a", :8080, 3))
```

A document writes null where the language has nothing. `Decode.optional`
reads absent and null alike. A default answers for both.

Two types answer for themselves when a document does not carry the key. An
`Option` field reads as `None`. A `Bool` field reads as `false`. Those are
the two types with a word for absent. A default is not needed for either.

Every other field is required. A document without one is an error that names
the field.

A default and an `Option` state different things. They compose. `Option` is
about the value: the value may be nothing. A default is about the writing:
the field may be left out. So `tag : Option String = Some("none")` is a field
you can omit. Omitting it gives `Some("none")`, not `None`.

#### Puns

A field puns when a name of the same spelling already holds its value. A
pattern puns the same way:

```ocaml
let x = 1
let y = 2

Point(x, y)             -- Point(x = 1, y = 2)
Point(x = 8, y)         -- Point(x = 8, y = 2)
```

A pun does not reach one place. A bare name written *before* a named field
is the base of an update. That spelling meant an update first. Write
`Point(y = 9, x)` when you want both a change and a pun. A name that is not
the record gets an error that says so:

```ocaml
let x = 1
Point(x, y = 9)
-- type error: expected Point, got Int -- 'x' here is the record being
--   updated, not a field. Write 'Point(y = ..., x)' to pun it
```

One field alone does not pun either. `B(n)` is the constructor applied to
`n`, whichever way `B` is declared, so there is nothing for the declaration
to settle. Write `B(n = n)`.

`wand f` writes a construction's puns all or none: every field puns, or every
field carries its name. Both spellings that a mixed one can be read as -- the
update above, and the payload here -- are why. A pattern is not written under
that rule, because it has no update form to be confused with.

#### Update

A record with the same values but for the fields you name. Put the record
first, then what changes:

```ocaml
let p = Point (x = 1, y = 2)

Point (p, y = 9)          -- Point (x = 1, y = 9)
Point (p, x = 8, y = 9)   -- Point (x = 8, y = 9)
```

The type is named, as it is in a construction. A field not named keeps the
value the record holds. Naming a field twice is a type error.

Braces are a map, so `{p with y = 9}` is a parse error. It answers with
this form, carrying the names you wrote: `T(p, y = ...)`.

#### Pattern matching on named fields

A pattern can name fewer fields than the type has. Name a field to read
it:

```ocaml
let magnitude p =
  match p with
  | Point (x = a, y = b) -> a * a + b * b

let area c =
  let Circle (radius = r) = c in
  r * r

let just_x p = match p with | Point (x = a) -> a
```

A field puns when its name is the name you want for it. A map pattern puns
the same way. `Pod(name, restarts)` binds `name` and `restarts` to those two
fields:

```ocaml
type Pod(name : String, restarts : Int)

let summary p = match p with | Pod(name, restarts) -> "%{name}: %{restarts}"
```

A pun mixes with a field that carries a pattern, in any order. So
`Pod(name, restarts = 0)` matches a pod that has never restarted. It also
binds the name. A name that is not one of the constructor's fields is a type
error. The error names the constructor and the field.

One name alone is the exception, on this side as on the other: `Pod(name)` is
the payload bound to `name`, not the field. Write `Pod(name = name)`, which is
what `wand f` writes.

The same spelling means the tuple on a constructor whose payload is a tuple.
That reading has not changed:

```ocaml
type Span (Int, Int)

let width s = match s with | Span(a, b) -> b - a
```

A construction reads its bare names the same way. The declaration decides
which of the two readings a pattern has. The spelling does not decide it, so
the space in `Pod (name, restarts)` decides nothing.

A single name is a payload under either reading. `Wrap(v)` binds what `Wrap`
holds. A declaration has nothing to settle there.

#### Named fields in a type with several constructors

Named fields are not limited to the single-constructor form:

```ocaml
type Node = Leaf (value : Int) | Branch (left : Node, right : Node)
```

Construction and matching work as above. Dot access is narrower. A value of
`Node` is a `Leaf` or a `Branch`, and the access does not know which one. So
you can read a field only when every constructor carries it, at the same
type.

```ocaml
type Sized = Small (x : Int, u : Int) | Large (x : Int, w : Int)

(Large (x = 7, w = 9)).x     -- 7, every constructor has x
```

```ocaml
type Mixed = Counted (x : Int) | Named (y : String)

let v = Named (y = "hi")
v.x
-- type error: field 'x' is not on every constructor of 'Mixed': Named does
--   not have it, so which constructor a value holds decides whether 'x' is
--   there. Match on the constructor instead
```

Match on the constructor to read a field only some of them have.

A pattern that names one constructor of several can fail. A binding that
uses one says so. Over `Circle | Square`, `let area (Circle (radius = r)) = r`
has the type `Shape -> Int ! {Raise}`, and the name wants a `!`. What decides
this is whether the value could be another constructor. Whether the fields
have names does not matter. A type with one constructor has nothing to
mismatch, so the same binding is total. A `let` reads the same way:
`let Ok v = r in ...` raises where it stands.

---

## Generics

A type definition can take type parameters. Write each one with a leading
quote: `'a`, `'b`. `:t` already prints inferred polymorphic types this way:

```ocaml
type Maybe 'a = Nothing | Just 'a

let describe m = match m with
| Just v  -> "got a value"
| Nothing -> "empty"
```

Separate several parameters with a space. Positional constructor fields work
the same way:

```ocaml
type Pair 'a 'b = Pair 'a 'b
```

Type variables can also appear in ordinary annotations:

```ocaml
let identity : 'a -> 'a = fn x -> x
```

A variable there is a promise: the function works for any type. wand checks
it as it checks the rest of the annotation. Name a variable that the body
cannot keep, and you get a type error. This holds in both directions:

```ocaml
let f : 'a -> 'a = fn x -> x + 1
-- type error: the annotation says 'a, which stands for any type, but the
--   body works only for Int

let g : 'a -> 'b = fn x -> x
-- type error: the annotation says 'b and 'a are separate types, but the
--   body makes them the same
```

An annotation narrower than the body is still correct. `Int -> Int` over the
identity function names no variable, so it promises nothing.

`Option` comes with the standard library. See "Imports" below. The error
type of `Result` is a real type parameter. It is not fixed to `String`. The
common case, `Error "message"`, still infers as `Result String T`. An error
type of your own works the same way:

```ocaml
type ParseError = UnexpectedToken String | UnexpectedEof

let parse s : Result ParseError Int =
  if s == "" then Error UnexpectedEof
  else match String.to_int s with
  | Ok n    -> Ok n
  | Error _ -> Error (UnexpectedToken s)
```

---

## Type inference and unification

wand uses Hindley-Milner type inference. It infers types without an
annotation. The type checker compares the constraints of the whole
expression.

```ocaml
let identity x = x
identity 42        -- inferred: Int -> Int at this call
identity "hello"   -- inferred: String -> String at this call
```

The type checker catches mismatches:

```ocaml
let add x y = x + y
add 1 "hello"      -- Error: expected Int, got String
```

Types flow through pipelines:

```ocaml
let double x = x * 2
[1, 2, 3] |> List.map double
-- List.map inferred as (Int -> Int) -> List Int -> List Int
```

Recursive types are inferred:

```ocaml
let length []      = 0
let length [_ : t] = 1 + length t
-- inferred: List 'a -> Int
```

Constructor types are checked at construction and match sites:

```ocaml
type Wrap = Wrap Int

Wrap 42        -- ok
Wrap "hello"   -- Error: expected Int, got String

match Wrap 42 with
| Wrap n -> n * 2   -- n inferred as Int
```

---

## Type annotations

You can write any type that the checker infers or prints:

```ocaml
let x : Int = 42

let xs : List Int = [1, 2, 3]

let pair : (Int, Bool) = (1, true)

let f : Int -> Int = fn x -> x + 1
```

Grouping and nesting work the same way in an annotation as in a printed
type:

```ocaml
let g : (Int -> Int) -> Int = fn f -> f 1        -- parens needed for left-nesting
let m : Map (List Int) = {a = [1, 2], b = [3]}   -- parens needed for a compound argument
```

`:t` prints a type in this syntax. So you can paste what you see into an
annotation. This includes the constraints `Num`, `Add` and `Ord`. Each
written `Num` is a new "`Int` or `Float`" variable, and the use sites link
them. `let square : Num -> Num = fn x -> x * x` rebuilds what `:t square`
printed.

### A type on a parameter

A parameter can carry its type, in parentheses:

```ocaml
let describe (p: Pod) = p.name

let f = fn (p: Pod) -> p.status.restarts
```

This is what lets a definition read a field off a parameter. Dot access
needs a named type. wand generalizes a definition before it sees any call,
so the type has to come from the definition, and there was nowhere to write
it:

```ocaml
let describe p = p.name
-- type error: 'p' needs its type before '.name' can be read:
--             write '(p: Pod)'
```

The message names the annotation to write. Where more than one declared
type has the field it names them all and asks which, and where the value is
not a plain name it says to bind it to one that carries its type.

A lambda written as an argument is the other case, and it needs no
annotation: the call itself says what the parameter is.

```ocaml
List.filter (fn p -> p.status.restarts > 5) pods

pods |> List.map (fn p -> p.name)
```

A call reads its arguments in written order, and a lambda's body waits
until the rest of them have been read. So `pods` has already said what `p`
is by the time `p.status.restarts` is looked up, whether it stands after
the lambda or arrives from a pipe. A parameter that nothing in the call
pins is still refused, and still takes an annotation.

The annotation works in each place a pattern does: a `let`, a `fn`, an arm
of a `match`, a `with ... as`, and inside a constructor's payload — which
is where a decoder's result lands:

```ocaml
match JSON.decode Pod.decoder doc with
| Ok (p: Pod) -> p.status.restarts
| Error why   -> 0
```

It also composes with the return annotation:

```ocaml
let describe (p: Pod) : String = p.name
```

The parentheses are part of the syntax. Cons is `::`, so the `:` inside
them is never anything but a type.

The annotation constrains inference; it does not replace it. A body that
contradicts the annotation is a type error, and so is a call that does.

A type variable is refused here:

```ocaml
let f (x: 'a) = x
-- type error: a type variable in a pattern is not shared with the other
--   patterns, so it cannot say what it looks like it says. Write the type
--   of the whole definition instead: let f : 'a -> 'a = ...
```

Each annotation resolves its own names, so `'a` in two parameters would be
two variables, and the reader would have been promised one.

### The three colons

`:` means two things, and position decides which:

```ocaml
let port : Port = :8080     -- annotation, then a port literal
let xs = 1 :: [2, 3]        -- cons is `::`, and takes no `:`
```

- **A port literal** is a `:` directly against a digit: `:80`, `:8080`. The
  lexer decides this one. No space, and a digit after it, make one token.
- **A type annotation** is every other `:`. After a binding's name and
  parameters in a `let`: `let x : Int = ...`, `let f a b : Int = ...`.
  Inside the parentheses of a pattern: `(p: Pod)`, `Ok (p: Pod)`. In a type
  definition's named fields.

There is no inline ascription `(e : T)`. Annotate the binding instead.

Cons is `::`, and a `:` gives a name a type. So a `:` between two
expressions, or in a pattern with no type after it, is refused where it
stands and the error names `::`, rather than being read on until the
expression fails somewhere else.

---

## Imports

### Standard library modules

```ocaml
import List
import String
import FS
```

A script that you run with `wand file.wand` must `import` a stdlib module
before it uses one. `List.map` without `import List` fails with an
unbound-name error, although the module comes with wand. The REPL and the
one-shot `e`, `t`, `d` and `env` subcommands are the exception. They load every
stdlib module for you — every one listed under
[Current standard library](#current-standard-library), and a module added
there is loaded the day it is added.

Every function a file calls comes from a module it imported, with no
exceptions. Printing is `IO.println`, so a file that prints writes
`import IO`. A type and a constructor follow the same rule. The only names in
scope without an import are `Ok`, `Error`, `Some` and `None`, which are
constructors of built-in types and have no module to come from.

Imported names are available under the module prefix:

```ocaml
import List

List.map    (fn x -> x * 2) [1, 2, 3]    -- [2, 4, 6]
List.filter (fn x -> x > 2) [1, 2, 3]    -- [3]
List.length [1, 2, 3]                     -- 3
```

### User modules

Bind a user module to a name:

```ocaml
let utils   = import ./utils
let Helpers = import ./lib/helpers    -- capitalisation is convention, not enforced
```

The file extension is optional. `./utils` and `./utils.wand` mean the
same.

Access members via dot notation:

```ocaml
let utils = import ./utils

utils.my_function 42
utils.greeting
```

### Destructured imports

Import specific names from a module by naming them in braces:

```ocaml
let {foo = bar}            = import ./utils   -- bind utils.foo as bar
let {foo = a, bar = b}     = import ./utils   -- and utils.bar as b
```

The name on the left of the `=` belongs to the module. The name on the right
is the name it has here.

Or bind each name under its own name. A map pattern has the same
shorthand:

```ocaml
let {foo, bar} = import ./utils         -- bind foo and bar
```

Short entries and renamed entries mix freely. A map pattern behaves the same
way.

An uppercase name selects a type or one of its constructors:

```ocaml
let {TestOutcome, Pass, Fail} = import Test
let {Conf = MyConf}           = import ./foo
```

Renaming a type renames its constructor where it has one, so `MyConf(port =
:80)` builds a `Foo.Conf`. A type with several constructors has no single one
to rename, so renaming one of them is refused. Rename the type, or reach the
constructor through the module.

#### What a destructure binds by

Brackets destructure a list. Braces destructure a map or a module. What they
match on differs in each case, and the value on the right decides:

```ocaml
let [a, b]      = [10, 20]         -- a list: by position
let {x = a}     = m                -- a map: by key
let {map}       = import List      -- a module: by name
let {map = m2}  = import List      -- a module: by name, renamed
let {Pass}      = import Test      -- a module: a constructor, by name
```

Only a list pattern is positional. The difference shows when the order
changes. Swap two names in a list pattern, and the bindings swap with them.
Swap them in a module pattern, and nothing moves. There is no order to
follow:

```ocaml
let {filter, map} = import List
map (fn x -> x * 2) [1, 2]     -- [2, 4] — still List.map
```

Only a list can be too short during a run in a way that its type did not
catch. wand checks a module at the import, and a missing name is an error
there.

### Stdlib bound to custom name

```ocaml
let L = import List
L.length [1, 2, 3]    -- 3
```

### Private symbols

Names beginning with `_` are private — they cannot be accessed from outside the module:

```ocaml
-- utils.wand
let _helper x = x * 2      -- private
let double x = _helper x    -- public, calls private helper
```

```ocaml
let utils = import ./utils
utils.double 5       -- 10
utils._helper 5      -- type error: _helper not found in module
```

An import by path must state the name that it binds. `import ./utils` alone
is an error. Write `let utils = import ./utils`, or a destructuring pattern.
Then the name of the module is written at the import, and `grep` finds it.
This does not affect `import FS` and the other stdlib imports. Those already
write the name.

---

## Current standard library

### `List`

```ocaml
map        : ('a -> 'b ! 'e) -> List 'a -> List 'b ! 'e
filter     : ('a -> Bool ! 'e) -> List 'a -> List 'a ! 'e
filter_map : ('a -> Option 'b ! 'e) -> List 'a -> List 'b ! 'e
fold_left  : ('a -> 'b -> 'a ! 'e) -> 'a -> List 'b -> 'a ! 'e
fold_right : ('a -> 'b -> 'b ! 'e) -> List 'a -> 'b -> 'b ! 'e
length     : List 'a -> Int
append     : List 'a -> List 'a -> List 'a ! 'e
reverse    : List 'a -> List 'a
head       : List 'a -> Option 'a
head!      : List 'a -> 'a ! {Raise}
tail       : List 'a -> Option (List 'a)
tail!      : List 'a -> List 'a ! {Raise}
empty?     : List 'a -> Bool
any?       : ('a -> Bool ! 'e) -> List 'a -> Bool ! 'e
all?       : ('a -> Bool ! 'e) -> List 'a -> Bool ! 'e
find       : ('a -> Bool ! 'e) -> List 'a -> Option 'a ! 'e
zip        : List 'a -> List 'b -> List ('a, 'b) ! 'e
take       : Int -> List 'a -> List 'a ! 'e
drop       : Int -> List 'a -> List 'a ! 'e
take_while : ('a -> Bool ! 'e) -> List 'a -> List 'a ! 'e
drop_while : ('a -> Bool ! 'e) -> List 'a -> List 'a ! 'e
each       : ('a -> 'b ! 'e) -> List 'a -> Unit ! 'e
indexed    : List 'a -> List (Int, 'a)
sort       : List 'a -> List 'a
sort_by    : ('a -> 'b) -> List 'a -> List 'a
unique     : List 'a -> List 'a
range      : Int -> Int -> List Int
flatten    : List (List 'a) -> List 'a
concat     : List 'a -> List 'a -> List 'a
get        : Int -> List 'a -> Option 'a
get!       : Int -> List 'a -> 'a ! {Raise}
sum        : List Add -> Option Add
max        : List Ord -> Option Ord
min        : List Ord -> Option Ord
```

`sum`, `max` and `min` start from the first element rather than from a
literal zero. That is what keeps them polymorphic: a `0` would be an `Int`
and would pin the list to `Int`, and [`Add`](#adding-and-add) covers `Size`
and `Duration` too. So a list of file sizes totals to a `Size`.

The `Option` is the price of that, and it is honest. A sum of nothing has no
unit to answer with, and the unit is the very thing the type does not fix.
Supply one where it is known:

```ocaml
List.sum [1KB, 500B]                        -- Some(1500B)
List.sum sizes |> Option.default 0B         -- a Size either way
List.max [1.9.0, 1.10.0]                    -- Some(1.10.0), by precedence
```

`max` and `min` read the value, not the text it was written as, exactly as
[`<`](#comparison-and-ord) does. For the larger of two values rather than of
a list, [`Ord`](#ord) has the same pair.

`each` takes the element, as `map` and `filter` do, and returns `Unit`. Use
it for effects. wand drops what the function returns. So a command that you run
for its effect needs nothing around it, and `$()` gives back stdout whether the
command wrote any or not. Use `indexed` when you want the position:

```ocaml
files |> List.each (fn p -> FS.copy! p (Path.join dest (Path.basename p)))
files |> List.indexed |> List.each (fn (i, p) -> IO.println "%{i}: %{p}")
```

### `String`

```ocaml
length       : String -> Int
empty?       : String -> Bool
upper        : String -> String
lower        : String -> String
trim         : String -> String
trim_left    : String -> String
trim_right   : String -> String
slice        : Int -> Int -> String -> String
split        : String -> String -> List String
contains?    : String -> String -> Bool
starts_with? : String -> String -> Bool
ends_with?   : String -> String -> Bool
replace      : String -> String -> String -> String
repeat       : Int -> String -> String
reverse      : String -> String
truncate     : Int -> String -> String
bytes        : String -> List String
join         : String -> List String -> String
lines        : String -> List String
words        : String -> List String
of_int       : Int -> String
to_int       : String -> Result String Int
to_float     : String -> Result String Float
to_bool      : String -> Result String Bool
to_path      : String -> Path
to_glob      : String -> Result String Glob
to_url       : String -> Result String URL
to_ipv4      : String -> Result String IPv4
to_cidr      : String -> Result String CIDR
to_port      : String -> Result String Port
to_version   : String -> Result String Version
to_size      : String -> Result String Size
to_datetime  : String -> Result String DateTime
to_duration  : String -> Result String Duration
```

A `String` holds bytes, so `length` and `bytes` count bytes, `upper` and
`lower` convert ASCII only, and `slice` and `reverse` can cut a multi-byte
character in half. `truncate` is the one that will not:
[A `String` is bytes](#a-string-is-bytes) says which functions are safe on
any input and why the model is the right one.

The `to_*` family reads a value as a script writes it. Each one returns a
`Result` that names the rule the text broke:

```ocaml
String.to_duration "30s"      -- Ok 30s
String.to_ipv4 "256.0.0.1"    -- Error (invalid IPv4 address: each octet must be 0–255)
String.to_port ":99999"       -- Error (invalid port :99999: must be 0-65535)
```

`to_port` also takes the bare number. `"8080"` and `":8080"` both read. That
is what an environment variable, a config file or a flag holds. `Decode.port`
accepts both for the same reason.

### `Regex`

```ocaml
compile     : String -> Result String Regex
match?      : Regex -> String -> Bool
capture     : Regex -> String -> List String
replace     : Regex -> String -> String -> String
replace_all : Regex -> String -> String -> String
split       : Regex -> String -> List String
match_all   : Regex -> String -> List String
```

A pattern matches bytes, not characters, so `.` is one byte and `r/^.$/`
does not match `"é"`. See [A `String` is bytes](#a-string-is-bytes).

### `Map`

```ocaml
empty     : Map 'a
get       : String -> Map 'a -> Option 'a
get!      : String -> Map 'a -> 'a ! {Raise}
set       : String -> 'a -> Map 'a -> Map 'a
delete    : String -> Map 'a -> Map 'a
has?      : String -> Map 'a -> Bool
keys      : Map 'a -> List String
values    : Map 'a -> List 'a
size      : Map 'a -> Int
to_list   : Map 'a -> List (String, 'a)
from_list : List (String, 'a) -> Map 'a
merge     : Map 'a -> Map 'a -> Map 'a
map       : ('a -> 'b) -> Map 'a -> Map 'b
filter    : ('a -> Bool) -> Map 'a -> Map 'a
```

### `FS`

Each operation that can fail comes as a pair. The plain name returns a
`Result`. The `!` sibling raises. Each one names its file with a `Path`.

```ocaml
read_file    : Path -> Result String String ! {FS.Read}
write_file   : Path -> String -> Result String Unit ! {FS.Write}
append       : Path -> String -> Result String Unit ! {FS.Write}
create_file  : Path -> Result String Unit ! {FS.Write}
mkdir        : Path -> Result String Unit ! {FS.Write}
delete       : Path -> Result String Unit ! {FS.Write}
rename       : Path -> Path -> Result String Unit ! {FS.Write}
copy         : Path -> Path -> Result String Unit ! {FS.Write}
copy_tree    : Path -> Path -> Result String Unit ! {FS.Write}
delete_tree  : Path -> Result String Unit ! {FS.Write}
list_dir     : Path -> Result String (List Path) ! {FS.Read}
mtime        : Path -> Result String DateTime ! {FS.Read}
size         : Path -> Result String Size ! {FS.Read}
stream_lines : Path -> Stream {FS.Read, Raise | ..} String
```

The `!` siblings return the value and carry `Raise`:

```ocaml
read_file!   : Path -> String ! {FS.Read, Raise}
write_file!  : Path -> String -> Unit ! {FS.Write, Raise}
append!      : Path -> String -> Unit ! {FS.Write, Raise}
create_file! : Path -> Unit ! {FS.Write, Raise}
mkdir!       : Path -> Unit ! {FS.Write, Raise}
delete!      : Path -> Unit ! {FS.Write, Raise}
rename!      : Path -> Path -> Unit ! {FS.Write, Raise}
copy!        : Path -> Path -> Unit ! {FS.Write, Raise}
copy_tree!   : Path -> Path -> Unit ! {FS.Write, Raise}
delete_tree! : Path -> Unit ! {FS.Write, Raise}
list_dir!    : Path -> List Path ! {FS.Read, Raise}
mtime!       : Path -> DateTime ! {FS.Read, Raise}
size!        : Path -> Size ! {FS.Read, Raise}
```

Questions and lookups cannot fail, so they have no pair:

```ocaml
exists?      : Path -> Bool ! {FS.Read}
file?        : Path -> Bool ! {FS.Read}
dir?         : Path -> Bool ! {FS.Read}
cwd          : Unit -> Path ! {FS.Read}
glob         : Glob -> List Path ! {FS.Read}
glob_in      : Glob -> Path -> List Path ! {FS.Read}
```

```ocaml
temp_file    : String -> String -> Resource {FS.Read, FS.Write, Raise | ..} Path
temp_dir     : String -> Resource {FS.Read, FS.Write, Raise | ..} Path
```

`temp_file prefix suffix` is a resource rather than a plain call, so the
file it creates is removed when the bracket holding it ends:

```ocaml
with FS.temp_file "wand_" ".txt" as p ->
  FS.write_file! p contents
```

The release accepts a file that is already gone. So a body can rename the
file into place, which is how an atomic write publishes its result, and the
cleanup still succeeds.

`temp_dir prefix` is the same for a directory, and removes it with
everything in it:

```ocaml
with FS.temp_dir "build_" as dir ->
  ...
```

A scratch directory exists to be filled. So the release removes the tree.
The body does not have to empty it first.

wand creates a file with mode 0644 and a directory with mode 0755. The umask
then applies. `copy` is the exception. A new destination gets the permissions
of the source, so a copied script stays executable and a copy of a private file
stays private. A destination that already exists keeps the permissions it
had.

### `Resource`

```ocaml
make : (Unit -> 'a ! 'e) -> ('a -> Unit ! 'e) -> Resource {..} 'a
```

A resource pairs an acquire with a release. Only `with` runs one. See
[Resource brackets](#resource-brackets).

### `Path`

```ocaml
join           : Path -> Path -> Path
parent         : Path -> Path
basename       : Path -> Path
dirname        : Path -> Path
extension      : Path -> String
with_extension : String -> Path -> Path
absolute?      : Path -> Bool
relative?      : Path -> Bool
normalize      : Path -> Path
to_string      : Path -> String
of_string      : String -> Path
components     : Path -> List String
```

`basename` returns a `Path`, as `parent` and `dirname` do. A basename is a
relative path of one segment. You usually join it onto a directory next:

```ocaml
FS.copy! p (Path.join dest (Path.basename p))
```

`extension` and `components` return text, because an extension and a list of
segments are not paths. Use `Path.to_string` when the text of a basename is
what you want.

### `IO`

```ocaml
print       : 'a -> Unit ! {IO}
println     : 'a -> Unit ! {IO}
print_err   : String -> Unit ! {IO}
println_err : String -> Unit ! {IO}
read_line   : Unit -> Result String String ! {IO}
read_line!  : Unit -> String ! {IO, Raise}
read_all    : Unit -> Result String String ! {IO}
read_all!   : Unit -> String ! {IO, Raise}
flush       : Unit -> Unit ! {IO}
stdin_lines : Unit -> Stream {IO, Raise | ..} String
```

### `Stream`

```ocaml
of_list   : List 'a -> Stream {..} 'a
map       : ('a -> 'b ! 'e) -> Stream {..} 'a -> Stream {..} 'b
filter    : ('a -> Bool ! 'e) -> Stream {..} 'a -> Stream {..} 'a
take      : Int -> Stream {..} 'a -> Stream {..} 'a
fold_left : ('a -> 'b -> 'a ! 'e) -> 'a -> Stream {..} 'b -> 'a ! 'e
each      : ('a -> 'b ! 'e) -> Stream {..} 'a -> Unit ! 'e
to_list   : Stream {..} 'a -> List 'a ! 'e
count     : Stream {..} 'a -> Int ! 'e
last      : Stream {..} 'a -> Option 'a ! 'e
empty?    : Stream {..} 'a -> Bool ! 'e
any?      : ('a -> Bool ! 'e) -> Stream {..} 'a -> Bool ! 'e
all?      : ('a -> Bool ! 'e) -> Stream {..} 'a -> Bool ! 'e
find      : ('a -> Bool ! 'e) -> Stream {..} 'a -> Option 'a ! 'e
sum       : Stream {..} Add -> Option Add ! 'e
max       : Stream {..} Ord -> Option Ord ! 'e
min       : Stream {..} Ord -> Option Ord ! 'e
```

Read through a file, and do not read it into memory. A stream describes a
source and its stages. wand reads nothing until a terminal operation runs it:
`fold_left`, `each` or `to_list`. The run opens the source, sends each line
through the stages, and closes the source on the way out, however the run
ends. A stream describes, as a `Resource` does. It is never the open thing. So
you can name it, pass it, send it to `Par`, and fold it twice.

```ocaml
FS.stream_lines /var/log/app.log
|> Stream.filter (fn l -> String.contains? "ERROR" l)
|> Stream.fold_left (fn n _ -> n + 1) 0
```

`take n` stops the read after n elements. The memory and the reading are
both bounded. `to_list` reads everything. Its name says so.

Everything below `to_list` in that list is a terminal operation too, so each
one runs the stream. They divide by how much of the source they need.

`count`, `last`, `sum`, `max` and `min` read all of it. **`count` is not
called `length`.** `List.length` sounds free and this is not: counting reads
the whole source, and counting twice reads it twice. The different word is
the warning. `sum`, `max` and `min` answer an `Option` and start from the
first element, for the same reason [`List.sum`](#list) does.

`empty?`, `any?`, `all?` and `find` stop as soon as the answer is settled.
`any?` reads to the first element that matches, `all?` to the first that does
not, and `empty?` reads one element. So a match near the head of a 10GB log
costs the head of that log:

```ocaml
FS.stream_lines /var/log/app.log
|> Stream.any? (fn l -> String.contains? "PANIC" l)
```

Every name here that `List` also has keeps the `List` spelling, because the
answer really is the same one. Only `count` differs, and only because the
cost does.

**Each terminal operation reads the source again.** Fold a stream twice, and
wand opens and reads the file twice. Each read sees the file as it is then.
Each `Par` worker reads for itself. A traversal is not free, and it is not a
snapshot. What you know about `List` does not transfer. `IO.stdin_lines` is the
one source that cannot run twice. A second read of the real stdin raises.

A source that can fail puts `Raise` in the effect set of the stream. The
failure appears at the terminal operation, where the open happens. So put `try`
around the terminal call. There are no `!` siblings here. No `Stream` function
adds a raise of its own, so none earns a bang.

A read performs one effect for each open. `FS.read_file` works at the same
level. So a fold traces as one line, and a test mocks the whole file.
`Test.with_lines path lines thunk` answers each `FS.stream_lines` for `path`
with `lines`. Any other path streams as empty.

### `DateTime`

```ocaml
year        : DateTime -> Int
month       : DateTime -> Int
day         : DateTime -> Int
hour        : DateTime -> Int
minute      : DateTime -> Int
second      : DateTime -> Int
weekday     : DateTime -> Int
day_start   : DateTime -> DateTime
on          : Int -> Int -> Int -> Result String DateTime
on!         : Int -> Int -> Int -> DateTime ! {Raise}
date_string : DateTime -> String
time_string : DateTime -> String
```

There is one instant type and one resolution, the second. `2024-01-15` is a
spelling of `2024-01-15T00:00:00Z`, so a day and an instant are one value
written two ways, and a `Duration` moves either by the same amount. A value
prints in full; `date_string` is how the short form is written.

Nothing here reads a clock — `Clock.now` does, and this module takes what it
answers apart:

```ocaml
Clock.now () |> DateTime.day_start            -- today at midnight
```

`weekday` is ISO 8601: Monday is 1 and Sunday is 7. A number rather than a
variant, because it sorts and compares.

`on` is the only builder, and it answers a `Result` because `2026 2 30` is
not a day. A time of day goes on top as a `Duration`, since a `Duration`
already moves an instant:

```ocaml
DateTime.on! 2026 8 22 + 14h + 30min          -- 2026-08-22T14:30:00Z
```

That needs no rule for what `at 25 0 0` would mean: adding 25 hours to a
midnight is the next day at one.

`date_string` is the stamped-name case, which is why there is no format
string:

```ocaml
let name = "backup-%{DateTime.date_string (Clock.now ())}.tar.gz"
```

Every instant is UTC. A local reading would make one script answer
differently on two machines, and the timezone database is not going in the
binary. There is no calendar arithmetic: a month is not a fixed length, so
it is not a `Duration`.

### `Clock`

```ocaml
sleep : Duration -> Unit ! {Clock}
now   : Unit -> DateTime ! {Clock}
timed : (Unit -> 'a ! 'e) -> (Duration, 'a) ! {Clock | 'e}
```

Waits for at least the duration given. It is a floor, not a promise: a
loaded machine, a busy worker or an interrupt window each make it longer.

```ocaml
import Clock

let () = Clock.sleep 30s
```

A zero or a negative duration returns at once, and still performs the
effect. So a trace sees it, and a handler that supplies a clock is not
stepped around by a value that happens to be zero.

Ctrl-C during a sleep takes effect at once.

`now` answers the current instant in UTC. There is no local form: a local
reading would make one script answer differently on two machines, and a
wall clock a human reads is `$(date)`.

A `Duration` moves an instant, and two instants subtract to the length
between them:

```ocaml
Clock.now () - FS.mtime! log > 30d     -- older than thirty days
Clock.now () + 1h                      -- an hour from now
FS.mtime! b - FS.mtime! a              -- how much later b was written
```

Two instants do not add, and a `Duration` does not subtract an instant.
Both are type errors that name the form to write. A difference floors at
zero, as every `Duration` subtraction does, so a file stamped in the future
reads as no age rather than a negative one. An instant carries whole
seconds, so a duration below a second moves it nowhere.

`timed` runs a thunk and answers with how long it took, beside what it
returned:

```ocaml
let (took, report) = Clock.timed (fn () -> build ())
```

It is the only way wand measures a length of time. Two readings of `now`
subtract to something a clock step can spoil, so `timed` reads a clock that
no correction moves. Time while the machine is suspended counts, because a
laptop that slept for seven hours did take seven hours. `V-CLOCK1` names
`timed` when a subtraction has `now` on both sides.

A virtual clock does not shorten it. `Test.with_clock` makes the sleeps
inside cost nothing, and `timed` then reports the real time taken, which is
almost none. The virtual total is what `with_clock` itself answers.

Under a handler the clock is whatever the handler says. `Test.with_clock`
supplies one that costs no time, so a test of an hour of backoff runs in
microseconds:

```ocaml
let (elapsed, result) = Test.with_clock (fn () -> retry fetch)
```

### `Random`

```ocaml
seed    : Int -> Unit ! {Random}
int     : Int -> Int -> Int ! {Random}
float   : Unit -> Float ! {Random}
chance? : Float -> Bool ! {Random}
choose  : List 'a -> Option 'a ! {Random}
shuffle : List 'a -> List 'a ! {Random}
hex     : Int -> String ! {Random}
```

Every draw performs `Random`, for the same reason `Clock.now` performs
`Clock`: nothing in the type says that two identical calls give two
different answers, so the manifest does.

```ocaml
uses {Random}

import Duration
import Random

let roll = Random.int 1 6                  -- both ends included
let host = Random.choose pool              -- Option, because a list can be empty
let order = Random.shuffle tests
let wait = Duration.add 1s (Duration.seconds (Random.int 0 30))
```

`seed` pins what the run draws, and a run that pins nothing starts from the
environment. So a script is reproducible when it says it is:

```ocaml
Random.seed 42
```

Call it once, at the top. A seed set in the middle pins the rest of the run
and leaves what came before it unpinned, which is the shape that looks
reproducible in a test and is not. The sequence a seed produces is stable
for a build, not across builds — it is what a test needs, not a format, so
nothing should store a seed expecting to draw the same values from it a
year later.

`int` includes both ends, because a die has six faces and `Random.int 1 6`
should roll one. A range given backwards is read forwards, so `Random.int 6
1` is the same six faces rather than an empty range that silently answers
the same number every time.

`chance?` takes the odds rather than fixing them at a half, which is what
the call sites want — a retry that jitters, a sample that keeps one row in
a hundred, a fault injected rarely. `0.0` is never and `1.0` is always, and
both are exact.

Nothing here raises. A draw from an empty list answers `None`, `shuffle []`
is `[]`, and `hex 0` is `""` — an empty range is a question about the
argument, and the caller already has it.

`hex` is for temporary paths, run identifiers and cache keys, where a
collision is an inconvenience. It is not for anything a secret rests on:
the generator behind it is fast and predictable from its own output, which
is the opposite of what a token needs.

A handler answers draws directly, which is how a test fixes what a shuffle
does without pinning a seed and hoping:

```ocaml
handle thunk () with
| Random!below _ k -> k 0        -- every draw takes the first thing offered
| Random!float _ k -> k 0.5
| Random!seed  _ k -> k ()
```

All three, because an effect is discharged only when every operation
carrying it is handled — see [What a handler
discharges](#what-a-handler-discharges). Answering `below` alone still fixes
the draws it covers; it just leaves `Random` on the signature.

### `Proc`

```ocaml
exit : Int -> 'a ! {Proc}
args : Unit -> List String
pid  : Unit -> Int
```

`Proc.exit` ends the program with the code you give. On the way out it runs
the cleanup of each `with` that still holds something. Its result type is
whatever the caller needs, because nothing follows it:

```ocaml
if broken? then Proc.exit 1 else continue! ()
```

`args` gives the arguments of the script, without the program name.
`wand deploy.wand --port 8080` gives `["--port", "8080"]`. See
[`Args`](#args) to read them with a decoder. `pid` gives the process id the
operating system assigned.

Neither carries an effect. Both are handed to the process before it starts
and never change, so reading either reaches nothing and answers the same
twice — see [What earns a label](#what-earns-a-label). A `Par` worker is a
domain rather than a second process, so every branch reads one pid.

### `Env`

```ocaml
get   : String -> Option String ! {Env}
get!  : String -> String ! {Env, Raise}
set   : String -> String -> Unit ! {Env}
clear : String -> Unit ! {Env}
all   : Unit -> List (String, String) ! {Env}
home  : Unit -> Path ! {Env}
user  : Unit -> String ! {Env}
read  : Path -> Result String (Map String) ! {Env, FS.Read}
read! : Path -> Map String ! {Env, FS.Read, Raise}
load  : Path -> Result String Unit ! {Env, FS.Read}
load! : Path -> Unit ! {Env, FS.Read, Raise}
```

The arguments of the script are not here. They are handed to the process
rather than read from the environment, so they are [`Proc.args`](#proc).

### `CSV`

```ocaml
parse          : String -> List (List String)
parse_with     : String -> String -> List (List String)
stringify      : List (List 'a) -> String
stringify_with : String -> List (List 'a) -> String
read_file      : Path -> Result String (List (List String)) ! {FS.Read}
read_file!     : Path -> List (List String) ! {FS.Read, Raise}
rows           : Decoder 'a -> String -> Result String (List 'a)
```

Parses [RFC 4180](https://tools.ietf.org/html/rfc4180) CSV. A field can
carry quotes, written `""`. Double a quote inside one: `"say ""hi"""`.
`read_file` returns `Result String (List (List String))`. `read_file!`
raises.

```ocaml
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

```ocaml
parse            : String -> Result String JSON
parse!           : String -> JSON ! {Raise}
stringify        : JSON -> String
stringify_pretty : JSON -> String
read_file        : Path -> Result String JSON ! {FS.Read}
read_file!       : Path -> JSON ! {FS.Read, Raise}
null             : JSON
of_bool          : Bool -> JSON
of               : 'a -> Result String JSON
of!              : 'a -> JSON ! {Raise}
of_int           : Int -> JSON
of_float         : Float -> JSON
of_string        : String -> JSON
of_list          : List JSON -> JSON
of_map           : Map JSON -> JSON
null?            : JSON -> Bool
get_bool         : JSON -> Result String Bool
get_int          : JSON -> Result String Int
get_float        : JSON -> Result String Float
get_string       : JSON -> Result String String
get_array        : JSON -> Result String (List JSON)
get_object       : JSON -> Result String (Map JSON)
field            : String -> JSON -> Result String JSON
field!           : String -> JSON -> JSON ! {Raise}
decode           : Decoder 'a -> JSON -> Result String 'a
```

`JSON` is an opaque type. `parse` and `read_file` return
`Result String JSON`. The `!` forms raise. Each typed extractor returns a
`Result`.

`of` writes any value as JSON in one call, so a structure does not have to
be converted a piece at a time: numbers, text, every domain type, lists,
maps, options and records, and any nesting of them. A function, a resource
or a stream cannot be written, and that is the `Error`; `of!` raises
instead. The `of_*` builders take one converted value each and cannot fail.

A `Map` holds one type, so a document whose fields differ is a record.

`of_map` is the inverse of `get_object`. It writes the keys in the order that
the `Map` holds them, which keeps a diff small. A `Map` cannot hold a key
twice, so wand writes it once, at its first position. That is the value that
`Map.get` finds. Parsers disagree about a document that names a key twice.

```ocaml
import JSON

let j = JSON.parse! "{\"name\":\"Alice\",\"age\":30}"

match JSON.field "name" j with
| Ok v  -> JSON.get_string v    -- Ok "Alice"
| Error _ -> Error "missing"

-- Building JSON
JSON.stringify (JSON.of! [1, 2])              -- "[1,2]"
JSON.stringify (JSON.of! {name = "web"})      -- {"name":"web"}

-- A record is how a document with fields of different types is written.
type Pod (name : String, port : Int)
JSON.stringify (JSON.of! Pod(name = "web", port = 8080))
                                              -- {"name":"web","port":8080}

-- The precise builders are still there, and cannot fail.
let arr = JSON.of_list [JSON.of_int 1, JSON.of_int 2]

match JSON.read_file ./config.json with
| Ok cfg -> JSON.field! "host" cfg
| Error msg -> JSON.of_string "localhost"
```

### `TOML`

```ocaml
parse      : String -> Result String TOML
parse!     : String -> TOML ! {Raise}
of         : 'a -> Result String TOML
of!        : 'a -> TOML ! {Raise}
stringify  : TOML -> String
read_file  : Path -> Result String TOML ! {FS.Read}
read_file! : Path -> TOML ! {FS.Read, Raise}
table?     : TOML -> Bool
array?     : TOML -> Bool
get_bool   : TOML -> Result String Bool
get_int    : TOML -> Result String Int
get_float  : TOML -> Result String Float
get_string : TOML -> Result String String
get_array  : TOML -> Result String (List TOML)
get_table  : TOML -> Result String (Map TOML)
field      : String -> TOML -> Result String TOML
field!     : String -> TOML -> TOML ! {Raise}
decode     : Decoder 'a -> TOML -> Result String 'a
```

`of` writes a value as TOML, which is what builds a document rather than
re-printing a parsed one. A TOML document is a table, so the value is a map
or a record; a bare number says so rather than producing something no parser
would read back. An array holds one type, as a wand list does, and a field
that is `None` is left out — TOML has no null, so writing one would not read
back the same.

`TOML` is an opaque type for any TOML value: a table, a string, an int, a
float, a bool or an array. The top-level parse always gives a table. Each typed
extractor returns a `Result`. `field` and `field!` walk the keys.

```ocaml
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

### `Float`

```ocaml
of_int : Int -> Float
round  : Float -> Int
floor  : Float -> Int
ceil   : Float -> Int
abs    : Float -> Float
format : Int -> Float -> String
```

`Float.format` writes a fixed number of digits after the point, and fills
them in: `Float.format 1 0.3333` is `"0.3"` and `Float.format 2 1.5` is
`"1.50"`. A width is a printing decision, so it answers a `String`.

These functions cross between the two members of `Num`. Arithmetic never
converts for you. `1.5 + 1` is a type error, and it names these functions. So
you always write the crossing:

```ocaml
import Float

Float.of_int 3          -- 3 : Float
Float.round 2.5         -- 3, halves rounding away from zero
Float.round (- 2.5)     -- -3
Float.floor (- 2.1)     -- -3
Float.ceil 2.1          -- 3
Float.abs (- 2.5)       -- 2.5
```

`String.to_float` parses text. `JSON`, `TOML` and `Decode` read a float out
of a document.

### `Int`

```ocaml
abs       : Int -> Int
pow       : Int -> Int -> Int ! 'e
divmod    : Int -> Int -> (Int, Int)
max_value : Int
min_value : Int
```

What an operator does not spell. Arithmetic is `+ - * / %`, so this module
is the remainder: distance from zero, repeated multiplication, both halves
of a division at once, and the ends of the range.

```ocaml
Int.abs (-7)            -- 7
Int.pow 2 10            -- 1024
Int.divmod 17 5         -- (3, 2)
Int.max_value           -- 4611686018427387903
```

`abs` is `Int`-only rather than `Num`-polymorphic, because `Float.abs`
already answers on the other side and arithmetic never crosses between the
two for you.

`pow` with a negative exponent divides, and `Int` division truncates toward
zero, so `Int.pow 2 (-1)` is `0`. A base of zero with a negative exponent
divides by zero, exactly as writing that division would.

`divmod` truncates toward zero in both halves, as `/` and `%` do on their
own, so the remainder takes the sign of the dividend: `Int.divmod (-17) 5`
is `(-3, -2)`.

`max_value` and `min_value` name the range that
[`Int`](#primitives) already documents. Arithmetic outside it is a runtime
error rather than a wrap, and it is not the `Raise` effect.

There is no `Int.to_string` and no `Int.to_float`. wand puts a conversion on
the type it produces, so those are `String.of_int` and `Float.of_int`.
`Int.of_string` is `String.to_int` under the same rule, and drawing a number
is `Random.int`, which carries the effect that belongs with it.

### `Ord`

```ocaml
max      : Ord -> Ord -> Ord
min      : Ord -> Ord -> Ord
clamp    : Ord -> Ord -> Ord -> Ord
between? : Ord -> Ord -> Ord -> Bool
```

The functions people write out of `<` and `>`. The module is named for the
constraint that appears in the signature, as `Option` and `Result` are, so a
reader who sees `Ord -> Ord -> Ord` and reaches for `Ord.max` finds it where
they looked.

One definition serves all ten [ordered types](#comparison-and-ord). There is
no `Int.max` beside a `Duration.max` beside eight more, which is the point of
having a constraint at all:

```ocaml
Ord.max 3 7                     -- 7
Ord.max 30s 2min                -- 2min
Ord.max 1.9.0 1.10.0            -- 1.10.0, by precedence
Ord.min 4KB 100MB               -- 4KB
```

`clamp` and `between?` take the low bound, then the high, then the value, so
the value can arrive from a pipeline. Both bounds are included:

```ocaml
Ord.clamp 0 10 42               -- 10
Ord.clamp 1s 30s 5min           -- 30s
Ord.between? 1 10 10            -- true
```

Comparison reads the value rather than the text it was written as, so these
answer about instants, byte counts and version precedence rather than about
spelling. For the largest of a list rather than of two values,
[`List.max`](#list) is the same idea folded.

### `Duration`

```ocaml
zero    : Duration
seconds : Int -> Duration
minutes : Int -> Duration
hours   : Int -> Duration
days    : Int -> Duration
weeks   : Int -> Duration
add     : Duration -> Duration -> Duration
sub     : Duration -> Duration -> Duration
scale   : Int -> Duration -> Duration
format  : Duration -> String
to_ms   : Duration -> Int
```

### `Size`

```ocaml
to_bytes : Size -> Int
of_bytes : Int -> Size
format   : Size -> String
```

A size literal carries the units it was written in, and `to_bytes` reads
it as a number: `100MB` is `100000000`, because `KB` is the SI thousand
and not 1024. Going the other way has to pick units, so `of_bytes` picks
bytes and stays exact — `Size.of_bytes 6466` is `6466B`. `format` is the
readable spelling of the same size, `"6.5KB"`, the way `Duration.format`
renders a duration. A byte count below zero reads as `0B`.

[`FS.size`](#fs) answers a `Size`, in bytes, so a threshold is the literal
it is: `FS.size! p < 4KB`.

### `Port`

```ocaml
to_int : Port -> Int
of_int : Int -> Result String Port
```

The colon is the literal's punctuation and stays in every string a port
makes, so `"host%{:8080}"` is `"host:8080"` — the address. Use `to_int`
where a command wants the number as an argument of its own, as in
`$(nc -z localhost %{Port.to_int port})`.

`of_int` refuses a number that is not a port. A port is 0 to 65535, and
70000 is a mistake rather than a maximum, so it answers an `Error` where
[`Size.of_bytes`](#size) clamps.

### `IPv4`

```ocaml
octets    : IPv4 -> (Int, Int, Int, Int)
to_int    : IPv4 -> Int
of_int    : Int -> Result String IPv4
private?  : IPv4 -> Bool
loopback? : IPv4 -> Bool
to_string : IPv4 -> String
of_string : String -> Result String IPv4
```

The literal checks itself — each octet is 0 to 255, or it is a lex error
naming the rule — and the language orders addresses numerically, so
`10.0.0.2 > 10.0.0.1` and `List.sort` agrees where sorting the text would
not. There is no `compare` here for that reason.

`to_int` is the address as the number it is, and every question about a
network is arithmetic on it. Doing that octet by octet is how an off-by-one
gets in one octet at a time.

`private?` is the three RFC 1918 ranges — `10.0.0.0/8`, `172.16.0.0/12`,
`192.168.0.0/16` — and nothing else. A caller asking about link-local or
multicast is asking a different question, and [`CIDR.contains?`](#cidr)
answers it against the range they name.

### `CIDR`

```ocaml
contains? : CIDR -> IPv4 -> Bool
network   : CIDR -> IPv4
prefix    : CIDR -> Int
first     : CIDR -> IPv4
last      : CIDR -> IPv4
count     : CIDR -> Int
to_string : CIDR -> String
of_string : String -> Result String CIDR
of_parts  : IPv4 -> Int -> Result String CIDR
```

`contains?` is what the type was missing. A network may be written from an
address inside it — `10.0.0.5/8` is how an `ip addr` line spells one — so
the prefix is what decides the range and every function here reads through
it. `CIDR.network 10.0.0.5/8` is `10.0.0.0`.

`first` and `last` are the addresses the prefix bounds: host bits all clear,
and all set. They are not "the first usable host" and "the broadcast
address", which are conventions of particular network sizes — a `/31` on a
point-to-point link has neither.

Networks order by where they start and then by how far they reach, so
`9.0.0.0/8 < 10.0.0.0/8 < 10.0.0.0/16`. As text the first two sort the other
way round.

### `Glob`

```ocaml
matches?  : Glob -> Path -> Bool
base      : Glob -> Path
to_string : Glob -> String
of_string : String -> Result String Glob
```

[`FS.glob`](#fs) answers which files a pattern selects, and needs `FsRead`
to say so. `matches?` answers the other question — whether a path is one the
pattern would select — and needs no effect, because the pattern and the path
are both already in hand. It is a builtin rather than the rules written
again in wand: it compiles the pattern the way `FS.glob` walks a directory
with it, so a walk and a predicate cannot disagree.

A leading `./` is not part of either side. It is a way of writing "here", so
it comes off the pattern and the path before they meet.

`of_string` is the only way to build a glob from text, and the only way to
write one that begins with a bare name — `src/**/*.ts` as a literal reads as
a variable called `src`, so a literal has to be written `./src/**/*.ts`.
Text with no `*`, `?` or `[` is refused: it names one file, which is what a
[`Path`](#path) is for, in a type whose functions are about naming a file
rather than selecting several. An unclosed character class is refused here
too, rather than raising the first time the pattern is matched.

`base` is the directory part before the first wildcard — where a walk over
the pattern has to start, and above which is ground it cannot reach.
`Glob.base ./src/**/*.ts` is `./src`. A pattern whose first segment is
already a wildcard answers `.`, since there is no directory above it to
begin from.

### `Version`

```ocaml
major           : Version -> Int
minor           : Version -> Int
patch           : Version -> Int
core            : Version -> Version
prerelease      : Version -> Option String
build           : Version -> Option String
stable?         : Version -> Bool
to_string       : Version -> String
of_string       : String -> Result String Version
of_parts        : Int -> Int -> Int -> Result String Version
bump_major      : Version -> Version
bump_minor      : Version -> Version
bump_patch      : Version -> Version
with_prerelease : Option String -> Version -> Result String Version
with_build      : Option String -> Version -> Result String Version
```

The type is [Semantic Versioning 2.0.0][semver], and the spec's grammar is
what a literal and `of_string` are both checked against. So a value of this
type is a semantic version: `01.2.3` and `1.2.3-01` are refused, because a
numeric identifier with a leading zero is not one, and `1.2.3-alpha_1` is
refused because `_` is not in the identifier set.

There is no `compare`. Ordering is the language's — `<`, `>` and `List.sort`
read a version by the spec's precedence rules, so
`1.0.0-alpha < 1.0.0-alpha.1 < 1.0.0-alpha.beta < 1.0.0-beta < 1.0.0` is
written the way it reads. Build metadata takes no part in precedence, as
rule 10 requires, so two versions differing only in their build compare
equal.

`of_string` reads two spellings a literal cannot. Build metadata, because
`+` is the addition operator and a literal reading `1.2.3+1` could not tell
it from arithmetic. And a leading `v`, because a git tag and a release note
write one: the `v` is dropped rather than kept, since the spec's FAQ calls
it a prefix and not part of the version, and keeping it would make `v1.2.3`
and `1.2.3` two values that order the same and print differently.

Each `bump_` clears everything below it, prerelease and build included: a
prerelease named a run-up to the version being stepped away from, and none
of it survives the step. `bump_patch` has one exception, which is rule 9
read forwards — a prerelease precedes the release it names, so
`bump_patch 1.2.3-rc.1` is `1.2.3` rather than `1.2.4`. Going to `1.2.4`
would step over the release the prerelease was for.

`with_prerelease` answers a `Result` because a prerelease is grammar rather
than text to escape: nothing turns `rc 1` into an identifier, so text that
is not one is reported instead of being quietly rewritten.

[semver]: https://semver.org/spec/v2.0.0.html

### `URL`

```ocaml
scheme          : URL -> String
hostname        : URL -> String
host            : URL -> String
port            : URL -> Option Port
username        : URL -> Option String
password        : URL -> Option String
origin          : URL -> String
path            : URL -> Path
query           : URL -> Map String
query_list      : URL -> List (String, String)
fragment        : URL -> Option String
to_string       : URL -> String
of_string       : String -> Result String URL
with_scheme     : String -> URL -> Result String URL
with_hostname   : String -> URL -> Result String URL
with_port       : Option Port -> URL -> URL
with_username   : Option String -> URL -> URL
with_password   : Option String -> URL -> URL
with_path       : Path -> URL -> URL
with_query      : Map String -> URL -> URL
with_query_list : List (String, String) -> URL -> URL
with_fragment   : Option String -> URL -> URL
join            : String -> URL -> Result String URL
encode          : String -> String
decode          : String -> Result String String
```

Every accessor is total. The value is a URL already — a literal, or
`URL.of_string` having checked one — so a part it does not hold answers `""`
or `None` rather than an error. `https://example.com` states no port, no
query and no fragment, and none of that is a failure.

`hostname` is the domain alone and `host` is the domain with the port, which
is the split the web platform uses. Naming the bare one `host` would read
correctly to anyone who had not met the other spelling and silently wrongly
to everyone who had.

`port` answers an `Option` rather than filling in a default. The default
follows from the scheme, 443 for https and 80 for http, and a caller passing
the port on to something else needs to know whether the URL named one.

`username` and `password` are two `Option`s rather than one pair, because a
URL may carry either: `https://:pw@host` has a password and no username. An
empty half is `None`, so "has one" is not two questions. Both are
percent-decoded, as every accessor here is.

`origin` is scheme, host and port — what two URLs have to share to address
the same server, and the reason it is one function rather than three read
together. The userinfo is not part of it: credentials do not change what is
addressed. It is written as the URL wrote it, so it says whether two URLs
*state* the same origin; see the note on normalization below.

`path` answers a [`Path`](#path), so it composes with the module that
already knows about segments and extensions. A URL with no path addresses
`/`.

`query` percent-decodes the keys and values, and reads `+` as a space: a
query string is form-encoded in practice, and a caller asking for `q` wants
what was typed. A repeated key keeps its last value, because that is what a
`Map` holds; `query_list` answers every pair in the order the URL wrote them.
`decode` is the one that leaves `+` alone.

`of_string` is `String.to_url` named from this side, and it is the only way
to build some URLs. A `,` and a `;` are legal in a URL and both end a URL
*literal*, because they are the punctuation of the expression around it — as
do the brackets of an IPv6 host:

```ocaml
URL.of_string "https://example.com/s?tags=a,b"    -- Ok(...)
URL.of_string "http://[::1]:8080/health"          -- Ok(...)
```

`join` resolves a reference the way a browser resolves the href of a link,
following RFC 3986: an absolute reference replaces the base, `/x` keeps the
host, `?q` and `#f` keep everything to their left, and a relative path is
merged against the base's directory and then has its `.` and `..` removed. A
`..` that would climb past the root is dropped rather than escaping the
authority. It answers a `Result` because an absolute reference is itself a
URL, and the text handed in may not be one.

`encode` covers everything outside the unreserved set, `/` and `&` included,
so its result is safe as one path segment or one query value. `with_query`
encodes for you, which is what stops an `&` in a value from becoming a
separator, and `with_query_list` is the one that can write the repeated key
`query_list` can read — a `Map` holds one value per key.

The `with_` functions each replace one part. Two answer a `Result`, because
their argument has to be a URL part in its own right: a scheme that is not
http, or a host holding a space, does not become one by being escaped, and
escaping it quietly would answer a URL addressing something else. The rest
encode what they are given and cannot fail. `with_path` keeps a path's `/`
separators and only escapes what cannot appear in a URL at all, and gives a
path a leading `/` if it has none, because a URL path is absolute.
`with_username` and `with_password` escape strictly: `@` and `:` delimit the
authority, so a password holding one would otherwise move the host.

This module does not normalize. It keeps the scheme, host and escapes as
they were written, where a browser's parser would lowercase the first two and
drop a default port. That matches how `DateTime` keeps the offset it was
written with. It also means `URL.host a == URL.host b` is a test of what two
URLs say, not of where they point.

### `Par`

```ocaml
map     : Int -> ('a -> 'b ! 'e) -> List 'a -> List (Result String 'b) ! 'e
each    : Int -> ('a -> 'b ! 'e) -> List 'a -> Unit ! 'e
race    : List (Unit -> 'a ! 'e) -> Result String 'a ! 'e
timeout : Duration -> (Unit -> 'a ! {Clock | 'e}) -> Result String 'a ! {Clock | 'e}
```

Fork-join parallelism, and nothing else:

```ocaml
Par.map  : Int -> ('a -> 'b ! 'e) -> List 'a -> List (Result String 'b) ! 'e
Par.each : Int -> ('a -> 'b ! 'e) -> List 'a -> Unit ! 'e
```

`each` drops what its function returns, as `List.each` does. The first
argument is the largest number of workers to run at one time. You state it,
because how much a script may do at once is a decision about the machine. The
results come back in the order of the list, not in the order they finished. An
element whose work raises comes back as an `Error` in its place. It does not
fail the others.

```ocaml
Par.map 4 (fn x -> x * 2) [1, 2, 3]        -- [Ok 2, Ok 4, Ok 6]
Par.map 4 (fn m -> Map.get! "k" m) [{k = 1}, Map.empty]
                                           -- [Ok 1, Error "map key not found: k"]
```

A worker never outlives the call. There is no handle to a running worker.
These two functions are the only way to start one. So there is nothing to
await, and no function changes because a worker calls it.

`race` runs every thunk at once and answers with the first to finish:

```ocaml
match Par.race [fn () -> $(curl %{a}), fn () -> $(curl %{b})] with
| Ok body   -> body
| Error why -> "both mirrors failed: %{why}"
```

First to *finish*, not first to succeed. A loser that raises is discarded.
A winner that raises comes back as `Error`, the way `map` puts a raise in
the element's place rather than failing the call. An empty list is an
`Error`.

`race` takes no worker limit, where `map` and `each` do. The count is the
length of the list, and the list is at the call site, so there is nothing
left to state.

**A race bounds when you get the answer, not when the machine goes quiet.**
The losers are told to stop, and each one stops at its next step, gives
back what it holds, and is joined before `race` returns. A loser doing wand
work stops at once. A loser waiting on a command waits for that command:
wand asks a worker to stop, and a worker inside a subprocess cannot answer
until the subprocess does. Put `Shell.timeout` in the thunk to bound that:

```ocaml
Par.race (List.map (fn u -> fn () -> Shell.timeout 2s (fn () -> $(curl %{u}))) mirrors)
```

**A race inside a handler is refused.** An effect cannot reach a handler on
another domain, so the branches cannot run where they were written: the race
would answer with its first thunk and say nothing, and a test of racing code
would test one branch and pass. Move the handler inside each thunk instead:

```ocaml
Par.race [
  fn () -> Test.with_shell mocks (fn () -> probe a),
  fn () -> Test.with_shell mocks (fn () -> probe b)
]
```

Under `--dry-run` and `--trace` a race still runs. Each reports what the
work would do, and the report costs nothing by the collapse, so the race is
left-biased and deterministic there: the first thunk is the one that
finishes first.

`timeout` puts a deadline on wand code, where `Shell.timeout` puts one on a
command:

```ocaml
match Par.timeout 30s (fn () -> poll_until_ready ()) with
| Ok v      -> v
| Error why -> "gave up: %{why}"
```

It is a race between the work and a sleeper, so it waits a length rather
than waiting until an instant — the difference that keeps it right on a
machine whose clock steps. The `Error` says how long it waited.

The work is asked to stop when the deadline passes, and stops at its next
step, giving back what it holds. Work inside a command finishes that
command first. Put `Shell.timeout` in the thunk to bound that too. A thunk
that raises comes back as `Error`, as it does under `race`.

**A deadline inside a handler is refused**, for the reason a race is: the
sleeper is a branch, and a branch cannot run where the handler is. Test a
deadline against real time, with a duration short enough to wait for, and
put the handler inside the thunk — `Par.timeout d (fn () -> with_shell
mocks (fn () -> work ()))`.

**A handler always reaches a worker.** When nothing watches, a worker
performs its own effects, and twenty slow commands do overlap. When a handler
is in scope — a mock, a `--dry-run`, a `--trace` — the effects run on the
calling side instead, one at a time. The handler lives there. So work that you
move into `Par` never escapes a test. To be watched costs the overlap, and
nothing rehearses for speed.

---

### `Shell`

```ocaml
ok?     : ShellResult -> Bool
failed? : ShellResult -> Bool
decode  : Decoder 'a -> String -> Result String 'a
lines   : Decoder 'a -> String -> Result String (List 'a)
timeout : Duration -> (Unit -> 'a ! 'e) -> Result String 'a ! {Clock | 'e}
```

Reading what a command wrote. See [Decoders](#decoders).

`ok?` and `failed?` are the same question asked either way, because half the
time the failing branch is the one a script is written around. `!` negates a
Bool but not a predicate waiting for its argument, so `!(Shell.ok? r)` needs
the brackets and `List.filter Shell.failed?` needs nothing.

`timeout` puts a deadline on the commands a thunk runs:

```ocaml
match Shell.timeout 30s (fn () -> $(curl %{url})) with
| Ok body   -> body
| Error why -> "gave up: %{why}"
```

A command that has not finished in time is sent SIGTERM, and SIGKILL five
seconds later. The grace is fixed, and is not a second parameter: a caller
who wants to think about TERM against KILL should write the signal handling
out instead.

The `Error` names the command and the deadline, because that message ends
up in a log and "timed out" alone says nothing. Only a deadline produces
one. Every other failure passes through, so a command that exits non-zero
raises as it always does.

Three things to know:

- **The deadline is per command.** A thunk that runs three commands may
  take three deadlines. For a bound on everything a thunk does, including
  the wand code between the commands, see `Par.timeout`.
- **A virtual clock does not shorten it.** The wait belongs to the
  operating system, not to wand, so `Test.with_clock` cannot answer it.
  Test a timeout against a command that really waits.
- **A killed command may leave children.** wand signals the command it
  started. `sh -c "sleep 30"` leaves the `sleep` when the shell is killed;
  wand stops waiting on it rather than waiting for a process it did not
  start.

```ocaml
let ahead = Shell.decode Decode.int $(git rev-list --count HEAD)
```

### `Hash`

```ocaml
string : Algorithm -> String -> Digest
file   : Algorithm -> Path -> Result String Digest  ! {FS.Read}
file!  : Algorithm -> Path -> Digest                ! {FS.Read, Raise}
hmac   : Algorithm -> String -> String -> Digest
equal? : Digest -> Digest -> Bool
```

Digests without a subprocess. A checksum written by `Shell(shasum)` tells a
reviewer that a binary ran and nothing about what was verified, and it does
not run everywhere: the tool is `shasum` on macOS and `sha256sum` on most
Linux images. A digest is arithmetic, and it should not depend on which
machine the script woke up on.

```ocaml
uses {FS.Read}
import Digest
import Hash
let {Sha256} = import Digest

Hash.string Sha256 body |> Digest.hex
Hash.file!  Sha256 ./dist/wand.tar.gz |> Digest.hex
```

**Hashing performs nothing.** `string`, `hmac` and every `Base64` function
reach nothing outside the program and answer the same twice, so they fit
none of the three things that [earn a label](#what-earns-a-label) and carry
none. Only `file` reaches outside, and what it carries is `FS.Read` for the
*read* — through an `FS!hash_file` operation, so `--dry-run`, `--trace` and
a test's mock see it the way they see `FS!read_file`. It reads the file in
blocks and never holds it, which is what makes a checksum of a release
archive possible at all.

`hmac` takes the key first and the message second, because a key is bound
once and a message is what varies, so a partial application reads as the
thing being built:

```ocaml
let sign = Hash.hmac Sha256 secret
let a = sign body
```

**`equal?` is constant-time and `==` is not.** Both compare digests. Use
`equal?` when the digest on one side came from somebody else — a webhook
signature, a token — because a comparison that stops at the first wrong byte
tells an attacker who can measure replies how much of the value they have
guessed. A deploy script checking a published checksum is not that case, and
`==` is right there. The lengths are compared before the bytes, and a
digest's length is public.

### `Digest`

```ocaml
type Algorithm = Sha256 | Sha512 | Sha1 | Md5
type Digest(algorithm: Algorithm, hex: String)

name      : Algorithm -> String
hex       : Digest -> String
base64    : Digest -> String
algorithm : Digest -> Algorithm
of_hex    : Algorithm -> String -> Result String Digest
of_hex!   : Algorithm -> String -> Digest ! {Raise}
```

`Hash` computes; this module holds the answer and renders it. A digest is a
type rather than a hex `String`, which buys two things.

**It carries which algorithm made it**, so comparing a sha256 against a
sha512 is a question the checker answers rather than a `false` that reads
like a failed verification. `of_hex` takes the algorithm because the text
cannot supply it: 64 hex digits are a sha256 or half a sha512, and which one
they are comes from whoever read them out of a file.

**One value has two renderings.** Checksum files are hex; S3 ETags and
subresource integrity are base64. Two accessors say that, where a `String`
return would need two families of function:

```ocaml
Hash.string Sha256 "abc" |> Digest.hex
-- "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
Hash.string Sha256 "abc" |> Digest.base64
-- "ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0="
```

`hex` and `algorithm` answer the same as the fields `d.hex` and
`d.algorithm`. The functions are the spelling that pipes.

`Sha256` and `Sha512` are for new work. `Sha1` and `Md5` are here for
interop and nothing else: git names objects with sha1 and S3 ETags are md5,
so a script matching one is not making a mistake. Leaving them out would not
stop anyone using them — it would send them to `Shell(md5sum)`, where the
manifest names a binary again.

### `Base64`

```ocaml
encode      : String -> String
decode      : String -> Result String String
decode!     : String -> String ! {Raise}
encode_url  : String -> String
decode_url  : String -> Result String String
decode_url! : String -> String ! {Raise}
```

Two alphabets, because both are load-bearing. The standard one is
RFC 4648 §4 and is what a basic-auth header and a kubeconfig secret use. The
URL-safe one is §5, with `-` and `_` where the standard has `+` and `/`, and
is what a JWT and a query parameter use. They are not interchangeable, so
each gets a name rather than the choice going into a flag that reads as a
detail.

**`encode` pads. `decode` accepts padded and unpadded input.** Padding is
required by the standard and omitted by most JWT producers, so a decoder
that insisted on it would reject the input people actually have. Strict out
and lenient in is the only pairing that round-trips against the rest of the
world.

```ocaml
Base64.encode "f"        -- "Zg=="
Base64.decode "Zg"       -- Ok "f"
Base64.decode "Zg=="     -- Ok "f"
```

A `String` [holds bytes](#a-string-is-bytes), so decoding answers a `String`
without lying about what is in it. Printing one writes rubbish if it is not
text.

### `Decode`

```ocaml
int      : Decoder Int
float    : Decoder Float
string   : Decoder String
bool     : Decoder Bool
field    : String -> Decoder 'a -> Decoder 'a
optional : String -> Decoder 'a -> Decoder (Option 'a)
list     : Decoder 'a -> Decoder (List 'a)
dict     : Decoder 'a -> Decoder (Map 'a)
nullable : Decoder 'a -> Decoder (Option 'a)
map      : ('a -> 'b) -> Decoder 'a -> Decoder 'b
map2     : ('a -> 'b -> 'c) -> Decoder 'a -> Decoder 'b -> Decoder 'c
map3     : ('a -> 'b -> 'c -> 'd) -> Decoder 'a -> Decoder 'b -> Decoder 'c -> Decoder 'd
and_then : ('a -> Decoder 'b) -> Decoder 'a -> Decoder 'b
succeed  : 'a -> Decoder 'a
fail     : String -> Decoder 'a
one_of   : List (Decoder 'a) -> Decoder 'a
path     : Decoder Path
glob     : Decoder Glob
duration : Decoder Duration
url      : Decoder URL
size     : Decoder Size
version  : Decoder Version

datetime : Decoder DateTime
ipv4     : Decoder IPv4
cidr     : Decoder CIDR
port     : Decoder Port
```

`Decoder a` is an opaque type. Running a decoder is a backend's job:

```ocaml
JSON.decode : Decoder 'a -> JSON -> Result String 'a
TOML.decode : Decoder 'a -> TOML -> Result String 'a
Args.parse  : Decoder 'a -> List String -> Result String 'a
```

See [Decoders](#decoders).

### `Args`

```ocaml
parse      : Decoder 'a -> List String -> Result String 'a
parse_with : List String -> Decoder 'a -> List String -> Result String 'a
read       : CommandLine 'a -> List String -> Result String 'a
help?      : List String -> Bool
```

A command line is another boundary without types. wand reads it the same way
as the others: argv becomes a document, and a decoder reads it. There are no
combinators here. Every combinator in `Decode` already applies, including the
domain readers and the error that names the field.

```ocaml
type Opts (port : Port, timeout : Duration, config : Path)

Args.parse Opts.decoder (Proc.args ())
-- Ok (Opts (port = :8080, timeout = 30s, config = ./app.toml))
-- Error .port: expected Port, got "http"
```

`--port 8080` and `--port=8080` mean the same. With `=`, only the first `=`
splits, so a value can hold more. wand assumes that each flag takes a value. A
list of strings cannot show this one fact. Without the assumption,
`--message -5` and a flag with a positional argument after it have the same
shape. Name the flags that take no value:

```ocaml
Args.parse_with ["verbose"] Opts.decoder (Proc.args ())
```

Each named flag is `true` when it is there and absent when it is not. A
`Bool` field left out of the document reads as `false`. A flag with nothing
after it is an error: `--config expects a value`.

Whether a flag takes a value is not the only fact that argv cannot state. A
flag written twice replaces its value. So `--name a --name b` is one name,
written twice. A flag whose field is a `List` collects instead. The type
states both facts, and `Opts.parser` carries them:

```ocaml
type Opts(host : String, tag : List String, verbose : Bool = false)

Opts.parser.spec   -- {tag = "repeated", verbose = "switch"}

Args.read Opts.parser (Proc.args ())
```

`Args.read` is `parse_with` given the whole account. `parse_with` takes a
list of switches alone.

A flag that the spec calls repeated always holds a list. It holds one however
many times it was written, including none. A flag written no times holds
`[]`. It is not a missing field. An absent `Bool` reads as `false` for the
same reason.

`Args` supplies that reading. A JSON document that is missing a key is still
the error it was.

The usage line comes from the same type. A flag cannot be in the type and
missing from the line:

```ocaml
type Flags(port : Port = :8080, timeout : Duration = 30s, verbose : Bool = false)

IO.println_err "usage: probe-args %{Flags.usage} host"
-- usage: probe-args [--port :8080] [--timeout 30s] [--verbose] host
```

The type does not state the shape around the flags. Positional arguments
arrive under `_`. Nothing marks the field that reads them. So the trailing
`host` above is written by hand. See
[`examples/ports/probe-args.wand`](../examples/ports/probe-args.wand).

`--` ends the flags. Everything after it is positional, whatever it looks
like. This is the only way to pass an argument that begins with two dashes:

```ocaml
Args.parse (Decode.field "_" (Decode.list Decode.string)) ["a", "--", "--b"]
-- Ok(["a", "--b"])
```

`--help` is not a flag that a type declares. It asks a question about the
command line. It is not a value in the command line. The answer is a usage
line, not a record. So ask it before you read the arguments:

```ocaml
if Args.help? (Proc.args ())
then (IO.println "usage: probe %{Flags.usage} host"; Proc.exit 0)
else ...
```

`Args.help?` is false after `--`. A `--help` there is an argument like any
other.

`wand script.wand -- ...` already spends one `--` to hand the rest to the
script. A script's own separator is therefore the second one.
`wand script.wand -- -- --weird` gives the script `["--", "--weird"]`, and
`--weird` is a positional argument.

Reading a command line that asks for help, without answering it first, is an
error that says so: `--help expects a value; \`Args.help?\` answers it
instead`.

Only `--name` is a flag. One dash is not, which keeps `-5` an argument.
There are no short flags. A positional argument arrives under `_`:

```ocaml
Args.parse (Decode.field "_" (Decode.list Decode.string)) (Proc.args ())
```

`Proc.args ()` gives the arguments only. There is no program name to skip at
the front. bash has `$0` and C has `argv[0]`; wand has neither.

### `Test`

```ocaml
test               : String -> (Testing 'b 'a -> TestOutcome ! {Raise | 'e}) -> TestOutcome ! 'e
group              : String -> (Unit -> List TestOutcome ! {Raise | 'e}) -> TestOutcome ! 'e
with_shell         : List (String, String) -> (Unit -> 'a ! 'e) -> 'a ! 'e
with_shell_results : List (String, ShellResult) -> (Unit -> 'a ! 'e) -> 'a ! 'e
shell_calls        : (Unit -> 'a ! 'e) -> List 'b ! 'e
without_writes     : (Unit -> 'a ! 'e) -> 'a ! 'e
with_lines         : Path -> List String -> (Unit -> 'a ! 'e) -> 'a ! 'e
writes             : (Unit -> 'a ! 'e) -> List Path ! 'e
with_clock         : (Unit -> 'a ! 'e) -> (Duration, 'a) ! 'e
at                 : DateTime -> (Unit -> 'a ! 'e) -> 'a ! 'e
```

The handle that a test block receives carries `ok`, `not_ok`, `eq`,
`not_eq`, `raises` and `fail`.

The module a test file imports. See [Testing](#testing).

### `Option`

```ocaml
some?     : Option 'a -> Bool
none?     : Option 'a -> Bool
map       : ('a -> 'b ! 'e) -> Option 'a -> Option 'b ! 'e
and_then  : ('a -> Option 'b ! 'e) -> Option 'a -> Option 'b ! 'e
or_else   : (Unit -> Option 'a ! 'e) -> Option 'a -> Option 'a ! 'e
default   : 'a -> Option 'a -> 'a
get!      : Option 'a -> 'a ! {Raise}
to_result : 'a -> Option 'b -> Result 'a 'b
```

`Option 'a` is a built-in generic type: `None | Some 'a`. Its name and its
two constructors need no import. The module holds the functions over it.
Calling one of those needs `import Option`, like any other module.

`Option` says that a value can be absent. `Result` says that an operation
ran and can have failed, and it carries the reason. The two do not mix. Pipe
one into something that expects the other, and you get a type error.

```ocaml
Map.get "k" m |> unwrap        -- Result 'a Int and Option Int are not
                               --   the same type
```

`Option.to_result` is the bridge. Write it where a script decides that
absence now counts as a failure:

```ocaml
Map.get "k" m |> Option.to_result "no such key"   -- Result String 'a
```

`Result.to_option` crosses back, where the reason has nowhere to go.

---

### `Result`

```ocaml
to_option : Result 'b 'a -> Option 'a
ok?       : Result 'b 'a -> Bool
error?    : Result 'b 'a -> Bool
```

`Result 'b 'a` is built in: `Ok v` and `Error e`, with the error type first.
Matching one is the usual way to deal with it and stays the usual way — these
are for what a match cannot say more briefly.

`to_option` drops the reason, which is the point: it is for a caller with
somewhere to put "no value" and nowhere to put "because". `Map.get`,
`List.get` and `Env.get` are each written with it.

`ok?` and `error?` are the same question either way, so the failing branch can
be the one a script is written around, and so either can be handed to
`List.filter` without brackets.

---

## Testing

The `Test` module gives each test a handle, `t`. It carries `ok`, `eq` and
`raises`:

```ocaml
let {test} = import Test

test "add" (fn t -> t.eq 4 (2 + 2))
test "some" (fn t -> t.ok (Option.some? (Some 1)))
test "get! out of bounds raises" (fn t -> t.raises (fn () -> List.get! 9 [1, 2, 3]))
```

- `t.eq expected actual` — passes if the two are equal. The value under test
  goes last, as it does in every wand function, so it pipes:

  ```
  t.eq 4 (2 + 2)
  (2 + 2) |> t.eq 4
  ```

  A failure reads `expected 4, got 5` in both forms. `got` names the code
  under test.
- `t.ok cond` — pass if `cond` is `true`.
- `t.fail why` — fails, and says why. Use it where the test itself went
  wrong, and not where a value differs: an `Error` you did not expect, a
  pattern that should not have matched, a setup step that did not hold.

  ```
  match Args.parse Opts.decoder args with
  | Ok o    -> t.eq :8080 o.port
  | Error e -> t.fail e
  ```

  A failure reads `label: why`. The reason travels with the name of the
  test. wand does not compare it against a value.
- `t.raises thunk` — passes if a call to `thunk ()` raises. `thunk` must be
  a function with no argument, `fn () -> ...`. Do not give the expression
  itself. wand evaluates arguments eagerly, so `t.raises (List.get! 9 xs)`
  raises while it evaluates the argument, before `t.raises` runs.

`let {test} = import Test` binds the one name that the file uses without a
prefix. Add `import Test` beside it, and the other helpers arrive under
`Test.`. Each import brings in what it names, and nothing more.

Put parentheses around the `fn` argument of each `test` call:
`test "x" (fn t -> ...)`. wand does not yet accept a bare `fn` as the last
argument of an application.

### Child tests

`group` runs child tests that share a label and whatever its body binds:

```ocaml
let {test, group} = import Test

group "the report" (fn () ->
  let lines = String.lines (build_report ()) in [
    test "has a header" (fn t -> t.eq "# Report" (List.head! lines)),
    test "is short" (fn t -> t.ok (List.length lines < 40))
  ])
```

wand prints each child under the path of labels that led to it, as in
`ok   the report / has a header`. Groups nest to any depth, because a `group`
is one more child in the list.

The body is ordinary code. So there is no `before` or `after` machinery to
learn:

- Setup is the code above the list. It runs once, and every child shares its
  bindings. A value cannot change, so one child cannot affect another
  through it.
- Teardown is a bracket around the list: `with (FS.temp_dir ()) as dir ->
  [...]`. It releases however the body ends, as it does in any script.
- Mocks wrap the children like any other code:
  `group "pushes" (fn () -> Test.with_shell mocks (fn () -> [...]))`.
- Per-child setup, where each test wants fresh state, is a function:

  ```
  let with_scratch label f =
    test label (fn t -> with (FS.temp_dir ()) as dir -> f t dir)
  ```

A raise in the body is a broken setup, not a failed child. wand reports it
as one failure of the group, under the label of the group. It does not invent
the children that did not run. A raise inside a child is the failure of that
child. Its siblings still run.

Run test files with `wand s`:

```sh
wand s                       # every test_*.wand at or below the current directory
wand s scripts/              # every test_*.wand under scripts/
wand s test_deploy.wand      # just this one
```

Name a test file `test_*.wand`. Put the tests of a script beside the script:
`deploy.wand` and `test_deploy.wand` in one directory. The prefix sorts every
test together, away from the code under test. With no argument, `wand s`
searches from the directory you are in, so you edit a script and run its tests
without a path. `wand s` does not search `_build`, `_opam`, `.git` or
`node_modules`. A file that you name on the command line runs, whatever it is
called.

wand prints each call to `test` as `ok   <label>` or as `FAIL <message>`. A
test whose body raises outside `t.raises` is the failure of that test:
`label: raised: <why>`. The rest of the file still runs. `wand s` exits
non-zero if a test failed, or if a file had a lex, parse or type error.

---

### Testing code that touches the outside world

The risky part of a script is what reaches outside it. A handler can stand
in for exactly that. `Test` covers the common cases, so a test does not write
a handler by hand:

```ocaml
Test.with_shell [(fragment, output), ...] thunk          -- answer commands from a table
Test.with_shell_results [(fragment, result), ...] thunk -- answer `$?()` with whole results
Test.shell_calls thunk                                  -- the commands it would run
Test.without_writes thunk                               -- swallow writes, keep the result
Test.writes thunk                                       -- the paths it would write
Test.at instant thunk                                   -- pin what `Clock.now` answers
```

`with_shell` and `shell_calls` answer a command run either way: `$(cmd)`
gets the output, and `$?(cmd)` gets it as the `stdout` of a `ShellResult`
that exited zero. A test of a failure path supplies the whole result:

```ocaml
test "a red build stops the gate" (fn t ->
  t.eq
    [("test", false)]
    (Test.with_shell_results
      [("dune test", ShellResult(stdout = "", stderr = "", code = 1))]
      (fn () -> gate ())))
```

A command the table misses exits zero with no output.
`$(cmd)` is not intercepted there, because a failure there is a raise and
not a value; nest `with_shell` around it for a body that uses both forms.

Given a deploy that pushes and rewrites a config:

```ocaml
let deploy () =
  let version = $(git describe --tags) in
  let () = FS.write_file! /etc/app/config.toml "version = \"%{version}\"\n" in
  let _ = $(rsync -a ./build/ web@host:/srv/app) in
  "deployed %{version}"
```

Handlers compose, so a script touching two families needs both, nested:

```ocaml
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

The last line is the point. The script ran, and nothing happened.

---

## Comments

A comment starts with `--` and runs to the end of the line. That is the
whole form:

```ocaml
-- this is a comment
let x = 1     -- so is this
```

A comment reads no brackets, so pasted text survives whatever it holds —
including the `*)` that a shell `case` arm writes.

Documentation is a run of comment lines directly above a definition. `wand
d` prints it, and so does an editor on hover:

```ocaml
-- Whether a command succeeded: its exit code is zero.
--
-- `$?(cmd)` gives a `ShellResult`, and the first thing a script asks of one
-- is whether it worked.
let ok? (r: ShellResult) = r.code == 0
```

Each line stands alone, the lines are consecutive, and the last one sits on
the line above the definition. So a comment after code documents nothing,
and a blank line ends the run — which is how a file header stays a file
header.

### Examples in a doc string

A line that opens with the session's prompt is an example, and the lines
under it are what it produces:

```ocaml
-- Keep only elements satisfying a predicate.
--
-- >> List.filter (fn x -> x >= 2) [1, 2, 3]
-- [2, 3] : List Int
let filter _ [] = []
let filter p [h :: t] = if p h then h :: filter p t else filter p t
```

`wand d -x <name>` prints the doc with its examples run where they stand, so
what each one produces now sits where the file says it should. `wand d -t`
asks the other question: it reports only what does not hold, says nothing
when everything does, and exits non-zero if anything does not. Either takes
a module name and covers every name in it.

The standard library's own are a CI gate — `tools/check_docs.wand`, which is
`-t` over every module — because an example is read by someone deciding how
to call a function, and a wrong one is read with the same trust as a right
one.

An expression too long for one line carries on under the continuation
prompt, as it would in a session:

```ocaml
-- >> with FS.temp_dir "ex_" as d ->
-- ..   (let f = Path.join d ./x; FS.write_file! f "hi"; FS.read_file! f)
-- "hi" : String
```

The examples of one doc string run in order, in one session, so a name bound
by one is there for the next. A prompt with nothing under it claims nothing
and is not checked — which is how one example sets up another:

```ocaml
-- >> let counts = {a = 1, b = 2}
-- >> Map.get "a" counts
-- Some(1) : Option Int
```

---

## Style for scripts

Everything in this manual parses anywhere. `examples/` and `demos/` use a
small dialect on purpose, for a reader who comes from the shell and not from
ML. The standard library uses the full language, because the compiler team
writes it and reads it. A script does not have to.

- **One statement per line.** A newline ends a statement, at the top level
  and inside a block alike. Code needs no terminator and no `let () =`. Do
  the thing, then do the next thing. A line indented past the statement above
  it continues that statement instead, as does a line that starts with an
  operator. See [Sequencing](#sequencing).

- **Sequence with `;` in parentheses inside a body.** A function body is one
  expression. So put several statements in parentheses and separate them with
  `;`. See [Sequencing](#sequencing):

  ```
  let backup_all! dest = (
    FS.mkdir! (Path.of_string dest);
    List.each (fn p -> backup_one! dest p) (FS.glob ./*.wand)
  )
  ```

- **Name a value with a `let` in the block, not with a nested `let ... in`.**
  A `let` before a `;` binds for the rest of the block, so two names cost no
  indentation. Keep `let ... in` for naming a value that one expression
  uses. `let () = e1 in e2` still works and still typechecks; the `;` form
  says the same thing without asking the reader what `()` binds. `wand f`
  makes the first half of this rule for you -- a binding whose body is a
  block comes back with the `;` -- and leaves the second to you, because
  `let () =` says something about `e1` that `;` does not.

- **Prefer `match` to several equations.** Two definitions with different
  patterns are legal. The standard library uses that form, as in
  `let failed? (Error _) = true` and `let failed? (Ok _) = false`. A script
  writes one definition and matches:

  ```
  let failed? r =
    match r with
    | Error _ -> true
    | Ok _ -> false
  ```

---

## REPL and CLI

### Running scripts

```sh
wand script.wand          # run a script
wand script.wand arg1     # pass arguments (available via Proc.args)
wand script.wand -- arg1  # everything after -- is the script's, whatever it looks like
```

```sh
wand script.wand --lint            # report the lint findings, then run it
wand script.wand --strict          # a violation is a failure, and does not run
```

A lint is not a type error and not a compiler error: a file that earns one
still runs correctly by the language's own rules. So a plain run does not
lint, and `--lint` is how the verdict is asked for on the way to running.
The findings go to stderr, which leaves stdout the script's.

`--strict` asks for the findings and makes them a condition of running, so
it implies `--lint`: a violation is reported and the script does not run.
Advice does not stop it -- `A-USES1` says a manifest is wider than the file,
which is imprecise rather than unsafe. The two together are one shape for
each end of a script's life: `wand t --strict` while writing it, to clear
everything, and `wand deploy.wand --strict` where it runs, to refuse a file
that has drifted.

`--dry-run`, `--trace`, `--lint` and `--strict` are wand's own wherever they
appear before a `--`, so `wand deploy.wand --dry-run` rehearses. A script
that takes an argument of the same name needs the terminator:
`wand deploy.wand -- --dry-run` runs for real and hands the flag on.

A script can also run itself, with a shebang line and the executable bit:

```ocaml
#!/usr/bin/env wand
uses {IO}
import IO
IO.println "hello"
```

```sh
chmod +x deploy.wand
./deploy.wand
```

#### The compile cache

To load a module is mostly to infer types. On a module with 200 definitions,
that is 5.7 ms of 7.2 ms. So wand keeps the types of a module between runs.

The key of an entry is a hash of the source of the module, and of everything
it imports, at every depth. So an entry for a file that has changed is
unreachable, not merely out of date. The key also covers the binary: its
version, its size and its mtime. The types of a module come from the builtins
as much as from its source. Without that, a builtin with a new signature would
leave each hash correct and each cached type wrong. You never clear the cache,
and there is no timestamp to be wrong about. An entry that wand cannot read is
a miss, not an error.

```sh
WAND_CACHE=0 wand script.wand    # ignore it, and write nothing
```

`0`, `false`, `no` and `off` turn it off. No value, or any other value,
leaves it on. The name of the switch says what it controls, not what it
prevents. So no value reads one way and behaves the other way.

The cache costs the first run of a script a little, and saves each run after
it. A script that imports six stdlib modules goes from 16.2 ms to 12.1 ms. A
script that imports a module with 200 definitions goes from 16.5 ms to
10.9 ms.

#### Environment

| | |
|---|---|
| `WAND_CACHE` | `0`/`false`/`no`/`off` disables the compile cache |
| `WAND_CACHE_HOME` | the cache directory itself |
| `XDG_CACHE_HOME` | a parent for it; wand uses `$XDG_CACHE_HOME/wand` |
| `WAND_STDLIB` | a standard library to use instead of the built-in one |
| `WAND_MAX_CALL_DEPTH` | how deep calls may nest before a run is refused (default 1,000,000) |

The cache goes in the first of these that is set: `WAND_CACHE_HOME`, then
`$XDG_CACHE_HOME/wand`, then `~/.cache/wand`. On Windows it goes in
`%LOCALAPPDATA%\wand\cache`, because Windows keeps nothing in `~/.cache`.

A call with work waiting on it keeps a stack frame; a call in tail position
does not. So a tail-recursive loop runs to any depth, and nesting calls
without end runs out of stack. That used to end the run with OCaml's own
`Fatal error: exception Stack overflow`, which cannot be caught: a handler
that matches it hangs rather than unwinds, because the handler's own guard
runs on the stack that just ran out. wand bounds the depth instead, and
refuses with an error a script can catch.

The default bound is above what any measured run reaches. Lower it when the
stack is smaller than the default -- under `OCAMLRUNPARAM=l=...`, or a small
`ulimit -s` -- because a bound above what the stack can carry never fires
and the fatal comes back.

The standard library is compiled into the binary. So wand runs the same way
from any directory, and a `stdlib/` folder is only a folder. `WAND_STDLIB`
replaces the whole library. A `List.wand` in the directory that it names is
then `List`. Use it to work on the standard library itself, where a built
binary must run against sources on disk.

An empty value counts as no value in each variable here. An empty value
nearly always comes from a shell that interpolated something empty.

### Interactive session

```sh
wand i                    # start session
wand i --load utils.wand  # start with a file preloaded
```

Inside the session:

```text
>> 1 + 2
3 : Int

>> let double x = x * 2
double : Int -> Int

>> double 21
42 : Int

>> List.map double [1, 2, 3]
[2, 4, 6] : List Int
```

This helps the REPL and the one-shot commands. It does not help a script.
See "Standard library modules" under "Imports" above for the list of modules
that wand loads for you. A script that you run with `wand file.wand` always
needs an `import`.

Special commands:

| Command | Long form | Description |
|---|---|---|
| `:c` | `:clear` | Clear the screen |
| `:d [name]` | `:doc` | With no name, list the session's bindings and modules. A module answers with its members and their signatures, as `wand d <Module>` does. A member answers with its doc string |
| `:e [name]` | `:edit` | Open a definition in `$EDITOR` |
| `:h` | `:help` | List these commands |
| `:l <path>` | `:load` | Load a `.wand` file into the session |
| `:r` | `:reload` | Reload the last loaded file |
| `:s` | `:reset` | Clear the screen and all session bindings |
| `:t <expr>` | `:type` | Show type without evaluating |
| `:x` | `:exit` | Exit interactive mode |

The REPL finds multi-line input for you. These keep an entry open: a bracket
that does not close, a trailing `->`, `=`, `|` or `,`, and a keyword with
nothing after it (`then`, `else`, `in`, `with`, `and`). Inside an entry that
already spans lines, a `let` equation that still waits for its `in` or its body
keeps it open too. A blank line submits what you have entered.

History is saved to `~/.wand_history` between sessions.

### One-shot commands

```sh
wand d "List.map"                     # show doc string
wand d -x "List.map"                  # print the doc with its examples run
wand d -t List                        # check a module's examples; silent if right
wand d --json "List.map"              # the same, as JSON for tools
wand -e "1 + 2"                       # evaluate and print result
wand --load config.wand -e "host"     # evaluate in context of a file
wand f script.wand                    # format a file in place
wand f stdlib/*.wand                  # format multiple files in place
wand h                                # show all commands
wand h e                              # help for a specific command
wand s                                # run every test_*.wand from here down
wand s test_deploy.wand               # run named test files
wand s --json                         # per-test results as JSON, for tools
wand t --expr "List.map"              # typecheck an expression
wand d                                # list all names and modules in scope
wand d List                           # list one module's members
wand d --json List                    # the same, as JSON for tools
wand v                                # print the version, as `wand 0.1.0`
```

Each subcommand has a full-word alias: `d`/`doc`, `e`/`eval`, `f`/`fmt`, `h`/`help`, `i`/`interactive`, `s`/`test`, `t`/`type`, `v`/`env`, `V`/`version`.

### Lints

`wand t` reports lint findings with the type. Each finding carries a rule ID.
The prefix says what the rule does to your build. A `V-` rule reports a
violation, and `--strict` makes it an error. An `A-` rule is advisory. It stays
a warning, however you run wand.

A rule must be decidable before it can be must-fix. Decidable does not make
it must-fix. A rule can be exact and still advisory, when a failed build would
punish the safer choice.

| Rule | Fires when |
|---|---|
| `V-PRED1` | a `?`-named function returns something other than `Bool` |
| `V-PRED2` | a `?`-named function also carries an `is_` prefix, which says predicate twice |
| `V-PRED3` | a function that returns `Bool` is not named with `?`, and cannot raise |
| `V-OR1` | a `Result`'s error side is `Unit`, so a failure reports no reason |
| `V-BANG1` | a function that can raise is not named with `!` |
| `V-BANG2` | a `!`-named function cannot raise |
| `V-NAME1` | a signature exposes a parameter whose name ends in `_` |
| `V-DROP1` | a statement's value is a `Result` nothing reads, so a failure is lost |
| `V-DROP2` | a statement's value is a `TestOutcome` nothing reads, so the test cannot fail |
| `V-IMP1` | two imports bind the same name, so the first binding is dead — every use reads the second, above its line as well as below — rename one (`let {parse = csv_parse} = import CSV`) or drop it |
| `V-IMP2` | an import binds nothing the file mentions, so it does nothing — drop the line |
| `V-SHADOW1` | a top-level name is bound twice in one file, so which value the name means depends on the line it is read from — rename one of them |
| `V-CLOCK1` | a length of time is measured by subtracting two readings of `Clock.now`, which a clock step spoils — wrap the work in `Clock.timed` |
| `A-SHELL1` | a `$()` holds a shell pipeline of three or more operators |
| `V-SHELL1` | the manifest narrows `Shell` to named binaries, but a command word is decided at run time |
| `V-SHELL2` | a command runs on to a second line, which starts a second command |
| `A-USES1` | a manifest permits an effect the file does not use, or a binary no command runs |
| `V-USES2` | a file performs effects and declares no manifest |

A name carries one ending. `has_example?!` does not parse, so a function that
returns `Bool` and can raise has no name that answers both conventions. The
`!` wins, and `V-PRED3` stays quiet: the risk is what a caller has to see, and
`V-BANG1` says the same thing from the other side.

`V-IMP2` reads the file and nothing else. An import binds names. Either the
file mentions one of them below, or it mentions none.

An import also brings its module's types and their constructors. This file
does not record which module a type came from. So the rule says nothing about
any import in a file that mentions a type or constructor that it did not
declare and that wand does not build in. The fix deletes a line, and a rule
that deletes cannot guess.

`V-SHADOW1` is about reading, not running. A second `let` of the same name
does not assign to the first: it binds a new value, and anything that closed
over the earlier one goes on reading it.

```ocaml
let limit = 100
let check = fn n -> n < limit     -- reads 100, and always will
let limit = 500                   -- V-SHADOW1: a second `limit`
```

`check` answers against `100` even below the second line. The rule fires on
the second binding, because the first is not dead — that is the point. It
carries no fix: the correction is a name, and only the author has one. A
binding named `_` is exempt, and a name bound inside a function shadows
freely; this is about the top level of a file, where the two bindings can be
hundreds of lines apart. `V-IMP1` covers the same shape for imports, and
reports the *earlier* line, because an import that is rebound really is dead.

`V-DROP1` catches a bug, not a habit:

```ocaml
FS.write_file /etc/app.toml config      -- the Result goes nowhere
IO.println "deployed"                   -- and this prints either way
```

The write can have failed. The script then says that it deployed, and it
exits 0. Match the `Result`, or call `write_file!` and let it raise, or bind it
to `_` if the failure does not matter. `let () = FS.write_file ...` is a type
error for the same reason. This rule catches the shape that says nothing either
way. wand leaves other values alone. To discard a `String` is what a command
run for its effect looks like.

`V-DROP2` is the same mistake with a worse end. A test block answers with one
outcome. So a sequence of assertions discards each one but the last:

```ocaml
test "parses" (fn t -> (t.eq 1 got_a; t.eq 2 got_b))
```

wand throws `t.eq 1 got_a` away, and the test reports a pass however that
first assertion went. Return the one outcome that the block answers with. Or
give each assertion its own `test`, and share the setup with `group`:

```ocaml
group "parses" (fn () -> let doc = parse! source in [
  test "a" (fn t -> t.eq 1 (field_a doc)),
  test "b" (fn t -> t.eq 2 (field_b doc))
])
```

`wand s` refuses a file that this rule fires on. It does not print a verdict
that it does not have. A run that discards its assertions cannot answer the
question you asked.

```sh
wand t --strict script.wand       # violations become errors (exit 1)
wand t --json script.wand         # diagnostics as JSON, for tools
wand t --fix script.wand          # apply the fixes the findings carry
```

### `--fix`

`wand t --fix script.wand` applies each correction that a machine can
apply. It writes the file, checks it again, and repeats until nothing more
applies. One fix can reveal another. A new binary in `Shell(...)` can reveal a
binary that no command runs. The fixes are the `fix` payloads that `--json`
reports: it creates a manifest, replaces one (which includes the line that the
manifest type error suggests), deletes a dead import, and inserts a missing
one. `IO.println` in a file without `import IO` names the module. The missing
line is therefore a correction, not a hint. An inserted import goes under the
manifest. It joins the run of plain imports, in the order that run is kept,
above any destructured `let {a} = import X`. wand prints one line
for each applied fix: `rule: line — what changed`. With `--json` it prints the
applied set in the diagnostics shape. A parse error refuses the whole run, and
so does a type error with no fix. wand writes nothing, because a fix around a
broken file is a guess. A plain `wand t` reports the findings that carry no fix,
and `--fix` leaves them alone.

### `--json`

With `--json`, `wand t` prints one JSON array on stdout, and nothing else.
The array holds one object for each diagnostic. The exit codes do not change.
Without the flag, the output for a person does not change.

Each finding and each error carries `severity`, either `"error"` or
`"warning"`. It carries `code`, such as `V-USES2` or `V-DROP1`. An error gets
`E-TYPE`, `E-PARSE`, `E-LEX` or `E-IMPORT`. It also carries `line`, `col` and
`message`.
`file` appears when a file was checked. A diagnostic that covers a
range also carries `end_line` and `end_col`, which are exclusive. A finding
spans the whole item. A type error spans the whole expression at fault. A lex
error spans the token that failed. Under `--strict`, a must-fix finding reports
as `"error"`. A correction that a machine can apply travels with it, in a `fix`
object. A manifest suggestion carries the exact line:

```json
{"severity":"warning","code":"V-USES2","line":1,"col":1,
 "message":"this file performs FS.Write and does not say so; it could declare \"uses {FS.Write}\"",
 "fix":{"insert_line":"uses {FS.Write}"}}
```

`A-USES1` and the manifest type error carry `fix.replace_line` instead.
`V-IMP1` and `V-IMP2` carry `"fix":{"delete_line":true}`. A drift error whose correction
is one substitution carries `"fix":{"replace":{"from":"and","to":"&&"}}`. A
typed hole has a shape of its own:

```json
{"kind":"hole","type":"Int -> Int -> Int ! 'e"}
```

The query commands also take `--json`. Each one prints one JSON value on
stdout, in place of its text. `wand d --json <name>` prints one object with
`name`, `type` and `doc`. A fact that the session does not have is `null`. wand
does not leave the key out:

```json
{"name":"List.map",
 "type":"('a -> 'b ! 'e) -> List 'a -> List 'b ! 'e",
 "doc":"Apply a function to every element of a list, returning a new list."}
```

`wand d --json` prints an array over the scope. A binding is
`{"name":...,"type":...}`. A module is `{"name":...,"module":true}`.
`wand d --json <module>` prints the members of the module, with qualified
names:

```json
[{"name":"List.all?","type":"('a -> Bool ! 'e) -> List 'a -> Bool ! 'e"},
 {"name":"List.any?","type":"('a -> Bool ! 'e) -> List 'a -> Bool ! 'e"}]
```

`wand s --json` prints one object for the whole run, after the run ends. A
correct JSON value cannot stream test by test. While the tests run, what they
print goes to stderr, so stdout holds the JSON only. A pass carries its
`label`. A fail carries `message`, which starts with the label, because the
`Test` module writes it that way. A test that raised, instead of failing an
assertion, has the status `"error"`. Both count in `failed`, and the exit code
does not change. A file that would not load, from a parse error or a missing
import, appears under `errors` and not under `tests`:

```json
{"tests":[{"file":"test_deploy.wand","status":"pass","label":"it adds"},
          {"file":"test_deploy.wand","status":"fail",
           "message":"it rounds: expected 4, got 3"}],
 "errors":[{"file":"test_broken.wand",
            "message":"parse error: 2:1: unexpected token: EOF"}],
 "passed":1,"failed":1}
```

### Formatter

`wand f <file>...` formats one or more `.wand` files in place. It
overwrites each file with the formatted text, and prints one line for each
file. A shell glob works: `wand f stdlib/*.wand` formats every file in
`stdlib/`.

wand keeps each comment and never drops one. It writes a
function of several equations back as separate clauses, as in
`let f 0 = ...` and `let f n = ...`. It does not leave the `match` that those
equations become.

wand writes the manifest in one canonical form. The labels come in display
order, which is alphabetical: `Env, FS.Read, FS.Write, IO, Proc, Raise, Shell`.
Every rendered effect set and every suggested manifest uses that order. The
binaries inside `Shell(...)` are sorted. If the form passes the column budget,
it wraps to one label per line. A long `Shell(...)` list wraps to one binary per
line in the same way.

In the first run of imports at the top of a file, the plain `import M`
statements come first, in alphabetical order. The let-imports follow, such as
`let {test} = import Test`, in source order. A let-import is an ordinary
binding, so wand never changes the order of two of them. wand leaves a region
with a comment in it exactly as written. An import after the first run stays
where it is.

wand wraps a line to 92 columns. That width fits the pane where people read
code, not the pane where they write it. A split diff gives each side about
ninety columns. A longer line scrolls sideways at the place where people look
hardest. The same width fits wand beside bash in a README or in a terminal
recording.

wand writes an item with a comment inside it exactly as you wrote it. To
format it, wand would decide which expression the comment belongs to now. A
comment moved to the wrong expression is worse than a comment left where its
author put it. Everything else has a formatting rule.

### Language server

`wand l` (or `wand lsp`) starts the language server. It speaks LSP over stdio. It is a
subcommand of the compiler binary, so the editor gets the same inference, the
same lint rules and the same formatter. The two cannot disagree. An editor that connects to it gets seven things. It gets a diagnostic on each
change. It gets hover, which shows the signature with its effect set, and the
doc string. It gets a lens above each definition carrying its inferred type,
which is hover's answer for a whole file at once. It gets completion. It gets
a quick fix that carries the correction that `wand t --fix` applies. It gets
formatting of the whole document. It gets go to definition, and a jump into
the standard library opens the source of the module from the binary, as a
read-only document.

Hover reads the position as well as the word. A label inside `uses {...}` is
an effect and is described as one: `Env` names a module elsewhere in the same
file, and on the manifest line what it declares is the effect that module's
calls perform.

A qualified name resolves as you type it. Write `FS.write_file!` in a buffer
that has not imported `FS`, and the editor inserts `import FS` into the sorted
import block. It also adds `FS.Write` to the manifest. The edit fires only when
the member resolves. A miss gives a diagnostic, never a guess. The edit never
touches `Shell`. To add a binary, to widen the label or to narrow it is always
a quick fix that you can see. The editor extends a manifest. It never creates
one that you did not ask for.

The VS Code extension is at `editors/vscode/` in the wand repository. It has
syntax highlighting, which shows a domain literal as a constant and the shell
inside `$()`. It has the client for `wand lsp`. It has a "Rehearse (dry run)"
code lens on the manifest line, which runs `wand --dry-run` on the file. The
extension is not on the Marketplace yet. Its README says how to build it and
how to sideload it.

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

This needs OCaml 5.x and opam. `wand.opam` names the dependencies.

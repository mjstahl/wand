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
  - [List](#list) · [String](#string) · [Regex](#regex) · [Map](#map) · [FS](#fs) · [Resource](#resource) · [Stream](#stream) · [Path](#path) · [IO](#io) · [Float](#float) · [Proc](#proc) · [Env](#env) · [CSV](#csv) · [JSON](#json) · [TOML](#toml) · [Duration](#duration) · [Par](#par) · [Shell](#shell) · [Decode](#decode) · [Args](#args) · [Test](#test) · [Option](#option)
- [Testing](#testing)
- [Comments](#comments)
- [Style for scripts](#style-for-scripts)
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
wand v                  # list all names in scope
wand f script.wand      # format a file in place
wand s                  # run every test_*.wand from here down
wand h                  # help
wand V                  # print the version
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

`Int` is a machine word. It holds `-4611686018427387904` to
`4611686018427387903`. A literal outside that range is a lex error.
Arithmetic that goes outside it is a runtime error. The value does not wrap
around:

```
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

```
let double x = x + x     -- double : Num -> Num
(double 2, double 1.5)   -- (4, 3) : (Int, Float) — each call picks its type
```

`Num` in a signature means `Int` or `Float`. The use site decides which.
It appears in [Type annotations](#type-annotations) like any type name.
Float division does not raise: `1.0 / 0.0` is infinity, as IEEE 754 says.
Int division keeps its check.

String interpolation with `%{...}`, which takes any expression:

```
let name = "world"
"hello, %{name}!"        -- "hello, world!"
"1 + 1 = %{1 + 1}"       -- "1 + 1 = 2"
"home is %{$HOME}"       -- reads the environment, like any other expression
```

`$` is not special in a string. A string that holds shell or Make source
keeps it. This is what you want when something else expands the string:

```
"export PATH=$HOME/bin:$PATH"   -- exactly those characters
```

For the literal text `%{`, escape the percent: `"\%{not an interpolation}"`.

String concatenation with `++`:

```
"foo" ++ "bar"           -- "foobar"
```

### Backtick strings

Between backticks each character is itself. There are no escapes. A quote
is a quote, and a backslash is a backslash. Use this form for text written in
another language:

```
`{"hello": "world"}`
`\d+\s*(\w+)`
`C:\Users\ada`
```

A backtick string spans lines, and the layout is the text. A newline
directly after the opening backtick is not part of it, so a literal can start
on the line below. wand trims nothing else. Indentation and the final newline
stay:

```
`
Hello World
This was a line break
`
```

is `"Hello World\nThis was a line break\n"`.

`%{...}` still interpolates, so a backtick string is a template like any
other:

```
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

```
`ab` ++ `c`                    -- "abc"

match answer with
| `yes` -> 1
| _     -> 0
```

---

## Lexical domain types

wand has literal syntax for the values a script uses most. Each one is a
type of its own, not a string. So the type checker catches a `Date` that you
gave where a `Duration` belongs.

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

The equations are one definition. Write them on consecutive lines. Give
each one the same number of parameters. wand tries them in the order you wrote
them. If an earlier equation already covers a later one, that is an error:

```
let f _ = 0
let f 1 = 1     -- error: equation 2 for 'f' is unreachable
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

```
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

In the REPL, enter a group as one entry. The first line alone does not
typecheck, because its partner is unbound. So put the `and` at the end of the
line. Do not start the next line with it:

```
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

---

## If expressions

```
if x > 0 then "positive" else "non-positive"
```

An `if` with nothing to do when the condition is false leaves the branch out:

```
if stashes > 0 then println "Stashes: %{stashes} saved"
```

This is the same expression as `else ()`. It is not a second kind of
conditional. The branch must be `Unit`, because a branch that is not there can
only be `()`:

```
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

```
[1, 2, 3] |> List.map double |> List.filter (fn x -> x > 2)
$(git log --oneline) |> String.lines |> List.length
```

**Form 2 — stdin threading.** The right operand is literally a `$()` or a
`$?()` form. Then `|>` sends the left value, a `String`, to the standard input
of the command:

```
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

```
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

```
println "starting";
println "working";
42
```

A newline alone ends a statement, so at the top level of a file `;` is only
needed to put several on one line or to make the sequencing explicit.

A newline does not end a statement if the next line starts with an operator.
That line continues the statement. A pipeline that leads with `|>` needs
this:

```
let count =
  names
    |> List.filter short?
    |> List.length
```

`-` follows the same rule, and there it can surprise you. These two lines
are one statement, and `a` is `-1`:

```
let a = 1
-2
```

Write `let b = -2` if you want a second statement.

Inside a function body — or anywhere else an expression is expected — a
newline cannot separate statements, because inside brackets a newline is just
formatting and an application may continue across it. There, statements
sequence with `;` inside parentheses:

```
let deploy! target = (
  FS.mkdir! (Path.of_string target);
  FS.write_file! (Path.of_string "%{target}/config.toml") "version = \"1\"\n";
  "deployed"
)
```

The value of the sequence is the last expression; a trailing `;` before the
`)` is allowed. Every statement before the last is discarded, so a discarded
`Result` is flagged by `V-DROP1` exactly as a bare top-level statement's
would be — match it, call the `!` sibling, or bind it to `_` to say the
failure does not matter. `let () = e1 in e2` still works and means the same
thing, with the stricter guarantee that `e1` must be `Unit`.

---

## Pattern matching

```
match x with
| 0 -> "zero"
| 1 -> "one"
| n -> "other: %{n}"
```

With guards:

```
match n with
| x when x < 0  -> "negative"
| x when x == 0 -> "zero"
| _             -> "positive"
```

### Exhaustiveness checking

`wand t` checks that each `match` covers every case. A case that is missing
is a type error, not a surprise during a run:

```
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
| [x]       -> "one element: %{x}"
| [x, y]    -> "exactly two"
| [h : t]   -> "head %{h}, tail %{t}"
```

Cons patterns chain, matching several leading elements at once:

```
match xs with
| [a : b : c : t] -> "first three: %{a}, %{b}, %{c}, rest: %{t}"
| _               -> "fewer than three elements"
```

The same patterns work in a `let`, with one difference. A `match` arm gives
the whole shape, because a longer list belongs to another arm. A `let` has no
other arm. It only binds. So in a `let` a list pattern names the first
elements and ignores the rest. A map pattern behaves the same way with
keys:

```
let xs = [1, 2, 3]

let [a, b, c] = xs      -- a = 1, b = 2, c = 3
let [a, b]    = xs      -- a = 1, b = 2, the 3 is not consulted
let [h : t]   = xs      -- h = 1, t = [2, 3]
```

The shape of a tuple is part of its type. So a wrong pattern for a tuple is
a type error. The length of a list is not part of its type. So a `let` that
names more elements than the list holds is accepted, and it fails during the
run:

```
let [a, b] = [1]
-- runtime error: pattern match failure
```

Use `match` when even the elements you name may not be there.

Multi-equation over lists:

```
let sum []      = 0
let sum [h : t] = h + sum t
```

---

## Maps

String-keyed, homogeneous maps. The type is `Map T` where `T` is the value type.

```
let m = {x = 1, y = 2, z = 3}   -- Map Int
```

A key is any string. Put quotes around a key that is not an identifier.
Most keys in a document from elsewhere need them:

```
{"content-type" = "application/json", "@type" = "Pod", name = "web"}
```

Quoted keys work in patterns too: `| {"content-type" = v} -> v`.

A map holds a key once. Give a key twice, and the last value wins. The key
keeps the position where it first appeared. That is what an assignment means.
It also writes a document back in the order it arrived:

```
{a = 1, b = 2, a = 9}        -- {a = 9, b = 2}
Map.set "b" 99 {a = 1, b = 2, c = 3}   -- {a = 1, b = 99, c = 3}
Map.merge {a = 1, b = 2} {b = 9}       -- {a = 1, b = 9}
```

A JSON document can name a key twice, but a `Map` cannot hold one twice.
Each reader takes the later value: `JSON.field`, `Decode.field`, and the `Map`
from `JSON.get_object`. So two readers of one document always agree.

Using the `Map` module:

```
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

```
match m with
| {x, y} -> x + y            -- binds x and y by name
| {x = a, y = b} -> a + b    -- the rename form

let {x} = m in x             -- extract just x; other keys ignored
```

A key that the map does not hold fails during the run. A list of the wrong
length fails the same way. The keys of a map are not part of its type.

An empty map is `Map.empty`, and `{}` is the same value written as a
literal.

Brackets mean lists and nothing else. wand refuses the map forms from
before 0.17, `[x = 1]` and `[x = a]`. The error names the brace spelling.

---

## Shell execution

Run a shell command and get its stdout as a `String`. Raises on non-zero exit.

```
$(git status)
$(ls -la)
$(git log --oneline -%{count})      -- values go in with %{...}
```

Get full output without raising using `$?()`, which returns a `ShellResult`:

```
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

```
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

```
let name = "$(whoami)"
$(echo "hi %{name}")        -- runs: echo "hi \$(whoami)"    (one argument)
$(grep "^%{name}" log)      -- the value is part of the pattern
```

**Raw interpolate — `%!{x}`.** wand puts the value into the command as shell
source, and the shell reads it. Use this form for a value that holds several
arguments, a pattern to expand, or a whole command:

```
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

```
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

```
$(git log --oneline)
  |> $(grep "fix")
  |> $(wc -l)
```

The stderr of a command is the stderr of the script. It appears as the
command writes it. `$?()` captures it instead. Stdin changes neither
form.

Combined with regex:

```
$(git log --oneline)
  |> String.lines
  |> List.filter (Regex.match? r/fix|bug/i)
```

---

## Glob

`Glob` is a type of its own, not a `Path`. It is a pattern for a set of
files. A glob literal uses `*`, `**`, `?` or `[...]`:

```
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

```
'file*.txt' should be written as './file*.txt'
```

`FS.glob` accepts a `Glob`, not a `Path`. Give it a `Path` and you get a
type error:

```
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

`match_all` returns each match in order. The matches do not overlap. Use it
with an alternation pattern to make a simple tokenizer:

```
Regex.match_all r/[a-zA-Z_]\w*|[{}=,]|"[^"]*"|\d+/ "block{x=\"1\"}"
-- ["block", "{", "x", "=", "\"1\"", "}"]
```

Compile a pattern during the run, for example a pattern from the user:

```
match Regex.compile pattern with
| Ok re  -> Regex.match? re input
| Error e -> false
```

---

## Errors and `try`

An operation that can fail returns a `Result`. Its `!` sibling raises
instead. `try` runs an expression and turns a raise back into a `Result`. So
you choose the place where raising code becomes a value again:

```
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

```
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

```
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

```
let f : Unit -> String ! {Shell} = fn () -> $(git status)
-- type error: cannot unify effects {Shell} with {Raise, Shell | ..}
```

Use this in one case: the type must say that the effects of one part are the
same as the effects of another part. To say that, name the same variable
twice. There is no other way. Inference cannot see a relationship that the
type does not mention. A field that holds a function is the case that needs
it. See
[A function kept in a field keeps its effects](#a-function-kept-in-a-field-keeps-its-effects).
Everywhere else, write no effects and let wand infer them.

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

A label answers one question: what can this touch? So a label is coarse. It
must fit in a signature, and you must be able to hold all seven in your
head.

### They are inferred, however deep

```
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

```
let countdown n =
  if n == 0 then () else let () = IO.println "%{n}" in countdown (n - 1)

countdown       -- Int -> Unit ! {IO}
```

### `try` and `handle` take effects away

`try` converts a raise into a `Result`, so `Raise` does not escape it:

```
fn () -> $(git status)          -- Unit -> String ! {Raise, Shell}
fn () -> try ($(git status))    -- Unit -> Result String String ! {Shell}
```

This is why an operation and its `!` sibling differ by one effect. The plain
one is `try` over the raising one:

```
FS.read_file!   Path -> String ! {FS.Read, Raise}
FS.read_file    Path -> Result String String ! {FS.Read}
```

A handler removes an effect when its cases cover **every operation that
effect carries**:

```
fn () -> handle (Proc.exit 1) with
         | Proc!exit _ k -> k 0        -- Unit -> 'a
```

`Proc` is gone. It carries one operation, so one case covers it. Nothing
left in the body can end the process.

Covering some of them is not enough:

```
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

```
type Action = Action (Unit -> String)

let a = Action (fn () -> $(git push))
let fire x = match x with | Action f -> f ()
```

wand takes the effects from the value that builds the field. So `fire`
performs `Shell`, and a file that calls it declares `Shell`. A named field
behaves the same way, through dot access or through a match.

A field can take a function and pass its effects on. To say so, name the
same variable twice. The effects of a written type are part of that type:

```
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

```
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

```
uses {FS.Write, Shell}
```

This is the one place where you write effect labels. The manifest goes
first, before everything but a shebang and comments. A reader sees the bound
without a search. A manifest that could be anywhere is worth no more than no
manifest.

A file without a manifest is unconstrained, so casual scripts pay nothing.

### Doing more than you declared is an error

The manifest is checked against everything the file defines, not only what
running it performs — a function that shells out still shells out when
another file imports and calls it.

```
$ wand t --file deploy.wand
Error: type error: 'publish' performs Shell, which the manifest does not allow.
       The manifest should be:  "uses {Shell(rsync), FS.Write}"
```

The error names the binding that introduced the effect. It also gives the
line to write, so you copy it instead of working it out. If every command word
in the file is literal, the suggested `Shell` names the binaries it saw. See
[Naming the binaries](#naming-the-binaries-shellgit-curl). If one word is not
literal, the suggestion is bare `Shell`.

### Declaring more than you use is a warning

```
warning: 1:1: A-USES1: the manifest permits Shell, which this file does not
         use; it could be "uses {FS.Write}"
```

To permit more than you need is the safe direction. A build that failed here
would punish caution. So this stays advisory, and `--strict` leaves it
alone.

### Performing effects without saying so is a warning

```
warning: 1:1: A-USES2: this file performs Shell, FS.Write and does not say
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

```
uses {Shell(git, curl), FS.Write}
```

Write each name as it appears inside `$()`. `Shell(git, docker-compose,
node.js, g++, /opt/bin/deploy)` all work without quotes. Use quotes only for a
name that wand cannot lex as one name, such as `"7zip"` or a name with a
space. Bare `Shell` stays legal and means any binary. It is the honest
spelling for a script that is open-ended. `Shell()` is a parse error: a file
that runs nothing drops the label.

What is checked, and when:

- **`wand t` checks each literal command word.** These are the first word
  of each `$()` and `$?()`, and the first word after each top-level `|`,
  `&&`, `||` and `;`. A word that the list omits is a type error. The error
  names the word and the manifest line that admits it. wand skips a prefix
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
- **You cannot narrow shell control flow.** A reserved word in command
  position, as in `$(for f in *; do ...; done)`, is a type error under a
  narrowed manifest. Neither check can bound what the body runs. The
  message tells you to write the loop in wand, or to declare bare
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

```
test "deploy pushes once" (fn t ->
  let outcome =
    handle deploy () with
    | Shell!run _ k -> k "mocked output"
  in t.eq outcome "done")
```

A case names the operation that it intercepts. The name is the call you
would make, with a `!` in place of the dot. You call `FS.read_file`. You
intercept `FS!read_file`:

```
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

```
| FS!write_file (path, _) k -> path ++ "!" ++ k ()
-- cannot unify Path with String

| FS!read_file _ k -> k 42
-- cannot unify String with Int
```

`Shell!run` and `Shell!capture` are the exception. Each one carries a
command, or a command and the stdin for it. There is no single payload type to
check a case against, so wand leaves these two open.

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

The intercepted code stops there, and it gives back what it holds. A `with`
inside it releases on the way out. So a mock cannot leak the resources of the
code that it replaces.

The operations you can intercept are the builtins that touch the world
outside. Each name has the form `Family!verb`. The family is the one that
appears in an effect set:

| Family | Operations |
|---|---|
| `Shell` | `run`, `run_quiet`, `capture`, `exit_code` |
| `FS` | `read_file`, `stream_lines`, `write_file`, `append`, `create_file`, `delete`, `delete_tree`, `copy`, `rename`, `mkdir`, `list_dir`, `glob`, `exists`, `file`, `dir`, `size`, `mtime`, `cwd`, `temp_file`, `temp_dir` |
| `Env` | `get`, `set`, `clear`, `all`, `args`, `home`, `user`, `parse_dotenv` |
| `IO` | `print`, `println`, `print_err`, `println_err`, `read_line`, `read_all`, `flush`, `stdin_lines` |
| `Proc` | `exit` |

Type `FS!` in an editor, and it lists them. Each entry says what the
operation carries and what performs it. The editor reads the table that the
typechecker reads. Nothing performs `Shell!run_quiet` or `Shell!exit_code`. A
case for either one is legal, and it never fires.

There is no `perform` keyword. A script cannot define an effect operation.
It can only intercept a built-in one.

Use `handle` at a boundary: to mock in a test, to audit what another module
attempts, or to retry. `try` and `Result` handle errors. `handle` is not a
control-flow form.

---

## Resource brackets

You must give some things back: a temp file, a lock, a directory that you
changed into. `with` acquires one, binds it, runs a body, and releases it:

```
with FS.temp_file "build_" ".tar" as archive ->
  let () = FS.write_file! archive contents in
  publish! archive
```

**A `with` always releases, however the script ends.** The script can
return, raise, call `Proc.exit`, meet a handler that answers without resuming,
take Ctrl-C, or take a `kill`. There is no `defer`, no `trap`, and nothing to
remember at each exit.

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

```
with FS.temp_file "wand_" ".txt" as scratch ->
with FS.temp_file "wand_" ".log" as log ->
  ...
```

### A resource is a description

`FS.temp_file "wand_" ".txt"` creates no file. It describes how to create
one and how to remove it. So you can name it, pass it to a function, and use
it more than once. Each `with` acquires again:

```
let scratch = FS.temp_file "wand_" ".txt"

let first  = with scratch as p -> Path.to_string p
let second = with scratch as p -> Path.to_string p   -- a different file
```

Build your own with `Resource.make`. Give the two halves in one place, so
they cannot drift apart:

```
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

```
let f () = with FS.temp_file "wand_" ".txt" as _ -> 1
-- f : Unit -> Int ! {FS.Read, FS.Write, Raise}
```

A bracket makes sure that the release runs. It does not hide the file from
the signature.

---

## Decoders

Data from outside a script has no type: a JSON document, a config file, the
output of a command. A `Decoder a` says how to read an `a` out of it:

```
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

```
.items[3].metadata.name: expected String, got Int
.spec.replicas: no such field
```

The path is the point. Read fields one at a time, and a wrong name gives you
a null. The run continues and fails later, somewhere else. A decoder stops at
the field that was wrong, and it names that field.

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

`map2` covers a record with two fields. For a wider record, chain through
`and_then`. Validation also goes there:

```
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

```
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

```
{"web-01": 3, "db-01": 12}   Decode.dict Decode.int   -- Ok (Map of 2)
{"a": 1, "b": "x"}           Decode.dict Decode.int   -- Error .b: expected Int, got "x"
```

`Decode.nullable` is the sibling of `optional`, one level down. `optional`
asks whether a field is there. Only a lookup can ask that. `nullable` asks
whether a value is null. An element of a list raises that question:

```
[1, null, 3]   Decode.list (Decode.nullable Decode.int)   -- Ok [Some 1, None, Some 3]
```

### Domain literals decode as themselves

```
Decode.path  Decode.duration  Decode.url   Decode.size  Decode.version
Decode.date  Decode.time      Decode.datetime  Decode.ipv4  Decode.cidr  Decode.port
```

`"30s"` in a document lexes as `30s` in a script. So the boundary gives you
the type that the rest of the program uses. You do not convert a `String`
later. Each of the twelve domain types has a decoder.

Each decoder reads what the source could hold, and nothing that the source
would refuse. The same lexer decides both. `port` shows this best. A script
writes `:8080`, and a document usually holds the bare number. `8080`, `"8080"`
and `":8080"` all read. A port is 0 to 65535, so `65536` and `-1` do not. The
failure gives the rule, not only the refusal:

```
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

```
{"restarts": 4}     Decode.int   -- Ok 4
{"restarts": "4"}   Decode.int   -- Ok 4
```

The reverse never happens. `Decode.string` does not take a number and make a
string of it. A `string` that accepts anything is the scrape that this layer
replaces:

```
{"restarts": 4}     Decode.string   -- Error .restarts: expected String, got Int
```

### Running one

Each backend presents what it read in the same shape. So the combinators
above are the whole surface. Only the source of the data changes:

```
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

```
[2].restarts: expected Int, got "many"
```

### A type is its own decoder

A type with one constructor and named fields already says what its decoder
does. So it has one:

```
type Pod (name : String, restarts : Int, timeout : Duration)

JSON.decode Pod.decoder (JSON.parse! out)   -- Result String Pod
```

`Pod.decoder : Decoder Pod` reads each field by its own name. Add a field to
the type, and the decoder reads it. There is no second copy to keep in
step.

A field whose type is an `Option` can be absent. Every other field must be
there. The type already says this:

```
type Job (name : String, owner : Option String)

{"name": "build"}                  -- Ok (Job (name = "build", owner = None))
{"name": "build", "owner": 3}      -- Error .owner: expected String, got Int
```

Fields may hold lists, other derivable types, and the type being defined:

```
type Node (label : String, children : List Node)
```

A type with parameters takes one decoder for each parameter, in the order
that the type declares them:

```
type Paged 'a (items : List 'a, total : Int)

Paged.decoder : Decoder 'a -> Decoder (Paged 'a)
Paged.encoder : ('a -> JSON) -> Paged 'a -> JSON

JSON.decode (Paged.decoder Pod.decoder) doc
```

Derivation covers a flat record whose keys are its field names. Write a
decoder by hand for a document with nested keys, with other names, or with
values to validate. Derivation removes the dull decoders, not the interesting
ones. The two mix freely:

```
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

A type with more than one constructor has neither. Name one, and the error
says which:

```
type Shape = Circle Int | Rect Int Int
Shape.decoder
-- type 'Shape' has no derived decoder: it has more than one constructor
```

### Writing it back out

The same type gives an encoder. It is an ordinary function, not a type of
its own. Encoding cannot fail, so there is nothing to carry:

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

A field that holds `None` is left out. It is not written as null. Both read
back as `None`, and a config file is tidier without the empty keys.

### Decoding is pure

The functions that build a decoder carry the empty effect set. So a decoder
cannot read a file, and it cannot run a command. The caller gets the data, and
the signature of the caller says so.

```
Decode.map2 (fn a b -> let _ = $(echo hi) in a) Decode.int Decode.int
-- type error: cannot unify effects {} with {Raise, Shell | ..}
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

Every type a definition mentions has to exist. Declaration order does not
matter — a file's types are collected before any of them is read, so a field
may name a type declared further down, and two types may refer to each other:

```
type Pod  = Pod (metadata : Meta, status : Status)
type Meta = Meta (name : String, namespace : String)
type Status = Running | Pending
```

A name that is declared nowhere is an error, rather than a type of its own:

```
type Pod = Pod (metadata : Meta, status : Statsu)
-- type error: unknown type 'Statsu' in field 'status' of 'Pod'
--   (did you mean 'Status'?)
```

A type from another module needs that module imported, the same as its
functions do:

```
import Option
type Slot = Slot (owner : Option String)
```

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

### Named fields

Fields may be named instead of positional, and are then given and read by
name rather than by position. For a type with one constructor there is a
shorthand: `type Point (x : Int, y : Int)` means
`type Point = Point (x : Int, y : Int)`. The shorthand is the canonical
form — `wand f` writes the long spelling back to it whenever the one
constructor bears the type's own name.

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

Fields are named, in any order, and every one has to be given:

```
Point (x = 1, y = 2)
Point (y = 2, x = 1)    -- same thing

Point (x = 1)
-- type error: constructor 'Point' is missing field 'y'
```

#### Pattern matching on named fields

A pattern may name fewer fields than the type has — naming one is how you
read it:

```
let magnitude p =
  match p with
  | Point (x = a, y = b) -> a * a + b * b

let area c =
  let Circle (radius = r) = c in
  r * r

let just_x p = match p with | Point (x = a) -> a
```

#### Named fields in a type with several constructors

Named fields are not limited to the single-constructor form:

```
type Node = Leaf (value : Int) | Branch (left : Node, right : Node)
```

Constructing and matching work as above. Dot access is narrower: a value of
`Node` is a `Leaf` or a `Branch`, and which one is not known at the access,
so a field is readable only when *every* constructor carries it, at the same
type.

```
type Sized = Small (x : Int, u : Int) | Large (x : Int, w : Int)

(Large (x = 7, w = 9)).x     -- 7, every constructor has x
```

```
type Mixed = Counted (x : Int) | Named (y : String)

let v = Named (y = "hi")
v.x
-- type error: field 'x' is not on every constructor of 'Mixed': Named does
--   not have it, so which constructor a value holds decides whether 'x' is
--   there. Match on the constructor instead
```

Match on the constructor to read a field only some of them have.

A pattern that names one constructor of several can fail, and a binding that
uses one says so: `let area (Circle (radius = r)) = r` over
`Circle | Square` has type `Shape -> Int ! {Raise}`, and the `!` belongs in
its name. What decides this is whether the value could be another
constructor, not whether the fields are named — with a single-constructor
type there is nothing to mismatch, and the same binding is total. It reads
the same for `let`: `let Ok v = r in ...` raises where it stands.

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

A variable there is a promise that the function works for any type, and it
is checked like the rest of the annotation. Naming one the body cannot keep
is a type error, in both directions:

```
let f : 'a -> 'a = fn x -> x + 1
-- type error: the annotation says 'a, which stands for any type, but the
--   body works only for Int

let g : 'a -> 'b = fn x -> x
-- type error: the annotation says 'b and 'a are separate types, but the
--   body makes them the same
```

An annotation narrower than the body is still fine — `Int -> Int` over the
identity names no variable and so promises nothing.

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
let m : Map (List Int) = {a = [1, 2], b = [3]}   -- parens needed for a compound argument
```

`:t` prints types in exactly this syntax, so what you see there is always
what you can paste back into an annotation. That includes `Num`: each
written `Num` is a fresh "`Int` or `Float`" variable, and use-sites link
them — `let double : Num -> Num = fn x -> x + x` reconstructs exactly
what `:t double` printed.

### The three colons

`:` means three things, and position decides which:

```
let port : Port = :8080     -- annotation, then a port literal
let xs = 1 : [2, 3]         -- cons
```

- **A port literal** is `:` glued directly to a digit: `:80`, `:8080`. The
  lexer decides this one — no space and a digit following make it one
  token.
- **A type annotation** is the `:` right after a binding's name and
  parameters in a `let`: `let x : Int = ...`, `let f a b : Int = ...`.
  Only that position (and a type definition's named fields) reads `:` as
  an annotation.
- **Cons** is every other `:` between expressions, and the list pattern
  `[h : t]`. Expression position always means cons — which is why an
  inline OCaml-style ascription `(e : T)` does not exist; annotate the
  binding instead.

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
`String`, `Path`, `FS`, `IO`, `Float`, `Duration`, `Env`, `Map`, `Regex`,
`JSON`, `TOML`, `CSV`, `Option`, `Par`, `Resource`, `Stream` and `Proc`.

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

Import specific names from a module by naming them in braces:

```
let {foo = bar}            = import ./utils   -- bind utils.foo as bar
let {foo = a, bar = b}     = import ./utils   -- and utils.bar as b
```

The name on the left of the `=` is the module's; the name on the right is
what it is called here.

Or bind names under their own names — the same punning a map pattern has:

```
let {foo, bar} = import ./utils         -- bind foo and bar
```

Punned and renamed entries mix freely, exactly as they do in a map
pattern.

#### What a destructure binds by

Brackets destructure a list, braces a map or a module, and what they
match on differs in each — the value on the right decides:

```
let [a, b]      = [10, 20]         -- a list: by position
let {x = a}     = m                -- a map: by key
let {map}       = import List      -- a module: by name
let {map = m2}  = import List      -- a module: by name, renamed
```

A list pattern is the only one that is positional, and the difference shows
when the order changes. Swap two names in a list pattern and the bindings
swap with them; swap them in a module's and nothing moves, because there is
no order to follow:

```
let {filter, map} = import List
map (fn x -> x * 2) [1, 2]     -- [2, 4] — still List.map
```

Only a list can be too short at run time in a way its type did not catch;
a module is checked when it is imported, and a missing name is an error
there.

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

```
map        : ('a -> 'b ! 'e) -> List 'a -> List 'b ! 'e
filter     : ('a -> Bool ! 'e) -> List 'a -> List 'a ! 'e
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
any        : ('a -> Bool ! 'e) -> List 'a -> Bool ! 'e
all        : ('a -> Bool ! 'e) -> List 'a -> Bool ! 'e
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
```

`each` takes the element, as `map` and `filter` do, and returns `Unit` — it
is for side effects. Whatever the function returns is dropped, so a command
run for its effect needs no ceremony: `$()` hands back stdout whether or not
the command wrote any. When the position is wanted, `indexed` supplies it:

```
files |> List.each (fn p -> FS.copy! p (Path.join dest (Path.basename p)))
files |> List.indexed |> List.each (fn (i, p) -> IO.println "%{i}: %{p}")
```

### `String`

```
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
chars        : String -> List String
join         : String -> List String -> String
lines        : String -> List String
words        : String -> List String
of_int       : Int -> String
to_int       : String -> Result String Int
to_float     : String -> Result String Float
to_bool      : String -> Result String Bool
to_path      : String -> Path
to_url       : String -> Result String Url
to_ipv4      : String -> Result String IPv4
to_cidr      : String -> Result String CIDR
to_port      : String -> Result String Port
to_version   : String -> Result String Version
to_size      : String -> Result String Size
to_date      : String -> Result String Date
to_time      : String -> Result String Time
to_datetime  : String -> Result String DateTime
to_duration  : String -> Result String Duration
```

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

```
compile     : String -> Result String Regex
match?      : Regex -> String -> Bool
capture     : Regex -> String -> List String
replace     : Regex -> String -> String -> String
replace_all : Regex -> String -> String -> String
split       : Regex -> String -> List String
match_all   : Regex -> String -> List String
```

### `Map`

```
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

Each fallible operation comes as a pair: the plain name returns a `Result`,
the `!` sibling raises. Every one names its file with a `Path`.

```
read_file    : Path -> Result String String ! {FS.Read}
write_file   : Path -> String -> Result String Unit ! {FS.Write}
append       : Path -> String -> Result String Unit ! {FS.Write}
create_file  : Path -> Result String Unit ! {FS.Write}
mkdir        : Path -> Result String Unit ! {FS.Write}
delete       : Path -> Result String Unit ! {FS.Write}
rename       : Path -> Path -> Result String Unit ! {FS.Write}
copy         : Path -> Path -> Result String Unit ! {FS.Write}
list_dir     : Path -> Result String (List Path) ! {FS.Read}
mtime        : Path -> Result String DateTime ! {FS.Read}
size         : Path -> Result String Int ! {FS.Read}
stream_lines : Path -> Stream {FS.Read, Raise | ..} String
```

The `!` siblings return the value and carry `Raise`:

```
read_file!   : Path -> String ! {FS.Read, Raise}
write_file!  : Path -> String -> Unit ! {FS.Write, Raise}
append!      : Path -> String -> Unit ! {FS.Write, Raise}
create_file! : Path -> Unit ! {FS.Write, Raise}
mkdir!       : Path -> Unit ! {FS.Write, Raise}
delete!      : Path -> Unit ! {FS.Write, Raise}
rename!      : Path -> Path -> Unit ! {FS.Write, Raise}
copy!        : Path -> Path -> Unit ! {FS.Write, Raise}
list_dir!    : Path -> List Path ! {FS.Read, Raise}
mtime!       : Path -> DateTime ! {FS.Read, Raise}
size!        : Path -> Int ! {FS.Read, Raise}
```

Questions and lookups cannot fail, so they have no pair:

```
exists?      : Path -> Bool ! {FS.Read}
file?        : Path -> Bool ! {FS.Read}
dir?         : Path -> Bool ! {FS.Read}
cwd          : Unit -> Path ! {FS.Read}
glob         : Glob -> List Path ! {FS.Read}
glob_in      : Glob -> Path -> List Path ! {FS.Read}
```

```
temp_file    : String -> String -> Resource {FS.Read, FS.Write, Raise | ..} Path
temp_dir     : String -> Resource {FS.Read, FS.Write, Raise | ..} Path
```

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

A file wand creates is created 0644, and a directory 0755, before the
umask has its say. `copy` is the exception: a new destination is given the
source's own permissions, so a copied script is still executable and a
copy of a private file is still private. A destination that already exists
keeps the permissions it had.

### `Resource`

```
make : (Unit -> 'a ! 'e) -> ('a -> Unit ! 'e) -> Resource {..} 'a
```

A resource pairs an acquire with a release, and `with` is the only thing
that runs one. See [Resource brackets](#resource-brackets).

### `Path`

```
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

`basename` returns a `Path`, as `parent` and `dirname` do — a basename is a
one-segment relative path, and joining it onto a directory is the usual next
step:

```
FS.copy! p (Path.join dest (Path.basename p))
```

`extension` and `components` return text, because an extension and a list of
segments are not paths. Use `Path.to_string` when the text of a basename is
what you want.

### `IO`

```
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

```
of_list   : List 'a -> Stream {..} 'a
map       : ('a -> 'b ! 'e) -> Stream {..} 'a -> Stream {..} 'b
filter    : ('a -> Bool ! 'e) -> Stream {..} 'a -> Stream {..} 'a
take      : Int -> Stream {..} 'a -> Stream {..} 'a
fold_left : ('a -> 'b -> 'a ! 'e) -> 'a -> Stream {..} 'b -> 'a ! 'e
each      : ('a -> 'b ! 'e) -> Stream {..} 'a -> Unit ! 'e
to_list   : Stream {..} 'a -> List 'a ! 'e
```

Reading through a file without reading it in. A stream describes a
source and its stages; nothing is read until a terminal operation
(`fold_left`, `each`, `to_list`) runs it: open, each line through the stages, close on
the way out however the run ends. Like a `Resource`, a stream describes;
it is never the open thing — so it can be named, passed, sent to `Par`,
and folded twice.

```
FS.stream_lines /var/log/app.log
|> Stream.filter (fn l -> String.contains? "ERROR" l)
|> Stream.fold_left (fn n _ -> n + 1) 0
```

`take n` stops the source being read once n elements have passed — the
memory and the reading are both bounded. `to_list` reads everything, and
saying so is the point of its name.

**Each terminal operation reads the source afresh.** Folding a stream twice
opens and reads the file twice, seeing it as it is each time; `Par`
workers enumerate independently. Traversal is neither free nor
snapshotted — `List` intuition does not transfer. `IO.stdin_lines` is
the one source that cannot re-run: streaming the real stdin a second
time raises.

A source that can fail carries `Raise` in the stream's effect set, and the
failure surfaces at the terminal operation, where the open happens —
`try` around the terminal call is the one capture. There are no `!`
siblings here: no Stream function adds a raise of its own, so none earns
a bang.

Enumeration performs one effect per open — the same file-level
granularity as `FS.read_file` — so a fold traces as one line, and a test
mocks it wholesale: `Test.with_lines path lines thunk` answers every
`FS.stream_lines` for `path` with `lines`, and streams any other path as
empty.

### `Proc`

```
exit : Int -> 'a ! {Proc}
```

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

```
get   : String -> Option String ! {Env}
get!  : String -> String ! {Env, Raise}
set   : String -> String -> Unit ! {Env}
clear : String -> Unit ! {Env}
all   : Unit -> List (String, String) ! {Env}
args  : Unit -> List String ! {Env}
home  : Unit -> Path ! {Env}
user  : Unit -> String ! {Env}
read  : Path -> Result String (Map String) ! {Env, FS.Read}
read! : Path -> Map String ! {Env, FS.Read, Raise}
load  : Path -> Result String Unit ! {Env, FS.Read}
load! : Path -> Unit ! {Env, FS.Read, Raise}
```

`args` is the arguments the script was given, without the program name:
`wand deploy.wand --port 8080` gives `["--port", "8080"]`. See
[`Args`](#args) for reading them with a decoder.

### `CSV`

```
parse          : String -> List (List String)
parse_with     : String -> String -> List (List String)
stringify      : List (List String) -> String
stringify_with : String -> List (List String) -> String
read_file      : Path -> Result String (List (List String)) ! {FS.Read}
read_file!     : Path -> List (List String) ! {FS.Read, Raise}
rows           : Decoder 'a -> String -> Result String (List 'a)
```

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

```
parse            : String -> Result String JSON
parse!           : String -> JSON ! {Raise}
stringify        : JSON -> String
stringify_pretty : JSON -> String
read_file        : Path -> Result String JSON ! {FS.Read}
read_file!       : Path -> JSON ! {FS.Read, Raise}
null             : JSON
of_bool          : Bool -> JSON
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

```
parse      : String -> Result String TOML
parse!     : String -> TOML ! {Raise}
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

### `Float`

```
of_int : Int -> Float
round  : Float -> Int
floor  : Float -> Int
ceil   : Float -> Int
abs    : Float -> Float
```

Crossing between the two members of `Num`. Arithmetic never converts on
its own — `1.5 + 1` is a type error that names these functions — so the
crossing is always written out:

```
import Float

Float.of_int 3          -- 3 : Float
Float.round 2.5         -- 3, halves rounding away from zero
Float.round (- 2.5)     -- -3
Float.floor (- 2.1)     -- -3
Float.ceil 2.1          -- 3
Float.abs (- 2.5)       -- 2.5
```

`String.to_float` parses text; `JSON`/`TOML`/`Decode` read floats out of
documents.

### `Duration`

```
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

### `Par`

```
map  : Int -> ('a -> 'b ! 'e) -> List 'a -> List (Result String 'b) ! 'e
each : Int -> ('a -> 'b ! 'e) -> List 'a -> Unit ! 'e
```

Fork-join parallelism, and nothing else:

```
Par.map  : Int -> ('a -> 'b ! 'e) -> List 'a -> List (Result String 'b) ! 'e
Par.each : Int -> ('a -> 'b ! 'e) -> List 'a -> Unit ! 'e
```

`each` drops what its function returns, as `List.each` does. The first
argument is the most workers to run at once — stated, because how much a
script may do at the same time is a decision about the machine it runs on. Results come back in the list's order, not the order they finished, and
an element whose work raises comes back as an `Error` in its place rather
than failing the others.

```
Par.map 4 (fn x -> x * 2) [1, 2, 3]        -- [Ok 2, Ok 4, Ok 6]
Par.map 4 (fn m -> Map.get! "k" m) [{k = 1}, Map.empty]
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

```
decode : Decoder 'a -> String -> Result String 'a
lines  : Decoder 'a -> String -> Result String (List 'a)
```

Reading what a command wrote. See [Decoders](#decoders).

```
let ahead = Shell.decode Decode.int $(git rev-list --count HEAD)
```

### `Decode`

```
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
and_then : ('a -> Decoder 'b) -> Decoder 'a -> Decoder 'b
succeed  : 'a -> Decoder 'a
fail     : String -> Decoder 'a
one_of   : List Decoder 'a -> Decoder 'a
path     : Decoder Path
duration : Decoder Duration
url      : Decoder Url
size     : Decoder Size
version  : Decoder Version
date     : Decoder Date
time     : Decoder Time
datetime : Decoder DateTime
ipv4     : Decoder IPv4
cidr     : Decoder CIDR
port     : Decoder Port
```

`Decoder a` is an opaque type. Running a decoder is a backend's job:

```
JSON.decode : Decoder 'a -> JSON -> Result String 'a
TOML.decode : Decoder 'a -> TOML -> Result String 'a
Args.parse  : Decoder 'a -> List String -> Result String 'a
```

See [Decoders](#decoders).

### `Args`

```
parse      : Decoder 'a -> List String -> Result String 'a
parse_with : List String -> Decoder 'a -> List String -> Result String 'a
```

A command line is another untyped boundary, so it is read the same way as
any other: argv becomes a document and a decoder reads it. There are no
combinators here — every one of `Decode`'s already applies, including the
domain readers and the error that names the field.

```
type Opts (port : Port, timeout : Duration, config : Path)

Args.parse Opts.decoder (Env.args ())
-- Ok (Opts (port = :8080, timeout = 30s, config = ./app.toml))
-- Error .port: expected Port, got "http"
```

`--port 8080` and `--port=8080` are the same thing; with `=`, only the
first one splits, so a value may contain more. Every flag is assumed to
take a value, because that is the one fact a list of strings cannot reveal:
without it, `--message -5` and a flag followed by a positional argument are
the same shape. Name the flags that do not:

```
Args.parse_with ["verbose"] Opts.decoder (Env.args ())
```

Those become `true` when present and are absent otherwise, so a `Bool`
field wants `Decode.optional` or a default. A flag with nothing after it is
an error — `--config expects a value`.

Only `--name` is a flag. A single dash is not, which keeps `-5` an
argument; short flags do not exist. Positional arguments arrive under `_`:

```
Args.parse (Decode.field "_" (Decode.list Decode.string)) (Env.args ())
```

`Env.args ()` is already the arguments alone — there is no program name at
the front to skip, as there would be with bash's `$0` or C's `argv[0]`.

### `Test`

```
test           : String -> (Testing 'b 'a -> TestOutcome ! 'e) -> TestOutcome ! 'e
group          : String -> (Unit -> List TestOutcome ! 'e) -> TestOutcome ! 'e
with_shell     : List (String, String) -> (Unit -> 'a ! 'e) -> 'a ! 'e
shell_calls    : (Unit -> 'a ! 'e) -> List 'b ! 'e
without_writes : (Unit -> 'a ! 'e) -> 'a ! 'e
with_lines     : Path -> List String -> (Unit -> 'a ! 'e) -> 'a ! 'e
writes         : (Unit -> 'a ! 'e) -> List Path ! 'e
```

The handle a test block receives carries `ok`, `not_ok`, `eq`, `not_eq`,
`raises` and `fail`.

The module a test file imports. See [Testing](#testing).

### `Option`

```
some?     : Option 'a -> Bool
none?     : Option 'a -> Bool
map       : ('a -> 'b ! 'e) -> Option 'a -> Option 'b ! 'e
and_then  : ('a -> Option 'b ! 'e) -> Option 'a -> Option 'b ! 'e
or_else   : (Unit -> Option 'a ! 'e) -> Option 'a -> Option 'a ! 'e
default   : 'a -> Option 'a -> 'a
get!      : Option 'a -> 'a ! {Raise}
to_result : 'a -> Option 'b -> Result 'a 'b
```

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
let {test} = import Test

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
- `t.fail why` — fail, saying why. For the branch where the test itself has
  gone wrong rather than the value being different: an unexpected `Error`,
  a pattern that should not have matched, a setup step that did not hold.

  ```
  match Args.parse Opts.decoder args with
  | Ok o    -> t.eq :8080 o.port
  | Error e -> t.fail e
  ```

  A failure reads `label: why`, so the reason travels with the test name
  rather than being compared against something it was never meant to equal.
- `t.raises thunk` — pass if calling `thunk ()` raises. `thunk` must be a
  zero-argument function (`fn () -> ...`), not the expression directly —
  wand evaluates arguments eagerly, so `t.raises (List.get! 9 xs)` would
  raise while evaluating the argument itself, before `t.raises` ever runs.

`let {test} = import Test` binds the one name the file uses unqualified;
`import Test` alongside it gives the module's other helpers under `Test.`.
Like every import, it brings in what it names and nothing more.

Each `test` call needs explicit parens around its `fn` argument
(`test "x" (fn t -> ...)`) — wand doesn't currently allow a bare `fn` as
a trailing application argument.

### Child tests

`group` runs child tests that share a label and whatever its body binds:

```
let {test, group} = import Test

group "the report" (fn () ->
  let lines = String.lines (build_report ()) in [
    test "has a header" (fn t -> t.eq "# Report" (List.head! lines)),
    test "is short" (fn t -> t.ok (List.length lines < 40))
  ])
```

Each child is printed under the path of labels that led to it — `ok   the
report / has a header` — and groups nest to any depth: a `group` is one
more child in the list.

The body is ordinary code, which is why there is no `before`/`after`
machinery to learn:

- Setup is the code above the list: it runs once, and its bindings are
  shared by every child. Values are immutable, so sharing them cannot let
  one child contaminate another.
- Teardown is a bracket around the list — `with (FS.temp_dir ()) as dir ->
  [...]` — released however the body ends, exactly as in any other script.
- Mocks wrap the children like any other code:
  `group "pushes" (fn () -> Test.with_shell mocks (fn () -> [...]))`.
- Per-child setup, where each test wants fresh state, is a function:

  ```
  let with_scratch label f =
    test label (fn t -> with (FS.temp_dir ()) as dir -> f t dir)
  ```

A raise in the body itself — setup breaking, rather than a child failing —
is reported as the group's one failure under its label, and the children
it prevented are not invented. A raise inside a child is that child's own
failure; its siblings still run.

Run test files with `wand s`:

```
wand s                       # every test_*.wand at or below the current directory
wand s scripts/              # every test_*.wand under scripts/
wand s test_deploy.wand      # just this one
```

A test file is named `test_*.wand`, and a script's tests belong beside the
script — `deploy.wand` and `test_deploy.wand` in one directory, where the
prefix sorts every test together and away from the things being tested.
With no argument `wand s` searches from where you are standing, so
editing a script and running its tests takes no path. `_build`, `_opam`,
`.git` and `node_modules` are not searched. A file named on the command
line runs whatever it is called.

Each call to `test` is printed as `ok   <label>` or `FAIL <message>`; a
test whose body raises outside of `t.raises` is reported as that test's
failure — `label: raised: <why>` — without stopping the rest of the
file. `wand s` exits nonzero if any test failed or any file had a
lex/parse/type error.

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
  let () = FS.write_file! /etc/app/config.toml "version = \"%{version}\"\n" in
  let _ = $(rsync -a ./build/ web@host:/srv/app) in
  "deployed %{version}"
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

## Style for scripts

Everything in this manual parses anywhere, but `examples/` and `demos/` are
written in a deliberately small dialect, aimed at a reader coming from shell
rather than from ML. The standard library is written by and for the compiler
team and uses the full language; a script does not have to.

- **One statement per line at the top level.** A newline ends a statement,
  so top-level code needs no terminator, no `let () =`, and no ceremony —
  do the thing, then do the next thing. A line that starts with an operator
  is the exception: it continues the line above (see
  [Sequencing](#sequencing)).

- **Sequence with `;` in parentheses inside a body.** A function body is one
  expression, so several statements there go in parentheses, separated by
  `;` (see [Sequencing](#sequencing)):

  ```
  let backup_all! dest = (
    FS.mkdir! (Path.of_string dest);
    List.each (fn p -> backup_one! dest p) (FS.glob ./*.wand)
  )
  ```

- **Reach for `let ... in` to name something, not to sequence.** `let x = e
  in body` gives `e` a name that `body` uses; that is its job. Chaining
  statements as `let () = e1 in e2` still works and still typechecks, but
  the `;` form says the same thing without the puzzle of what `()` binds.

- **`match` over multi-equation definitions.** Defining a function twice
  with different patterns (`let failed? (Error _) = true` / `let failed?
  (Ok _) = false`) is legal, and the stdlib uses it. A script writes one
  definition and matches:

  ```
  let failed? r =
    match r with
    | Error _ -> true
    | Ok _ -> false
  ```

---

## REPL and CLI

### Running scripts

```
wand script.wand          # run a script
wand script.wand arg1     # pass arguments (available via Env.args)
wand script.wand -- arg1  # everything after -- is the script's, whatever it looks like
```

`--dry-run` and `--trace` are wand's own wherever they appear before a `--`,
so `wand deploy.wand --dry-run` rehearses. A script that takes an argument of
the same name needs the terminator: `wand deploy.wand -- --dry-run` runs for
real and hands the flag on.

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
5.7ms of 7.2ms — so what a module's types came out as is kept between runs.

An entry is keyed by the hash of the module's source *and* of everything it
imports, transitively, so an entry inferred against a file that has since
changed is unreachable rather than merely out of date. The key also covers
the binary itself — its version, size and mtime — because a module's types
come from the builtins as much as from its source, and a builtin whose
signature changed would otherwise leave every hash matching and every
cached type wrong. Nothing needs clearing, and there is no timestamp to be
wrong about. An unreadable entry is a miss, not an error.

```
WAND_CACHE=0 wand script.wand    # ignore it, and write nothing
```

`0`, `false`, `no` and `off` turn it off; unset, or any other value, leaves
it on. The switch is named for what it controls rather than against it, so
there is no value that reads one way and behaves the other.

Caching costs the first run of a script a little and saves every run after
it: a script importing six stdlib modules goes from 16.2ms to 12.1ms, and
one importing a 200-definition module from 16.5ms to 10.9ms.

#### Environment

| | |
|---|---|
| `WAND_CACHE` | `0`/`false`/`no`/`off` disables the compile cache |
| `WAND_CACHE_HOME` | the cache directory itself |
| `XDG_CACHE_HOME` | a parent for it; wand uses `$XDG_CACHE_HOME/wand` |
| `WAND_STDLIB` | a standard library to use instead of the built-in one |

The cache goes in the first of these that is set: `WAND_CACHE_HOME`, then
`$XDG_CACHE_HOME/wand`, then `~/.cache/wand` — or `%LOCALAPPDATA%\wand\cache`
on Windows, where `~/.cache` is not a place anything keeps.

The standard library is compiled into the binary, so wand runs the same from
any directory and a `stdlib/` folder is just a folder. `WAND_STDLIB` replaces
that library wholesale, so a `List.wand` in the directory it names *is*
`List`; it is meant for working on the standard library itself, where a built
binary has to run against sources on disk.

An empty value counts as unset everywhere here, since an empty value nearly
always comes from a shell interpolating something that held nothing.

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

| Command | Long form | Description |
|---|---|---|
| `:c` | `:clear` | Clear the screen |
| `:d <name>` | `:doc` | Show doc string |
| `:e [name]` | `:edit` | Open a definition in `$EDITOR` |
| `:h` | `:help` | List these commands |
| `:l <path>` | `:load` | Load a `.wand` file into the session |
| `:r` | `:reload` | Reload the last loaded file |
| `:s` | `:reset` | Clear the screen and all session bindings |
| `:t <expr>` | `:type` | Show type without evaluating |
| `:v [module]` | `:env` | List bindings and modules; `:v List` shows `List` members |
| `:x` | `:exit` | Exit interactive mode |

Multi-line input is detected automatically: unclosed brackets, a trailing
`->`, `=`, `|`, `,`, or dangling keyword (`then`, `else`, `in`, `with`,
`and`), and — within an entry already spanning lines — a `let` equation
still awaiting its `in` or body all keep the entry open. A blank
continuation line submits the accumulated input.

History is saved to `~/.wand_history` between sessions.

### One-shot commands

```
wand d "List.map"                     # show doc string
wand d --json "List.map"              # the same, as JSON for tools
wand e "1 + 2"                        # evaluate and print result
wand e --load config.wand "host"      # evaluate in context of a file
wand f script.wand                    # format a file in place
wand f stdlib/*.wand                  # format multiple files in place
wand h                                # show all commands
wand h e                              # help for a specific command
wand s                                # run every test_*.wand from here down
wand s test_deploy.wand               # run named test files
wand s --json                         # per-test results as JSON, for tools
wand t "List.map"                     # typecheck only
wand v                                # list all names and modules in scope
wand v List                           # list one module's members
wand v --json List                    # the same, as JSON for tools
wand V                                # print the version, as `wand 0.1.0`
```

Each subcommand has a full-word alias: `d`/`doc`, `e`/`eval`, `f`/`fmt`, `h`/`help`, `i`/`interactive`, `s`/`test`, `t`/`type`, `v`/`env`, `V`/`version`.

### Lints

`wand t` reports lint findings alongside the type. Each carries a rule ID
whose prefix says what it will do to your build: `V-` rules report a
violation, and `--strict` promotes them to errors; `A-` rules are advisory and stay
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
| `V-DROP1` | a statement's value is a `Result` nothing reads, so a failure is lost |
| `V-DROP2` | a statement's value is a `TestOutcome` nothing reads, so the test cannot fail |
| `V-IMP1` | two imports in the leading import block bind the same name, so the first binding is dead — rename one (`let {parse = csv_parse} = import CSV`) or drop it |
| `A-SHELL1` | a `$()` holds a shell pipeline of three or more operators |
| `V-SHELL1` | the manifest narrows `Shell` to named binaries, but a command word is decided at run time |
| `A-USES1` | a manifest permits an effect the file does not use, or a binary no command runs |
| `A-USES2` | a file performs effects and declares no manifest |

`V-DROP1` is the one that catches a bug rather than a habit:

```
FS.write_file /etc/app.toml config      -- the Result goes nowhere
IO.println "deployed"                   -- and this prints either way
```

The write may have failed; the script says it deployed and exits 0. Match
the `Result`, call `write_file!` and let it raise, or bind it to `_` if the
failure genuinely does not matter. Writing the statement as
`let () = FS.write_file ...` is a type error for the same reason — this rule
is what catches the shape that says nothing either way. Values that are not
`Result` are left alone: discarding a `String` is what running a command for
its effect looks like.

`V-DROP2` is the same mistake with a worse ending. A test block answers with
one outcome, so sequencing assertions discards all but the last:

```
test "parses" (fn t -> (t.eq 1 got_a; t.eq 2 got_b))
```

`t.eq 1 got_a` is thrown away, and the test reports a pass however that
first assertion went. Return the one outcome the block is answering with, or
give each assertion its own `test` and share the setup with `group`:

```
group "parses" (fn () -> let doc = parse! source in [
  test "a" (fn t -> t.eq 1 (field_a doc)),
  test "b" (fn t -> t.eq 2 (field_b doc))
])
```

`wand s` refuses a file this rule fires on rather than printing a verdict it
does not have — a run whose assertions are discarded cannot answer the
question it was asked.

```
wand t --strict "..."             # violations become errors (exit 1)
wand t --json "..."               # diagnostics as JSON, for tools
wand t --fix --file script.wand   # apply the fixes the findings carry
```

### `--fix`

`wand t --fix --file script.wand` applies every machine-applicable
correction to the file in place, re-checks, and repeats until nothing
more applies — a fix can unlock a further finding, as when admitting a
new binary into `Shell(...)` reveals another that no command runs. What
it applies is exactly the `fix` payloads `--json` reports: manifest
creation, replacement (including the manifest type error's suggested
line), and the dead-import deletion. One line is printed per applied
fix (`rule: line — what changed`); with `--json`, the applied set in
the diagnostics shape. A parse error, or a type error carrying no fix,
refuses the whole run — nothing is written, because fixing around a
broken file is guesswork. Findings without a fix payload are reported
by a plain `wand t` and left alone here.

### `--json`

With `--json`, `wand t` prints a single JSON array on stdout — one object
per diagnostic — and nothing else. Exit codes are unchanged, and the
human output is unchanged when the flag is absent.

Every finding and error carries `severity` (`"error"`/`"warning"`),
`code` (`A-USES2`, `V-DROP1`, ...; errors get `E-TYPE`, `E-PARSE`,
`E-LEX`), `line`, `col`, and `message`; `file` appears when a file was
named with `--file`. A diagnostic that covers an extent rather than a
point also carries `end_line` and `end_col` (exclusive): findings span
the whole item they are about, type errors the whole expression at
fault, lex errors the failing token. Under `--strict`, must-fix
findings report as `"error"`. When a machine-applicable correction
exists it rides along as a `fix` object: the manifest suggestions carry
the exact line —

```json
{"severity":"warning","code":"A-USES2","line":1,"col":1,
 "message":"this file performs FS.Write and does not say so; it could declare \"uses {FS.Write}\"",
 "fix":{"insert_line":"uses {FS.Write}"}}
```

(`A-USES1` and the manifest type error carry `fix.replace_line`
instead, `V-IMP1` carries `"fix":{"delete_line":true}`), and the drift
errors whose correction is a plain substitution carry
`"fix":{"replace":{"from":"and","to":"&&"}}`. Typed holes come as their
own shape:

```json
{"kind":"hole","type":"Int -> Int -> Int ! 'e"}
```

The query commands take `--json` too, printing one JSON value on stdout
in place of their text. `wand d --json <name>` prints one object —
`name`, `type`, `doc`, where a fact the session lacks is `null` rather
than omitted:

```json
{"name":"List.map",
 "type":"('a -> 'b ! 'e) -> List 'a -> List 'b ! 'e",
 "doc":"Apply a function to every element of a list, returning a new list."}
```

`wand v --json` prints an array over the scope — a binding as
`{"name":...,"type":...}`, a module as `{"name":...,"module":true}` —
and `wand v --json <module>` the module's members, names qualified:

```json
[{"name":"List.all","type":"('a -> Bool ! 'e) -> List 'a -> Bool ! 'e"},
 {"name":"List.any","type":"('a -> Bool ! 'e) -> List 'a -> Bool ! 'e"}]
```

`wand s --json` prints one object for the whole run, when the run
completes (a well-formed JSON value cannot stream test by test). While
the tests run, anything they themselves print goes to stderr, so stdout
holds nothing but the JSON. A pass
carries its `label`; a fail carries `message`, which already begins with
the label — that is how the Test module writes it. A test that raised
rather than failed an assertion has status `"error"`; both count in
`failed`, and the exit code is unchanged. A file that would not load
(parse error, missing import) appears under `errors` instead of `tests`:

```json
{"tests":[{"file":"test_deploy.wand","status":"pass","label":"it adds"},
          {"file":"test_deploy.wand","status":"fail",
           "message":"it rounds: expected 4, got 3"}],
 "errors":[{"file":"test_broken.wand",
            "message":"parse error: 2:1: unexpected token: EOF"}],
 "passed":1,"failed":1}
```

### Formatter

`wand f <file>...` formats one or more `.wand` files in place (each
file is overwritten with its formatted contents; a confirmation line is
printed per file). Shell globs work as expected: `wand f stdlib/*.wand`
reformats every file in `stdlib/`.

Comments (`-- ...`, `(* ... *)`, and doc `(** ... *)`) are always preserved —
never silently dropped, and never rewritten from one style into the other. Multi-equation function definitions
(`let f 0 = ... / let f n = ...`) are reconstructed as separate clauses
rather than left as the desugared `match`.

The manifest is emitted canonically: labels in display order (alphabetical
— `Env, FS.Read, FS.Write, IO, Proc, Raise, Shell`, the same order every
rendered effect set and suggested manifest uses), the binaries inside
`Shell(...)` sorted, and the whole form wrapping one label per line when
it passes the column budget (an over-long `Shell(...)` list wraps one
binary per line the same way). In the leading run of imports at the top
of a file, plain `import M` statements come first, alphabetized, then
let-imports (`let {test} = import Test`) in source order — let-imports
are ordinary bindings, so their relative order is never changed, and a
region with a comment inside it is left exactly as written. Imports past
the leading region stay where they are.

Lines are wrapped to fit 92 columns — chosen for the pane code is *read* in
rather than the one it is written in. A split diff gives each side around
ninety columns, and a line past that scrolls sideways exactly where code is
looked at hardest; the same width holds for wand shown next to bash in a
README or a terminal recording.

An item with a comment inside it is re-emitted exactly as written.
Formatting it would mean deciding which expression the comment now belongs
to, and a comment moved to the wrong one is worse than a comment left where
its author put it. Everything else has a formatting rule.

### Language server

`wand lsp` starts the language server, speaking LSP over stdio. It is a
subcommand on the compiler binary — the same inference, lint rules, and
formatter answer in the editor, so the two cannot disagree. An editor
connected to it gets diagnostics on every change, hover (the signature
with its effect set, and the doc string), completion, quick fixes
carrying the same corrections `wand t --fix` applies, whole-document
formatting, and go to definition — a jump into the standard library
opens the module's source from the binary as a read-only document.

Typing a qualified name resolves it as you type: `FS.write_file!` in a
buffer that has not imported `FS` inserts `import FS` into the sorted
import block and adds `FS.Write` to the manifest. The edit fires only
when the member resolves — a miss gets a diagnostic, never a guess — and
it never touches `Shell`: adding a binary, widening, or narrowing that
label is always a visible quick fix instead. A manifest is extended,
never created uninvited.

The VS Code extension lives at `editors/vscode/` in the wand repository:
syntax highlighting (domain literals as constants, embedded shell inside
`$()`), the client for `wand lsp`, and a "Rehearse (dry run)" code lens
on the manifest line that runs `wand --dry-run` on the file. It is not
on the Marketplace yet; its README shows how to build and sideload it.

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

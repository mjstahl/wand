## 0.79.0 - 2026-09-18

Checking a tree in one command, asking what a file reaches, and every
unknown name in one pass. Plus a signature that says which of its types are
the same one, and the comparisons moving onto the types they order.

### `wand t` takes a directory

Checking a tree was a shell loop, because a second path was "too many
arguments".

```
$ wand t .
scripts/deploy.wand: type error: 3:11: unbound variable 'targt'
scripts/report.wand: warning: 5:1: V-BANG2: 'safe!' cannot raise, so the
  `!` promises a risk that is not there; it is 'safe'
12 files, 1 error, 1 warning
```

Every finding carries its path, and one file's error does not stop the rest:
a gate wants the whole list, not the first line of it. The exit code is 1 if
any file has an error. A directory is searched all the way down, past
`_build`, `_opam`, `.git` and `node_modules`, without following a link to a
directory.

One file named on its own is unchanged.

### `wand t --effects` says what a file reaches

`--json` reported lint findings, and a clean file reported `[]`, so there was
no way to ask what a file reaches outside itself. Now there is, and a check
can compare it with a policy by exit code.

```
$ wand t --effects examples
examples/hello.wand                 ! {}
examples/log-summary.wand           ! {IO}
examples/party.wand                 ! {Shell(whoami)}
examples/ports/disk-threshold.wand  ! {IO, Shell(df)}
examples/ports/http-retry.wand      ! {Clock, Env, IO, Net, Proc}
examples/sysinfo.wand               ! {Env, Shell(hostname, uname)}
32 files
```

The set is the one wand inferred, never the `uses` line — a file with no
manifest is unbounded rather than sealed, so reading the manifest would
report the emptiest set for the least bounded file in a tree. A file that
reaches nothing reports `! {}` rather than a blank, so a check can match it.

### Every unknown name in one run

A failing typecheck answered with one error, so a file with six unknown names
took six runs to clear. A person reread it between each, and a tool driving
`wand t` in a loop paid a round trip per name.

```
$ wand t report.wand
Error: type error: 1:11: unbound variable 'alpha' -- 'wand d' lists the modules...
Error: type error: 3:11: unbound variable 'beta' -- 'wand d' lists the modules...
Error: type error: 5:11: unbound variable 'gamma' -- 'wand d' lists the modules...
```

An unbound name is the one error a check can carry on past: the name gets a
fresh type variable, which unifies with anything, so nothing below the miss
reports a consequence of it as a mistake of its own. Every other error still
stops where it stood.

### A signature says which of its types are the same one

`Ord`, `Add` and `Num` printed as though they were types, so a signature
could not say which of its uses were the same type — and where there were
two, it said nothing at all:

```
before:  pair_of_maxes : Ord -> Ord -> Ord -> Ord -> (Ord, Ord)
after:   pair_of_maxes : 'a: Ord -> 'a -> 'b: Ord -> 'b -> ('a, 'b)
```

Six `Ord`s there, and two types: `pair_of_maxes 1 2 "a" "b"` is legal. What
`wand d` prints still pastes back as an annotation.

### The comparisons moved onto the ordered types

The `Ord` module is gone. Each of the eleven types wand orders carries `max`,
`min`, `clamp` and `between?` itself, so the place to look for one is the
type in your hand.

```
Ord.max 3 7            ->  Int.max 3 7
Ord.min 4KB 100MB      ->  Size.min 4KB 100MB
Ord.clamp 1s 30s 5min  ->  Duration.clamp 1s 30s 5min
```

The old spelling says where its function went. `List.max`, `List.min`,
`List.sum` and the three on `Stream` are unchanged — a list is where you
already look for those.

### `wand d --index`

Every module's members with their signatures in one listing, 547 lines: the
whole standard library surface as a command that stays in step with what is
on disk. `--json` gives the same as an array of `{name, type}`.

### `String.lines` drops the piece a trailing newline left

A newline ends a line rather than separating two, so nearly every file gave
back one element more than it had lines, with `""` at the end, and every
caller had to filter it.

```
                        -- before            -- now
String.lines "a\nb\n"    ["a", "b", ""]      ["a", "b"]
String.lines ""          [""]                []
```

An empty line written on purpose is still a line: only the piece after the
last newline goes, and only when it is empty.

### The `String.to_*` family has its raising siblings

The naming rule is that a fallible function comes as a pair, and this family
was twelve exceptions to it in one module. `to_int!`, `to_float!`, `to_bool!`,
`to_glob!`, `to_url!`, `to_ipv4!`, `to_cidr!`, `to_port!`, `to_version!`,
`to_size!`, `to_datetime!` and `to_duration!`. `to_path` has none, because it
cannot fail: any text is a path.

### A named field's type can be a function

The comma or the closing parenthesis ends a named field, so a pair of
parentheses around the whole type said nothing.

```
-- before                          -- now
type Handler(                      type Handler(
  ok: (Bool -> Int),                 ok: Bool -> Int,
  eq: ('a -> 'a -> Int)              eq: 'a -> 'a -> Int
)                                  )
```

A function type written as a parameter keeps its parentheses, because there
they say which type it is.

### `wand f` no longer crawls on deeply nested code

It built each level's text by copying what the level below it had built, and
it wrote a value out to find whether the value fits. It joins the pieces once
now, and measures before writing.

```
                        before    after
400 nested if/else      189.1s    0.04s
2000 nested lists        50.5s    0.09s
400 nested calls          5.9s    0.17s
400 nested matches        1.1s    0.03s
```

Formatting is unchanged: the corpus, the tools, the demos and every
regression input come back byte for byte as before.

## 0.57.0 - 2026-09-03

wand can draw a random number. `Random` is the module, and `Random` is also a
new effect label -- the ninth, and the first added since the set was fixed.

A handler also discharges what it answers across a function boundary now.
That was the change the module needed, and it applies to every effect.

### Drawing

The module is seven names:

```
$ wand d Random
Random.chance? : Float -> Bool ! {Random}
Random.choose : List 'a -> Option 'a ! {Random}
Random.float : Unit -> Float ! {Random}
Random.hex : Int -> String ! {Random}
Random.int : Int -> Int -> Int ! {Random}
Random.seed : Int -> Unit ! {Random}
Random.shuffle : List 'a -> List 'a ! {Random}
```

`int` includes both ends. A die has six faces, and `Random.int 1 6` rolls
one. A range given backwards is read forwards, so `Random.int 6 1` is the
same six faces. A backwards pair is a slip, not an empty range that answers
the same number every time.

```ocaml
let roll = Random.int 1 6                  -- both ends included
let host = Random.choose pool              -- Option, because a list can be empty
let order = Random.shuffle tests
let wait = Duration.add 1s (Duration.seconds (Random.int 0 30))
```

What holds for every draw holds here too:

```
$ wand -e 'Random.int 3 3'
3 : Int

$ wand -e 'let r = Random.int 1 6 in r >= 1 && r <= 6'
true : Bool

$ wand -e 'List.sort (Random.shuffle ["alpha", "beta", "gamma"])'
["alpha", "beta", "gamma"] : List String

$ wand -e 'String.length (Random.hex 8)'
8 : Int
```

`Random.seed` pins a run, and a run that pins nothing starts from the
environment. A seed repeats within a build, which is what a test needs. It
is not a format: do not store a seed and expect the same draws from a later
binary.

`chance?` takes the odds instead of fixing them at a half. A fair coin is
`Random.chance? 0.5`. The call sites want the other values: a retry that
jitters, a sample that keeps one row in a hundred, a fault injected rarely.
`0.0` is never and `1.0` is always, and both are exact.

Nothing in the module raises. `choose` on an empty list is `None`, `shuffle
[]` is `[]`, and `hex 0` is `""`. An empty range is a question about the
argument, and the caller already holds the argument.

`hex` is for temporary paths, run identifiers and cache keys, where a
collision is an inconvenience. Do not rest a secret on it. The generator is
fast and predictable from its own output, which is the opposite of what a
token needs.

### Why it needed a label

The effect vocabulary was eight labels, and the reference promises you can
hold all of them in your head. A ninth had to earn the room.

A draw earns it. Nothing in `Unit -> Int` says that two identical calls give
two different answers, so a caller has to be told, and the manifest is where
wand tells them. The alternative was to fold drawing under `Clock`. `Clock`
reads as "waits" wherever a manifest is hovered, and that is wrong for every
name in the module.

`Random` is the fourth label that leaves the world alone and still has to be
declared, beside `Raise`, `Proc` and `Clock`.

Three operations sit under it, and a handler can answer them:

```ocaml
handle thunk () with
| Random!below _ k -> k 0        -- every draw takes the first thing offered
| Random!float _ k -> k 0.5
| Random!seed  _ k -> k ()
```

### A handler discharges across a function

A handler worth reusing takes the body as a parameter. That did not work. A
parameter's effects are an open set with nothing known in it, so removing a
label removed nothing, and the wrapper came out with one effect variable for
what went in and what came out:

```ocaml
-- before
pinned : (Unit -> 'a ! 'e) -> 'a ! 'e

-- after
pinned : (Unit -> 'a ! {Clock | 'e}) -> 'a ! 'e
```

The caller's effect passed straight through the handler that existed to stop
it. wand now splits the tail rather than searching it: what the body
performs is the handled set and a rest, and the rest is what escapes. This
is the shape `Par.timeout` has been written by hand with all along.

Asking for the effect does not turn a thunk away that never performs it.
`pinned (fn () -> 42)` still typechecks.

A manifest also stopped counting demands as deeds. An effect on an
argument's arrow is something the caller may bring, not something the file
does, so it no longer reaches the manifest. A file can now say it has mocked
an effect away without declaring the effect it mocked:

```ocaml
uses {}                          -- and it typechecks

let safely thunk =
  handle thunk () with
  | Proc!exit _ k -> k 0
```

Positions flip through arrows, so nothing is lost. A thunk the file *builds*
and hands to someone else still counts, because the file is what reads the
clock.

Two rules are unchanged, and both are in the reference now. An effect is
discharged only when every operation carrying it is handled: answering
`Shell!run` alone leaves `capture` and `exit_code` running for real.
Answering an operation still fixes what that operation returns, whether or
not the label goes away.

### What this breaks

Two things, and neither reaches a script that runs today.

**A manifest can now be too wide.** A file that fully handles an effect no
longer performs it, so a `uses` that names the effect is a `A-USES1`
warning: "the manifest permits Clock, and this file reaches outside itself
for nothing". Delete the label. Under `--strict` it fails. This can only
reach a file that wraps a handler and declares what it handles.

**`Random` is an effect name.** A manifest cannot use it for anything else,
and neither can a handler case. Nothing could before, since a script cannot
define an effect.

### Also

`Test.at` and `Test.with_clock` still carry the effect they mock. Each
answers one Clock operation on purpose, so neither discharges Clock. Their
signatures are unchanged.

`try` has the same open-set limit that handlers had. `Raise` never reaches a
manifest, so nothing about it is visible in a `uses` line.

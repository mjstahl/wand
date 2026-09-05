## 0.60.0 - 2026-09-05

`Env.args` moves to `Proc.args` and stops carrying an effect. `Proc.pid` is
new. The reference now states which of three things earns an effect label.

### `Proc.args`, with no effect

```
Env.args : Unit -> List String ! {Env}     -- 0.59.4
Proc.args : Unit -> List String            -- 0.60.0
```

Two things were wrong. `Env` means "reads or changes environment
variables". Argv is not one: the process is handed it at launch, from a
different place.

And the effect. `Env.get` needs one because `Env.set` exists, so two reads
in one run can disagree. Argv has no such pair. It is fixed before the
script starts and nothing in the language writes it. Reading it touches
nothing and answers the same twice.

So a script that only reads arguments now declares nothing for them:

```
$ wand t script.wand
V-USES2: this file performs Env, IO ... "uses {Env, IO}"    -- 0.59.4
V-USES2: this file performs IO ... "uses {IO}"              -- 0.60.0
```

There is no `Proc!args` operation. A handler cannot intercept argv, and
nothing needed to: `Args.parse` takes the list, so a test passes
`["--port", "9000"]` directly.

### `Proc.pid`

```ocaml
Proc.pid : Unit -> Int
```

The process id the operating system assigned. No effect, for the same
reason as `args`. A `Par` worker is a domain and not a second process, so
every branch reads one pid.

### What earns a label

A new section of the reference. Three things justify an effect, and the
nine labels divide between them:

| Justification | Labels |
|---|---|
| Reach — the call touches something outside the program | `Shell`, `FS.Read`, `FS.Write`, `Env`, `IO`, `Proc` |
| Non-determinism inside one run — two calls can disagree | `Clock`, `Random` |
| Control flow | `Raise` |

A call in none of the three carries no effect. `Proc.args` and `Proc.pid`
are the two. The section also states the rule that `Raise` follows, which
was written as a special case before.

### Also

- A `match` or `handle` arm whose body ends in a nested match keeps its
  bracket. `wand f` used to give the arms below it to the inner match
  through a `with`, `fn` or `if` tail. Read the diff if `wand f` has run
  over a file with a nested `match`
- A multi-line backtick string starts on the line of its `=`
- The stdlib doc examples write JSON and TOML between backticks

### Renamed

`Env.args` is now `Proc.args`. Update the call and drop `Env` from the
manifest if nothing else in the file needs it. `wand t --fix` writes the
manifest for you.

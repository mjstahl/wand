## 0.78.0 - 2026-09-17

A pre-release audit. Two ways past a manifest, five crashes `try` could not
catch, and a set of fixes to the command line, the REPL, the VS Code
extension and the ported examples.

### `Shell(echo)` let a script run `whoami`

wand read every `$((` as arithmetic and stopped looking. Where the brackets
close before the `))`, `sh` reads it as a command and runs what is inside:

```ocaml
uses {Shell(echo), IO}
IO.println $(echo $((whoami) ))
```

That typechecked, and printed the user name. It is refused now, when you
typecheck it and again when the command is about to run:

```
this command runs 'whoami', which Shell(echo) does not allow
```

### `Net(api.github.com)` let a script reach any other host

A URL you write out is checked against the manifest of the file you wrote it
in. A URL the script works out while it runs — from `String.to_url`, from
`URL.join`, from any `URL.with_*` setter — was checked against nothing:

```ocaml
uses {Net(api.github.com), IO}
match String.to_url "https://anywhere.test/x" with
| Ok u -> IO.println "%{HTTP.get u}"
| Error e -> IO.println e
```

That sent the request and said nothing. Nor was any redirect it followed
checked. The manifest of the file that is running answers for both now:

```
this request reaches 'anywhere.test', which Net(api.github.com) does not allow
```

### Five crashes `try` could not catch

An instant is written with four digits for the year, so `DateTime.on 10000 1
1` had no way to be written down — and it killed the run instead of saying
so. A `Duration` that moved an instant past that range did the same. A
directory it could not read killed a `FS.glob_in`. `Proc.exit` under `wand
-e`, `wand s` or `wand d -t` reported a crash and the code 2 rather than the
code it was given. And one position outside the file ended the language
server, so the editor stopped reporting anything for the rest of the
session.

Each answers now, `try` catches each, and the exit codes are the ones the
caller expects.

### A `with` could not be a binding's body after a `;`

Every other block form could be. The `;` ended the definition instead, and
the line below it fell through to the top of the file:

```ocaml
let f! () =
  let n = 1;
  with FS.temp_dir "t_" as d -> n
```

That is the shape `wand f` writes for such a chain, and it did not parse.
Found by the daily fuzzer.

### `--strict` was a gate on one side of the path and an argument on the other

`wand deploy.wand --strict` refused a violation. `wand --dry-run
deploy.wand --strict` ran the script and passed `--strict` on to it as an
argument. Both spellings are a gate now, wherever the flag is written.

### `Env.set` corrupted the environment

A name is what stands left of the `=`. `Env.set "A=B" "x"` set `A` to
`B=x`, and an empty name added an entry nothing could read. Both are
refused.

### The YAML reader had no bound on nesting

There was already a limit on how far an anchor may be expanded, which is the
well-known way to make a small file cost a lot. A file that simply nests
fifty thousand deep needs no anchors and cost just as much: seconds to read,
and it could end the run. Nesting stops at 200.

### `:reload` served a stale dependency

Editing a file the script imports and reloading said it had reloaded, and
then ran the version from before the edit.

### The VS Code extension coloured code wand rejects

`(* ... *)` looked like a comment, `14:30:00` like a value, `and` and `or`
like operators, and `for`, `do`, `end`, `class`, `instance`, `orphan` and
`of` like keywords. Every one of those is an error when you run it, each
with a message naming the wand spelling — so the editor said one thing and
the run said another. Three of the ten effect names, `Net`, `Clock` and
`Random`, were left uncoloured inside the `uses` line that declares them.

The extension also said nothing useful when it could not start: a missing
`wand` showed up as "extension failed to activate". It names the path it
tried now, and offers to open the setting that fixes it. Changing
`wand.path` takes effect at once rather than after a window reload.

`class`, `instance`, `orphan` and `let*` are names you can use again. They
were reserved for nothing — no part of wand read them — and that list is
where the colouring had taken its keywords from.

### Three names that ran a command without checking the manifest

`process_run`, `process_run_quiet` and `process_exit_code` took a command as
text and ran it with no manifest consulted. No wand program could reach
them. They are gone, so none can.

### The ported examples

`stage-release.wand` exited 1 on every run — it listed a file it never
staged — and its "lock" was a file two runs would both write. It takes a
real one with `FS.lock` now. `dir-budget.wand` skipped every file with no
dot in its name, so it answered under what `du` says. `rotate-backups.wand`
deleted every `.tgz` in the directory where its comment promised only the
`backup-*.tgz` it writes. `normalize-names.wand` renamed one file onto
another when two names tidied to one.

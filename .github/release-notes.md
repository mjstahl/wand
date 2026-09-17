## 0.78.0 - 2026-09-17

A pre-release audit. Two manifest bypasses, five crashes that no `try` could
hold, and a set of fixes to the CLI, the REPL and the ported examples.

### A narrowed `Shell` did not bound a word inside `$((`

The scanner read every `$((` as arithmetic and looked no further. `sh` reads
the same text as a command substitution around a subshell when the
parentheses balance before the `))`:

```ocaml
uses {Shell(echo), IO}
IO.println $(echo $((whoami) ))
```

That typechecked, and it ran `whoami`. The scan now decides by how the form
closes, so a word in that position is checked like any other — against the
manifest, and again at the spawn.

### A narrowed `Net` did not bound a URL the run computed

The bound rode on the URL literal, because that is the part the calling file
wrote. A URL from `String.to_url`, from `URL.join` or from any `URL.with_*`
setter has no literal to take one from, and `HTTP.get` builds its request
inside the standard library, where the manifest is the standard library's.
So a file declaring `uses {Net(api.github.com)}` reached any host it
computed a URL for, and no redirect of such a request was checked either.

The running file's bound now answers where no literal can. A `Par` worker
carries it across the domain, and a URL built from another URL keeps that
URL's bound rather than losing it in the rebuild.

### Five crashes an effect handler could not catch

`DateTime.on 10000 1 1` ended the program with `int_of_string` — an instant
is written with a four-digit year, and nothing refused one that had no
spelling. A `Duration` that moved an instant past the range did the same.
An unreadable directory ended a `FS.glob_in` with the filesystem's own
`Sys_error`. `Proc.exit` under `wand -e`, `wand s` or `wand d -t` printed an
OCaml backtrace and left with 2. And a position outside the document ended
the language server, taking the session's diagnostics with it.

Each is a wand error now, which is to say each can be caught, and the exit
codes are the ones the caller expects.

### A `with` could not be a binding's body after a `;`

The forms that open an expression where a statement may stand carried `let`,
`if`, `match`, `fn`, `handle` and `try`. `with` was in neither list, so the
`;` ended the definition rather than handing the rest to the body, and the
line below fell through to the file:

```ocaml
let f! () =
  let n = 1;
  with FS.temp_dir "t_" as d -> n
```

That is the shape `wand f` writes for such a chain, and it did not parse.
Found by the daily fuzzer.

### `--strict` was a gate on one side of the path and an argument on the other

`wand deploy.wand --strict` refused a violation. `wand --dry-run
deploy.wand --strict` ran the script and handed it `--strict`. Two parsers
read the same four flags; there is one now.

### `Env.set` corrupted the environment

A name is what stands left of the `=`. `Env.set "A=B" "x"` set `A` to
`B=x`, and an empty name added an entry nothing could read. Both are
refused.

### The YAML reader had no bound on nesting

The alias limit covers the billion-laughs shape. A document that simply
nests fifty thousand deep took seconds and put the stack at risk, which is
the same attack by a plainer route. Nesting stops at 200.

### `:reload` served a stale dependency

A module was kept under the path it was loaded from and never dropped, so
editing an imported file and reloading reported success and ran the old
code.

### Three builtins that spawned a command from a `String`

`process_run`, `process_run_quiet` and `process_exit_code` took a command as
text and spawned it without consulting any manifest. No wand program could
reach them. They are gone, so none can.

### The ported examples

`stage-release.wand` exited 1 on every run — it listed a file it never
staged — and its "lock" was a file two runs would both write. It takes a
real one with `FS.lock` now. `dir-budget.wand` skipped every file with no
dot in its name, so it answered under what `du` says. `rotate-backups.wand`
deleted every `.tgz` in the directory where its comment promised only the
`backup-*.tgz` it writes. `normalize-names.wand` renamed one file onto
another when two names tidied to one.

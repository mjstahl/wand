## 0.62.0 - 2026-09-06

A command is a value now. `$*(cmd)` makes one and runs nothing. `Shell.run!`,
`Shell.run` and `Shell.query` run it. `Shell.stream` reads its output one
line at a time, which `$()` cannot do. `$()` and `$?()` are short forms for
the functions above.

### A command is a value

```ocaml
uses {Shell(pg_dump, git)}
import Shell

let backup = $*(pg_dump -Fc %{db})     -- nothing has run

let out = Shell.run!  backup
let r   = Shell.query backup

List.map Shell.query [$*(git fsck), $*(git gc --dry-run)]
```

```ocaml
Shell.run!  : Command -> String               ! {Raise, Shell}
Shell.run   : Command -> Result String String ! {Shell}
Shell.query : Command -> ShellResult          ! {Shell}
```

You can name a command, pass it to a function, and put it in a list. `$()`
cannot do any of that. It runs the command and reads all of the output before
a function sees a value.

**No `String` becomes a `Command`.** `Shell.run! "echo %{name}"` is a type
error. Inside a command, `%{...}` quotes the value as one argument. Inside a
string, `%{...}` puts the text in. The two forms look almost the same on the
page, and only the command form is safe. The quoting belongs to the syntax.
So a command can only be built where its words are written.

**A command performs `Shell` when it is made.** A function that only builds
commands carries the label. This keeps two checks on one site. `wand t` reads
the command words where they are written, so a file that names `git` and
never runs it still declares `Shell(git)`. The bound travels with the value:
a command built in a `Shell(echo)` file is checked against that list wherever
it is run.

### Reading a command as it runs

```ocaml
Shell.stream $*(tail -f /var/log/app.log)
|> Stream.filter (fn l -> String.contains? "ERROR" l)
|> Stream.take 10
|> Stream.to_list
```

`$()` reads to the end of the output before it answers. So
`$(tail -f app.log)` never returns. `kubectl logs -f` and `journalctl -f`
behave the same way. `Shell.timeout` was the only bound on this. It kills the
command and gives back an `Error`, and you get none of the lines.

A stream pulls one line at a time. It holds one line in memory. `Stream.take`
stops the read. `Shell.stream` is the third stream source, beside
`FS.stream_lines` and `IO.stdin_lines`, and it follows the same rules: it
runs nothing until a terminal operation, and folding it twice runs the
command twice.

**A stopped read stops the command.** wand sends SIGTERM. It sends SIGKILL
five seconds later. wand signals the command it started. It does not signal
that command's own children, so `sh -c "tail -f x"` leaves the `tail`
running.

**An early stop is not a failure.** A stream that reads to the end raises on
a non-zero exit, as `$()` does. A stream that stops early ignores the exit
code, because wand ended the command.

**Lines can arrive in gulps.** Many commands write in 4KB blocks when the
output is a pipe rather than a terminal, and `grep` is the common one. Ask
the command for line buffering (`grep --line-buffered`), or wrap it:
`$*(stdbuf -oL some-command)`.

`Shell.timeout` does not bound a stream. Its deadline is for a command that
runs to the end and hands back its output. `Stream.take` is the bound that
fits a stream.

### Handlers

`Shell` carries two new operations.

```ocaml
| Shell!command c k -> k c              -- a command is made
| Shell!stream  _ k -> k ["a", "b"]     -- a command is read as it runs
```

`Shell!command` carries the command line and resumes with the command line to
use. A test can read every command a body names, including one the body never
runs. A test can also put a different command in its place.

A handler takes `Shell` out of a signature only when it answers every
operation. That is six now: `command`, `run`, `stream`, `run_quiet`,
`capture` and `exit_code`. A handler that answered the old four still works;
it no longer removes the label.

### Also

- `$(cmd)` is `Shell.run! $*(cmd)` and `$?(cmd)` is `Shell.query $*(cmd)`.
  No script's text changes. Each form performs two operations now, where it
  performed one
- A `Command` shows as it would run, with its values quoted:
  `$*(echo 'two words')`
- `--dry-run` reports a streamed command and gives back no lines. Making a
  command is never held back, because the plan is printed from the value

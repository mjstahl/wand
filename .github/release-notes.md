## 0.55.0 - 2026-08-28

One bug that corrupts a file, and one rule that catches a mistake the
compiler cannot see. The command line is exactly 0.54.0's.

### `wand f` keeps a shebang

**Take this release if you write scripts that run themselves.** The formatter
deleted the `#!` line:

```
$ cat script.wand
#!/usr/bin/env wand
uses {IO}
...

$ wand f script.wand
$ ./script.wand
script.wand: line 1: uses: command not found
```

The lexer steps over `#!` on line one and emits no token for it, so it
reached neither the parser nor the pieces the output is assembled from. The
formatter wrote every other line back and not that one. `wand f` writes in
place, so formatting a self-running script stopped it running.

Present in every 0.53.x and in 0.54.0. The reference documents the form, and
nothing was holding it.

### `V-SHELL2`: a command that runs on to a second line

A newline inside `$()` starts a second command, exactly as it does in a shell
script. So a command broken over two lines for width runs as two:

```
let out = $(echo one
  two)
```

That runs `echo one`, then runs `two` as a command of its own. The half above
the break can do its work before the half below fails. Under `$()` the failure
raises; under `$?()` it is an exit code nobody reads.

`\` is the shell's continuation and wand passes it through, so the correction
is one character:

```
$ wand t --fix script.wand
V-SHELL2: 3 — appended "\"
```

The rule fires on `$()`, on `$?()`, and on the literal parts of a command that
carries `%{...}` holes. It says nothing about a command already continued with
`\`, or one that fits on a line.

It is a violation, so `--strict` fails on it. Nothing in wand's own tree trips
it.

### Also

- The manifest `wand t --fix` writes now stands off from the file below it.
  It was written against the first import, which is correct and reads as
  hand-patched: every file in the tree puts a blank line there, and so does
  the formatter
- `Diag.AppendToLine`, a fix that puts text at the end of the flagged line.
  The editor offers it as a code action like any other

Nothing else changed. `wand t`, `wand d`, `wand -e` and the rest are exactly
0.54.0's.

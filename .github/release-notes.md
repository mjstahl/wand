## 0.54.0 - 2026-08-28

**This release changes the command line, and scripts that call `wand t` or
`wand e` need editing.** One rule now covers the whole CLI:

> A file is named directly. An expression is given with `-e`/`--expr`.

```
wand t script.wand            # was: wand t --file script.wand
wand t -e "1 + 2"             # was: wand t "1 + 2"
wand -e "1 + 2"               # was: wand e "1 + 2"
```

`wand e` no longer exists, and `wand t --file` no longer exists. Nothing is
silently accepted: the old spellings report what is wrong and name the command
that works.

### Why

`wand t` took an expression, and an expression is indistinguishable from a
file name — `deploy.wand` is itself a valid path expression. So:

```
$ wand t ./deploy.wand
Path
$ echo $?
0
```

That is not a typo being tolerated. It is a checking tool reporting success
for a file it never opened, and the exit code says the file is clean. In CI it
passes. The other shapes were louder but no better: `wand t deploy.wand` said
`unbound variable 'deploy'`, which reads like a problem in the program rather
than in the command, and sends a reader looking for a definition that was
never missing.

Making the file the default removes the failure rather than documenting it.
When the argument is not a file, there is now something useful to say:

```
$ wand t "1 + 2"
Error: no such file: 1 + 2
       did you mean: wand t --expr "1 + 2"

$ wand e "1 + 2"
Error: no such file: e
       did you mean: wand -e "1 + 2"
```

A name that ends in `.wand` gets no hint — it is a file that is not there, and
offering `--expr` on a typo is noise.

### Also changed

- `--load` alongside a file is refused rather than ignored. It seeds a
  session, which checking a file does not use, and a flag accepted and dropped
  is a check that did not happen
- An unknown option is named rather than taken for the file. `wand t -e`
  used to read `-e` as a file name and report an argument count
- `--dry-run` and `--trace` alongside `--expr` are refused. They are built
  around a script's effects and there is no mode to hand an expression;
  accepting one and ignoring it would run for real, which is the single
  mistake `--dry-run` exists to prevent

### Manifests and `--strict`

**A missing manifest is now a violation.** `A-USES2` becomes `V-USES2`. A file
that reaches outside itself and declares nothing has no line to be checked
against, which is the thing the manifest exists to stop. A manifest *wider*
than the file stays `A-USES1` and stays advisory — imprecise, not unsafe.

```
$ wand t deploy.wand
warning: 1:1: V-USES2: this file performs IO and does not say so; it could
declare "uses {IO}"

$ wand t --fix deploy.wand
V-USES2: 1 — inserted "uses {IO}"
```

**`--strict` now works on a run, and implies `--lint`.** It reports the
findings and refuses to run if any is a violation:

```
$ wand deploy.wand --strict
warning: 1:1: V-USES2: ...
exit 1        (the script does not run)
```

It used to mean nothing on its own — it was passed to the script, so someone
who typed it before a deploy asked for a gate, got an ordinary run, and was
told nothing. That gives one shape for each end of a script's life:
`wand t --strict` while writing it, `wand deploy.wand --strict` where it runs.

A plain `wand deploy.wand` is unchanged: no findings, no delay. A script that
takes a `--strict` of its own is given it after `--`, the same trade already
made for `--dry-run`. Advice never blocks a run.

### Added

**`--help` and `-h` on every command**, printing that command's usage:

```
wand t --help      wand f --help      wand s --help      wand d --help
wand v --help      wand i --help      wand lsp --help    wand h --help
```

`wand i --help` used to start an interactive session and `wand lsp --help` a
language server — both of which hang instead of answering. `wand d --help`
looked up documentation for a name called `--help` and exited 0.

A flag after a script still belongs to the script, so `wand deploy.wand
--help` passes `--help` through as before. `--help` after `-e` is still part
of the expression.

**Clearer refusals**, from sweeping the flag combinations:

- An unknown option is named by every command that takes an argument, rather
  than read as one. `wand f --nope` looked for a file called `--nope`,
  `wand v --nope` for a module, and `wand d --nope` reported no documentation
  for it and exited 0
- A flag that takes a value and did not get one says which value is missing.
  `wand t -e` reported an unknown option, which is the wrong problem — `-e`
  is a flag it has
- `wand t --fix` says `nothing to fix in <file>` when it changed nothing. It
  printed nothing and exited 0, which reads exactly like a file that was
  fixed

### Upgrading

Three substitutions cover it:

| was | now |
|---|---|
| `wand t --file F` | `wand t F` |
| `wand t 'EXPR'` | `wand t -e 'EXPR'` |
| `wand e 'EXPR'` | `wand -e 'EXPR'` |

`--fix`, `--json`, `--strict` and `--load` are unchanged in spelling. `--fix`
now applies to the file argument, and is refused with `--expr`, which it never
worked with.

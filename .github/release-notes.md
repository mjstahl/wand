## 0.54.0 - 2026-08-28

**This release changes the command line. Scripts that call `wand t`, `wand e`
or `wand v` need editing.** One rule now covers the whole CLI:

> A file is named directly. An expression is given with `-e`/`--expr`.

```
wand t script.wand            # was: wand t --file script.wand
wand t -e "1 + 2"             # was: wand t "1 + 2"
wand -e "1 + 2"               # was: wand e "1 + 2"
```

Nothing is silently accepted: every old spelling reports what is wrong and
names the command that works. The **Upgrading** table at the end is the whole
list.

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

`docs/llm-authoring.md` had a section for "the things that are got wrong in
practice", and this was its first entry, noting it had been got wrong twice
while writing that document. That entry is deleted rather than reworded.

### One command for "what is this"

`wand v` is merged into `wand d`, and `wand v` is now the version:

```
wand d List.map     # the doc, as before
wand d List         # every name in the module      (was: wand v List)
wand d              # everything in scope           (was: wand v)
wand v              # the version                   (was: wand V)
```

Two commands answered the same question, split on a line nobody could guess:
`wand v List.map` said `Unknown module`, and `wand d List` said `no doc`. Each
rejected what the other took. `wand d`'s own usage already claimed that "a
module name takes every name in it" — the code for it existed under `-x`/`-t`
and was never wired to the plain path.

`--load` carries through, so `wand d --load mine.wand` still answers "what
does my file define".

**`wand d --json` is now always an array** — for a single name as much as for
a module or the whole scope. It used to return a bare object for one name, so
a consumer had to branch on what was asked. The shape belongs to the command
now, not to the argument.

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

### `--help` on every command

Every command answers `--help` and `-h` with its own usage, and answers it
before doing anything:

```
wand d --help      wand f --help      wand h --help      wand i --help
wand l --help      wand s --help      wand t --help      wand v --help
```

Two of those used to hang rather than answer: `wand i --help` started an
interactive session and `wand lsp --help` started a language server. A third,
`wand d --help`, looked up documentation for a name called `--help`, found
none, and exited 0.

A flag after a script still belongs to the script, so `wand deploy.wand
--help` passes `--help` through as before. `--help` after `-e` is part of the
expression.

The language server is also `wand l` now — it was the one command without a
single-letter spelling. `wand lsp` still works, so an editor configured to
spawn it needs no change.

### Clearer refusals

From sweeping every command against its own flags, in both orders, with
values present and missing:

- **An unknown option is named** rather than read as an argument. `wand f
  --nope` looked for a file called `--nope`, `wand v --nope` for a module of
  that name, and `wand d --nope` reported that it had no documentation and
  exited 0
- **A flag that takes a value and did not get one** says which value is
  missing, instead of being taken for the argument
- **`wand t --fix` says `nothing to fix in <file>`** when it changed nothing.
  It printed nothing and exited 0, which reads exactly like a file it did fix
- **`--load` alongside a file is refused** rather than ignored. It seeds a
  session, which checking a file does not use, and a flag accepted and
  dropped is a check that did not happen
- **`--dry-run` and `--trace` are refused with `-e`.** They are built around a
  script's effects and there is no mode to hand an expression; accepting one
  and ignoring it would run for real, which is the single mistake `--dry-run`
  exists to prevent

### Upgrading

| was | now |
|---|---|
| `wand t --file F` | `wand t F` |
| `wand t 'EXPR'` | `wand t -e 'EXPR'` |
| `wand e 'EXPR'` | `wand -e 'EXPR'` |
| `wand v` | `wand d` |
| `wand v Module` | `wand d Module` |
| `wand V` | `wand v` |

`--fix`, `--json`, `--strict` and `--load` are unchanged in spelling. `--fix`
now applies to the file argument and is refused with `-e`, which it never
worked with. `wand lsp`, `wand f`, `wand s`, `wand i` and running a script are
unchanged.

Two changes are not spellings and will not announce themselves: `--strict` on
a run now refuses to run a file with a violation, and a missing manifest is
now such a violation. A CI step that runs `wand deploy.wand --strict` against
a file with no `uses` line will start failing. `wand t --fix` writes the line.

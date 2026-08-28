## 0.54.0 - 2026-08-28

**This release changes the command line, and scripts that call `wand t` or
`wand e` need editing.** One rule now covers the whole CLI:

> A file is named directly. An expression is given with `-e`/`--expr`.

```
wand t script.wand            # was: wand t --file script.wand
wand t --expr "1 + 2"         # was: wand t "1 + 2"
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
- `--dry-run` and `--trace` alongside `--expr` are refused. They are built
  around a script's effects and there is no mode to hand an expression;
  accepting one and ignoring it would run for real, which is the single
  mistake `--dry-run` exists to prevent

### Upgrading

Three substitutions cover it:

| was | now |
|---|---|
| `wand t --file F` | `wand t F` |
| `wand t 'EXPR'` | `wand t --expr 'EXPR'` |
| `wand e 'EXPR'` | `wand -e 'EXPR'` |

`--fix`, `--json`, `--strict` and `--load` are unchanged in spelling. `--fix`
now applies to the file argument, and is refused with `--expr`, which it never
worked with.

## 0.53.0 - 2026-08-26

A layout rule: a newline ends a statement wherever a statement can end, and
indentation says what continues. Less punctuation to write. The rest is
`wand f`, which had a run of ways to damage the file it was asked to tidy.

### Added

- **`V-SHADOW1`.** A top-level name bound twice in one file reports on the
  second binding. The first is not dead, so which value the name means
  depends on the line it is read from. A binding named `_` is exempt, and an
  inner binding shadows freely
- **`docs/llm-authoring.md`.** What in wand serves work that a model writes
  and a person reads, and why the syntax is ML-style. Rationale, not a
  benchmark

### Changed

- **A newline ends a statement wherever a statement can end.** It used to end
  one at the top level and mean nothing inside a bracket, which is two rules
  for one piece of punctuation. Indentation decides now. A bracket the
  statement opened suspends the rule until it closes, so an argument list
  still runs down the page
- **A binding inside a block ends at a newline.** `let a = 1` and then `a`
  below it needs no `;` and no `in`. Both spellings still work, and `wand f`
  prints back the one you wrote
- **A definition runs onto an indented line without brackets.** `let y = f`
  and then an indented `1` is one application. It used to be a parse error
  asking for brackets
- **The bracket a constructor or a type declaration takes obeys that rule
  too.** This changes what three spellings mean. A `(` back at the
  declaration's own column opens the next item, not a field list. `type Foo`
  with `(x: Int)` below it at column one now names the missing `=`, and
  `type Colour = Red` above a line opening with `(` is two items. Indent the
  bracket and it reads as the payload it always did

### Fixed

- **`wand f` writes source that parses.** Six shapes broke this: a wrapped
  `if` condition losing its `then`, a wrapped `try` doing the same to the
  keyword after it, a bracket written onto a glob, a glob holding an unmatched
  `[`, a URL that ate the `;` ending its statement, and an item opening with
  an operator. `wand f` writes in place, so each of these corrupted the file
  it was asked to tidy
- **`wand f` writes source that means the same thing.** A field access lost
  the brackets that made it one: `(6).o`, `(S 6).o` and `(./p).log` each read
  back as something else, and the last one typechecks, so nothing said a
  word. A run of bare constructor arguments came back reading two of them as
  one application. `$(i)` runs the command `i` and `$ (i)` runs whatever the
  value `i` holds; both printed as `$(...)`. `2222222.5` printed as
  `2.22222e+06`, a number wand cannot read
- **`wand f` settles**, and keeps every comment where its author put it
- **`wand f` is no longer exponential in nesting depth.** A 7.4KB file that
  took 5.2s takes 0.01s
- **A local multi-clause function keeps its clauses.** `stdlib/List.wand` is
  the one file in the repository whose formatting changed

Most of the formatter fixes come from a second fuzz oracle in `test/fuzz`, new
in this release. It checks four properties of `wand f` on anything that
parses: the output parses, it settles after one pass, every comment survives,
and the file still means what it meant. It runs nightly, and
`test/fuzz/known.txt` -- the list of signatures found and not yet fixed -- is
empty. None of it reaches an installed wand.

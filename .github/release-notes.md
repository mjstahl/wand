## 0.53.1 - 2026-08-28

A `wand f` release. The fuzz oracle added in 0.53.0 got its first full-length
runs, and they found twelve ways to write a file back wrong: ten in the
formatter, one in the lexer, one in the parser. Every one now has a reproducer
that `dune test` runs on every change.

`wand f` writes in place, so all of these damaged the file they were asked to
tidy. If you format, this is the release to take.

### Fixed

- **`wand f` writes source that parses.** Five shapes broke this. An
  application whose callee spans lines ends where the callee's bracket closes,
  and the guard for that counted only what the *first* line left open. `let x
  : T = e` is written by a branch of its own, which went around the helper
  that brackets a wrapped value. A top-level `let` dropped the brackets that
  are a pattern's syntax there, so `let (e.I) = ""` came back as
  `let e.I = ""` and stopped at the dot. A parameter list is read as names
  until the `->` or the `=`, and the brackets that make `t.A` a pattern in one
  were dropped the same way. A unary operator written onto its operand made
  one token of the two: `- ./` came back as `-./`, the float operator ML has
  and wand does not
- **`wand f` writes source that means the same thing.** A top-level `let`
  reads its head as the name being defined, so `let (E) = []` came back as a
  value named `E` rather than a match against the constructor, and
  `let (Some x) = e` as a one-clause definition of a function called `Some`. A
  bare constructor absorbs the bracket after it, which is harmless only while
  that bracket holds the whole argument: `O (())` came back as `O ()`, the
  empty field list. An `import` renders as the keyword and then a path, and a
  `.` after it runs into that path, so `(import /t).s` came back naming a
  different file. A decimal literal too large for a double lexes to infinity
  and was written back as `inf`, which re-reads as a variable. Most of these
  still typecheck, so nothing downstream said a word
- **`wand f` settles.** A comment kept whatever trailing whitespace its source
  had, so the formatter wrote a line ending `-- `, the next pass lexed that
  comment without the space, and the file alternated between the two
  spellings for ever. Four seeds found it in one night
- **A `with` below a `try` is a statement of its own.** The hint that wand has
  no `try ... with` was owed on any following `with`, including one back at
  the `try`'s own column — so a top-level `with ... as ... -> body` under a
  `try` did not parse, though the reference gives four examples of the form
  and it runs. The layout rule decides now, as it does everywhere else. The
  hint still reports on the same line, and on a line indented past the `try`
- **`%{...}` ends where wand's braces balance, not where a shell's do.** Every
  brace was counted, including one inside a `$(...)`, where a brace is an
  ordinary character. An interpolation could end early, swallow a brace the
  string meant to keep, and come back a `}` short. All three interpolation
  forms had their own copy of the loop and all three had it

Nothing here changes a program that was already correct, with one exception
worth knowing: a top-level `with` under a `try` used to be a parse error and
is now what the reference always said it was.

The findings came from four-shard, 45-minute runs over roughly 5.5M mutated
inputs each. `test/fuzz/known.txt` — the list of signatures found and not yet
fixed — is still empty. The nightly job also reports better: a finding's
signature now carries the parse error, so two different bugs can no longer
share one issue, and the job dedups against a listing rather than a search
index that had not caught up yet.

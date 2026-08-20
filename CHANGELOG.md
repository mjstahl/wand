# Changelog

## [0.19.0] - 2026-08-19

### Added

- Add `Test.group`: child tests that share the group's label and
  whatever its body binds, nesting to any depth — a `Suite` is a third
  `TestOutcome` constructor, and `wand s` prints each child under the
  path of labels that led to it. Setup is the bindings above the child
  list, teardown a `with` bracket around it; a raise in the body is the
  group's one failure (`c0871aa`)

### Changed

- Change `Test.test` to catch a raise in its own block and return it as
  that test's labeled failure — `label: raised: <why>` — where it used
  to escape as an error carrying no label. A raising child no longer
  takes its siblings down with it (`c0871aa`)
- Change `wand f` to step in the continuation lines of an `if`,
  `match`, or `handle` that starts mid-line, rather than landing its
  `else` or its cases flush with the line that introduced it; an else-if
  chain stays one flat ladder (`ab28876`)
- Change `wand f` to open a list, map, tuple or sequence bracket on
  the line that introduces it — after `=`, after `in`, and after a
  trailing lambda's `->` — instead of giving the bracket a line of its
  own (`04c60f7`)

### Fixed

- Fix `wand f` measuring a map's width from the indent it wraps to
  rather than the column its brace lands at, which let a map run past
  the margin (`04c60f7`)
- Fix `wand f` rendering a list's and a tuple's items at the
  sequence's own indent while placing them two columns in, so an item
  that broke internally wrapped to the left of the item itself
  (`04c60f7`)
- Fix the unbound-name hints to name the command as the usage output
  lists it: an unknown name points at `wand v`, not `wand env`. The
  documentation follows throughout — every command is written in the
  short form that heads its usage line. Both spellings still dispatch
  (`2332623`)

[0.19.0]: https://github.com/mjstahl/wand/releases/tag/v0.19.0

## [0.18.1] - 2026-08-19

### Changed

- Change `$()`/`$?()` to exec a command directly when the shell would
  find nothing to do in it — no operators, expansions, quotes, or
  builtins — skipping `/bin/sh`'s startup per spawn (~5ms on macOS,
  whose /bin/sh is bash). Anything shell-shaped still runs through
  `/bin/sh`, and a missing program reports exit 127 with sh's stderr
  line on either path (`c678a8e`)

[0.18.1]: https://github.com/mjstahl/wand/releases/tag/v0.18.1

## [0.18.0] - 2026-08-19

### Removed

- Remove the bracket map forms: `[x = 1]` literals, `[x = a]` patterns,
  and `let [test] = import Test` no longer parse, each refused with an
  error naming the brace spelling — "a map is written in braces --
  {k = v}, not [k = v]". The `A-MAP1` finding and its migration machinery
  retire with the syntax (`ba63d5c`)

### Fixed

- Fix `<=` and `>=` to order strings, as `<` and `>` always did —
  `"a" <= "b"` typechecked and then failed at run time (`7359637`)

[0.18.0]: https://github.com/mjstahl/wand/releases/tag/v0.18.0

## [0.17.0] - 2026-08-18

### Changed

- Change map syntax to braces: `{x = 1, y = 2}` literals, `{}` as the
  empty map (sugar for `Map.empty`, which stays), and brace map patterns
  that pun — `{status}` binds the key's value to a variable of its own
  name, `{x = a}` renames, and a quoted key takes `= pat`. Import
  destructuring follows: `let {test} = import Test`. Map values print in
  braces, and `wand fmt` writes every bracket form back as braces
  (`253ae90`, `1cdb76d`, `5ab4922`, `c9b793d`)
- Change the formatter to write a single-constructor type whose
  constructor repeats the type's name as the shorthand the parser already
  reads: `type Container(name: String, ready: Bool)` — named fields only;
  positional payloads, differently named constructors, and
  multi-constructor types keep the long form (`8f2f4d5`)

### Added

- Add `A-MAP1`: a map still written in brackets is an advisory finding
  carrying the flagged line with its brackets flipped, so `wand t --fix`
  migrates a file finding by finding to a fixed point. The bracket forms
  parse for this release and are removed in the next (`90f40eb`)

[0.17.0]: https://github.com/mjstahl/wand/releases/tag/v0.17.0

## [0.16.0] - 2026-08-18

### Changed

- Change the formatter to indent a nested match as a block, the same shape
  a multi-line `(...)` sequence gets: the opening paren ends the arrow's
  line, the nested match sits two spaces deeper than the outer arm, and
  the closing paren returns to the outer arm's column — instead of
  printing the nested arms flush with the outer ones. Handler arms with a
  match body format the same way (`44e66fe`)
- Change the formatter to move a string that escapes its quotes between
  backticks, where a quote is a quote: `"say \"hi\""` becomes
  `` `say "hi"` ``, splices intact for interpolated strings. The quoted
  form is kept when backticks could not reproduce the value exactly and
  visibly: a backtick in the text, a literal `%{`, or control characters
  (`9624144`)
- The demo scripts are reformatted with the current formatter, picking up
  0.13.0's canonical manifests; the decode examples' inline JSON loses its
  backslashes to the backtick preference (`44e66fe`, `9624144`)

[0.16.0]: https://github.com/mjstahl/wand/releases/tag/v0.16.0

## [0.15.0] - 2026-08-18

### Added

- Add hover for local names: parameters, `let ... in` names, and pattern
  variables now answer with their inferred type, at the binder and at every
  use — including inside `%{...}` splices. Locals carry no positions, so the
  item enclosing the cursor stands in for lexical scope, the innermost
  binding winning when an item rebinds a name (`65319f5`)
- Add documentation to completion items: the expandable panel shows the
  signature as a name-over-type block with the doc string beneath — the
  inline detail stays, but the suggest widget truncates it, so the full
  answer is one chevron away (`65319f5`)
- Add `make install` in `editors/vscode/`: one command runs `npm install`,
  compiles, packages the `.vsix`, and side-loads it, finding the `code` CLI
  in the macOS app bundle when it is not on `PATH` (`cacba1e`)

### Changed

- Change hover to render the name on its own line with the type beneath it,
  so a long signature — an effect row especially — no longer wraps mid-row
  (`65319f5`)
- Change the extension to resolve the wand binary itself when `wand.path`
  is the bare default and `PATH` has none: install.sh's `~/.local/bin`,
  then Homebrew's prefixes — a Dock-launched VS Code carries no shell
  `PATH` (`cacba1e`)
- Change the Rehearse lens to appear on every file — on the first line when
  there is no manifest — and to rehearse against `/dev/null`, so a script
  that reads stdin reports on empty input instead of blocking (`cacba1e`)

[0.15.0]: https://github.com/mjstahl/wand/releases/tag/v0.15.0

## [0.14.0] - 2026-08-18

### Added

- Add `--json` to `wand d`: one object on stdout — `name`, `type`, `doc` — with a fact the session lacks reported as `null` rather than omitted, so "no doc" reads as an answer and not a schema difference (`6f12546`)
- Add `--json` to `wand v`: an array over the scope, bindings as `{"name","type"}` and modules as `{"name","module":true}`; `wand v --json <module>` lists the members with qualified names, so an entry feeds straight into a follow-up `wand d` or `wand t` (`6f12546`)
- Add `--json` to `wand s`: one object for the whole run — per-test entries under `tests` (a pass carries its `label`, a fail its `message`; a test that raised reports `"error"`, and both count as failed), files that would not load under `errors`, and the `passed`/`failed` counts. While the tests run their own prints go to stderr, so stdout holds nothing but the JSON; exit codes are unchanged (`6f12546`)

With these, every command whose output a tool might read — `t`, `d`, `v`, `s` — has a `--json` form. Each shape is documented in the reference's `--json` section.

[0.14.0]: https://github.com/mjstahl/wand/releases/tag/v0.14.0

## [0.13.1] - 2026-08-18

### Fixed

- Fix multi-line REPL entry for local `let` chains: a line that is itself an open binding — a bare `=` no `in` closes — now keeps the continuation prompt up until a line supplies the body (`in fib 10`, or a plain expression). Submitting there did not even error before: a chain's body may be implicit, so the prefix parsed, bound `Unit`, and the remaining equations landed in fresh entries (`a19ebd5`)
- Fix mutual recursion in the REPL: a trailing `and` holds the entry open, so a group is entered by ending its first line with the `and` and finishing with a blank line — the first line alone does not typecheck, its partner being unbound (`a19ebd5`)
- Fix a mutual group binding silently in the REPL: each name of the group is now echoed with its type, the way a lone binding is (`a19ebd5`)

### Changed

- Change the reference to state what the REPL actually does with repeated equations — specific patterns before catch-alls whatever the entry order, the newer of two equal patterns winning, a not-yet-exhaustive set accepted as `{Raise}` — and to show the mutual-recursion entry transcript and the real multi-line continuation rules (`a19ebd5`)

[0.13.1]: https://github.com/mjstahl/wand/releases/tag/v0.13.1

## [0.13.0] - 2026-08-18

### Changed

- Change effect labels to a single canonical order, alphabetical (`Env, FS.Read, FS.Write, IO, Proc, Raise, Shell`): displayed signatures, manifests, and suggestions all agree by construction (`9ff454e`)
- Change `wand fmt` to canonicalize the manifest — labels and `Shell(...)` binaries sorted, wrapping one per line past the column budget — and to alphabetize the leading block of plain imports; let-imports keep their order, and a comment in the region pins it (`9ff454e`)
- Change error reporting to carry positions as data end to end: lex errors now name their line and column (pointing at the start of the failing token), and manifest errors anchor at the manifest line — in both text and `--json` (`f06a293`)
- Change diagnostics to carry extents, not points: a finding spans the whole item it is about, a type error the whole expression at fault, and `--json` reports `end_line`/`end_col` when a diagnostic has real width (`a1f71e0`)

### Added

- Add `wand t --fix`: apply every machine-applicable correction to the file in place — the suggested manifest line, dead imports, corrected lines — re-checking to a fixed point; a parse error, or a type error carrying no fix, refuses the whole run and nothing is written (`2ee9e25`)
- Add `wand lsp`: the language server, a subcommand on the compiler binary so the editor can never disagree with `wand t`. Diagnostics as you type, hover showing the signature with its effect row plus the doc string, completion (a member of an unimported stdlib module carries its `import` on accept), quick fixes from every finding that knows its correction, whole-document formatting, and go to definition — including into the standard library, opened from the binary as read-only documents (`162ebcd`, `ac3be7f`, `f527cc9`)
- Add editor auto-import: typing `FS.write_file!` in a buffer that has not imported `FS` inserts `import FS` into the sorted block and puts `FS.Write` into the manifest, with no gesture; `Shell` is never changed automatically — those edits stay one visible click away as quick fixes (`ac3be7f`)
- Add the VS Code extension at `editors/vscode/`: domain literals highlighted as the constants they are, embedded shell highlighting inside `$()`/`$?()` with `%{...}` splices back to wand, and a "Rehearse (dry run)" code lens on the `uses {...}` line; not on the Marketplace yet — its README shows how to build and sideload (`84936e1`)

[0.13.0]: https://github.com/mjstahl/wand/releases/tag/v0.13.0

## [0.12.0] - 2026-08-17

### Changed

- Change a destructuring `let` to bind a list pattern's leading elements and ignore the rest, as map patterns already do with keys; `match` arms and function equations still require the exact length (`f598bc3`)
- Change `wand h` and the REPL's `:h` to list commands short form first, alphabetized by it (`64f5f85`)
- Change `:reset` to clear the screen along with the session's bindings (`6a01dd9`)

### Added

- Add REPL shortcuts `:v` (`:env`), `:c` (`:clear`), `:s` (`:reset`) (`6a01dd9`)
- Add command shortcuts `v` (`env`), `f` (`fmt`), `s` (`test`), `V` (`version`) (`1b74e02`)
- Add `V-IMP1`: two imports in the leading import block binding the same name leave the first binding dead — rename one (`[parse = csv_parse]`) or drop it (`def6aa0`)

### Removed

- **Breaking:** remove `--version` and `-V`; the version is a command, `wand V` or `wand version` (`4db26e7`)
- **Breaking:** remove the `format` alias for `fmt` (`1b74e02`)
- **Breaking:** remove `:quit` and `:q`; `:x` (`:exit`) is the one way out of the REPL (`6a01dd9`)

[0.12.0]: https://github.com/mjstahl/wand/releases/tag/v0.12.0

## [0.11.0] - 2026-08-17

### Changed

- Change arithmetic (`+ - * /`, unary `-`) to be polymorphic over `Int` and `Float`; `Num` in a signature means either, decided at use (`77dbe38`)
- Change error messages to name the wand construct instead of a source language (`18b0131`)

### Added

- Add `Stream`: fold files of any size in bounded memory — `FS.stream_lines`, `IO.stdin_lines`, `Test.with_lines` (`539eeee`)
- Add `Float` module: `of_int`, `round`, `floor`, `ceil`, `abs` (`77dbe38`)
- Add corrective errors for `^`, OCaml float operators, character literals, `begin ... end`, and foreign stdlib names such as `List.iter` (`35379bf`)
- Add discovery pointers to unbound-name errors: `'wand env' lists the modules, 'wand env List' one module's members` (`35379bf`)
- Add `install.sh`: one-line install with platform detection and checksum verification (`a871d73`)

[0.11.0]: https://github.com/mjstahl/wand/releases/tag/v0.11.0

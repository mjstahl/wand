# Changelog

## [0.35.0] - 2026-08-22

### Changed

- **Breaking:** `Par.race` refuses inside a handler. An effect cannot reach
  a handler on another domain, so the branches cannot run where they were
  written: the race answered with its first thunk and said nothing, and a
  test of racing code tested one branch and passed. The message names the
  fix — move the handler inside each thunk. `--dry-run` and `--trace` still
  run a race, left-biased, because each only reports what the work would do

[0.35.0]: https://github.com/mjstahl/wand/releases/tag/v0.35.0

## [0.34.0] - 2026-08-22

### Changed

- **Breaking:** a comment is `--` to the end of the line, and that is the
  whole form. `(*` is a lex error that names it. A comment reads no
  brackets, so pasted text survives whatever it holds — including the `*)`
  that a shell `case` arm writes
- **Breaking:** documentation is a run of comment lines directly above a
  definition, which `wand d` and an editor hover print. Each line stands
  alone, the lines are consecutive, and the last one sits on the line
  above, so a comment after code documents nothing and a blank line ends
  the run

[0.34.0]: https://github.com/mjstahl/wand/releases/tag/v0.34.0

## [0.33.0] - 2026-08-21

### Added

- `Test.with_shell_results` supplies the `ShellResult` for each `$?(cmd)` a
  test runs, so a command can exit non-zero and the failure path can be
  tested. A command the test does not name exits zero with no output

### Changed

- `Test.with_shell` and `Test.shell_calls` now stand in for `$?(cmd)` as
  well as `$(cmd)`. Both handled `Shell!run` only, and `$?(cmd)` performs
  `Shell!capture`, so a mock written for a script that inspects an exit code
  did nothing and the test passed for the wrong reason. Under `with_shell` a
  `$?(cmd)` exits zero and carries the output written for that command

[0.33.0]: https://github.com/mjstahl/wand/releases/tag/v0.33.0

## [0.32.0] - 2026-08-21

### Added

- `Port.to_int` and `Port.of_int`. `Port` could be written, ordered,
  compared, decoded and interpolated, and nothing took `8080` out of
  `:8080`, so a script could not pass a port to a command. The string form
  is unchanged and is the address: `"host%{:8080}"` is `"host:8080"`.
  `of_int` refuses a number outside 0–65535 (`2738ddc`)

### Changed

- **Breaking:** `Par.timeout` refuses to run under a handler. A race runs
  only its first thunk while one is installed, so the sleeper never ran and
  the deadline never fired — work that only the deadline would have stopped
  ran forever, hanging a test suite with no message. Put the handler inside
  the thunk instead: `Par.timeout d (fn () -> with_shell mocks (fn () ->
  ...))` keeps the mock and fires the deadline. A rehearsal and a trace are
  not refused (`7016818`)
- `wand f` keeps a value that ends in a bracket on the line that opens it,
  the way a value that is a bracket already did. Run `wand f` over a
  formatted repository once: files laid out by 0.31.0 will change
  (`9cdb6f1`)

[0.32.0]: https://github.com/mjstahl/wand/releases/tag/v0.32.0

## [0.31.0] - 2026-08-21

### Changed

- **Breaking:** `:` is no longer cons. `1 : [2, 3]` and `[h : t]` are parse
  errors naming `::`, which 0.30.0 read as well and `wand f` writes. The
  `:` still binds where cons bound, so the message is reached rather than
  "expected ->, got :" from wherever the expression happened to end
  (`5d230d6`)

[0.31.0]: https://github.com/mjstahl/wand/releases/tag/v0.31.0

## [0.30.0] - 2026-08-21

### Added

- Cons is `::`. `1 :: [2, 3]` in an expression, `[h :: t]` in a pattern.
  `:` is a type annotation or a port literal and nothing else, so the
  lookahead that told `(p: Pod)` from `(h : t)` is gone with the ambiguity
  that needed it (`043c7a3`)
- A bare `h :: t` pattern is read, and `wand f` writes `[h :: t]`. The
  brackets say list, the way `[a, b, c]` does. `Some h :: t` is
  `(Some h) :: t` (`043c7a3`)
- A pattern carries a type inside a constructor's payload: `Ok (p: Pod)`,
  and inside a tuple payload, `Ok (p: Pod, n)`. That is where a decoder's
  result lands, and it was the one place a pattern could not be annotated
  (`78e7228`)

### Changed

- **Deprecated:** `:` as cons is still read, and `wand f` writes `::`.
  It becomes a parse error in the next release. Running `wand f` over a
  file is the whole migration (`043c7a3`)
- `V-IMP1` warns on any two imports that bind one name, where it used to
  stop at the first item of anything else. Imports bind before a file's own
  bindings wherever they are written, so a use between two imports reads
  the second one — which the rule had assumed was a genuine use of the
  first (`59a1e6f`)
- A `:` in a pattern with no type after it names `[x :: xs]` (`043c7a3`)

[0.30.0]: https://github.com/mjstahl/wand/releases/tag/v0.30.0

## [0.29.0] - 2026-08-21

### Added

- A record update: `Tally(t, failed = t.failed + 1)` is `t` with one field
  replaced. The record comes first, then the fields that change. A field
  not named keeps what the base holds, and naming one twice is a type
  error. `{t with failed = 1}` is a parse error that answers with this
  form, carrying the names you wrote (`fea51a5`, `66ab3f6`)
- `FS.delete_tree` and `FS.copy_tree`, each with a raising sibling, so
  `rm -rf build/` and `cp -r` have a wand spelling. Neither follows a
  symlink out of the tree: a delete unlinks it, a copy recreates it. A
  copied file keeps its mode (`78ec907`)
- `Shell.ok? r` is `r.code == 0`, the first question a script asks of a
  `$?()` (`78ec907`)
- `Decode.map3`, for a decoder built by hand from three fields. Wider is
  `and_then`, or a derived `T.decoder` (`fea51a5`)
- `Float.format 1 0.3333` is `"0.3"`. A width is a printing decision, so
  it answers a `String` (`fea51a5`)

### Changed

- **Breaking:** six `Env` operations now say what they carry and what
  resumes them. A handler case resuming `Env!get` with an `Int`
  typechecked, and `Env.get` answered `Some(42)` where its signature says
  `Option String`. That is now a type error (`ed4f8b8`)
- A nullary constructor applied to parentheses names itself:
  `t.eq None (usage row)` said "expected Option 'a, got Option (String,
  Int) -> 'a", and now says `'None' takes no arguments` and to write
  `(None)` (`11ef36d`)

[0.29.0]: https://github.com/mjstahl/wand/releases/tag/v0.29.0

## [0.28.0] - 2026-08-21

### Added

- `Size` crosses to a number and back: `Size.to_bytes 4KB` is `4000`,
  `Size.of_bytes 6466` is `6466B`, and `Size.format` is the readable
  spelling, `"6.5KB"`. A byte count below zero reads as `0B` (`a1e7f89`)
- `+` and `-` add two `Size`s or two `Duration`s, through a new `Add`
  constraint sitting between `Num` and `Ord`: `Int`, `Float`, `Size`,
  `Duration`. `100MB + 4KB` is `100004000B`, and `1h + 30min` is `1h30m`.
  `*`, `/` and unary `-` keep `Num`. A sum of sizes is written in bytes,
  and a subtraction that would go below zero floors there (`a37d13a`)
- `List.filter_map` applies a function to every element, keeps each `Some`
  value and drops each `None` (`7fcb947`)

### Changed

- **Breaking:** `FS.size` answers `Result String Size`, and `FS.size!`
  answers `Size`, where both answered bytes as an `Int`. `Size.to_bytes`
  is the number back (`bc2ac93`)
- `wand f` writes back the binding spelling that was written.
  `(let x = 1; x + 2)` used to come back as `let x = 1 in x + 2` (`8995887`)
- `wand f` wraps a `let ... in` chain in a lambda body under the `fn`,
  where the continuation lines used to sit level with it (`8995887`)
- `wand f` closes two brackets on one line when both would close at the
  same indent (`e870013`)

[0.28.0]: https://github.com/mjstahl/wand/releases/tag/v0.28.0

## [0.27.0] - 2026-08-21

### Added

- Add a binding that lives for the rest of its block: a `let` before a `;`
  inside parentheses binds for every statement after it, so a body that
  names two intermediates costs no indentation. `;` ends the binding's
  right-hand side, exactly as a newline does at the top level of a file.
  The same three words parsed before and bound nothing — the binding took
  `Unit` for a body, and the error named the use site rather than the
  mistake. `let ... in` keeps its own meaning: it names a value for one
  expression, so `(let x = 1 in x + 1; 9)` still scopes `x` over `x + 1`
  alone. `wand f` writes the block form when more than one statement
  follows a binding, and `let ... in` when one expression does (`0e737cc`)

### Changed

- **Breaking:** A block cannot end with a binding. `(f (); let x = 1)` is a
  parse error saying the binding has no body, where it used to be accepted
  and bind nothing (`0e737cc`)
- **Breaking:** A binding that bound nothing now binds, so a program that
  shadowed a live name answers differently: `let x = 0 in (let x = 1; x)`
  was `0` and is `1`. Every other program this touches is one that does not
  typecheck today (`0e737cc`)

[0.27.0]: https://github.com/mjstahl/wand/releases/tag/v0.27.0

## [0.26.0] - 2026-08-21

### Changed

- **Breaking:** `Size`, `Version`, `Port` and `IPv4` compare. Each was a
  type error under `<`, `>`, `<=` and `>=`. A `KB` is 1000 bytes, because
  the spelling is the SI one and the lexer has no `KiB`. `Version` follows
  semver precedence, prerelease rules included, so
  `1.2.3-alpha.1 < 1.2.3-alpha.2 < 1.2.3-beta < 1.2.3`. A `Port` is its
  number and an `IPv4` is its 32 bits (`1b10b92`)
- **Breaking:** `List.sort` reads these values rather than their text, so
  it answers with a different order than before —
  `[10.0.0.10, 10.0.0.9, 10.0.0.2]` sorted to
  `[10.0.0.10, 10.0.0.2, 10.0.0.9]` and now sorts to
  `[10.0.0.2, 10.0.0.9, 10.0.0.10]`. `1.10.0` sorted below `1.2.3`, and
  `1GB` below `999MB` (`1b10b92`)
- **Breaking:** Equality reads them too, so `1000B == 1KB` and
  `01.2.3 == 1.2.3` are true. The three relations agree: a value written
  two ways is equal, and neither below nor above (`1b10b92`)

[0.26.0]: https://github.com/mjstahl/wand/releases/tag/v0.26.0

## [0.25.0] - 2026-08-21

### Added

- Add `Clock`, an eighth effect label, and `Clock.sleep 30s`, which waits at
  least that long. wand could not wait: `Duration` had literals and
  arithmetic, and nothing consumed one as a wait, so a retry with backoff
  could not be written and a hung command hung forever. One label, not
  `Clock.Read` and `Clock.Wait` — `FS` splits because a handler can grant one
  half and not the other, and a clock cannot. The sleep waits in slices and
  checks for an interrupt between them, so Ctrl-C takes effect at once and
  the brackets a script holds release. `Test.with_clock` answers the effect
  with a clock that costs no time, so a test of an hour of backoff runs in
  microseconds, and `--dry-run` reports `would wait: 45s` without waiting.
  No manifest in the tree changes: nothing performed `Clock` before this
  (`f58c626`)
- Add `Shell.timeout`, a deadline on a command. Most script hangs are a
  subprocess, and this is the deadline that kills for real. Expiry is a
  sequence — SIGTERM, a fixed five-second grace, SIGKILL — so a command that
  tidies up on TERM gets to, and one that ignores it does not keep running.
  Only a deadline produces an `Error`, and the message names the command and
  the duration. Every other failure passes through: a command that exits
  non-zero has failed, not run late. The deadline is per command, and it is
  counted in slices of the select the pipes are already read with, so no
  clock is read and a machine that steps its clock cannot shorten or extend
  the wait (`78f6909`)
- Add `Par.race`: the first thunk to finish wins. No worker limit, because
  the count is the length of the list and the list is at the call site. First
  to finish, not first to succeed — a loser that raises is discarded, and a
  winner that raises comes back as `Error`. Cancellation is cooperative and
  reuses the Ctrl-C machinery, so a loser doing wand work stops at its next
  step and every worker is joined before `race` returns. A loser waiting on a
  command waits for the command; `Shell.timeout` in the thunk is that bound
  (`ef7e2fa`)
- Add `Par.timeout`, a deadline on wand code, written in wand over `race` and
  `Clock.sleep`: the work and a sleeper race, and whichever finishes first
  answers. That makes it a wait of a length rather than a wait until an
  instant, which is what keeps it right on a machine whose clock steps. The
  work is asked to stop when the deadline passes and stops at its next step,
  giving back what it holds (`59e622a`)
- Order the temporal types. `<`, `>`, `<=` and `>=` now take an `Ord`, a type
  wand orders, and seven are ordered: Int, Float, String, Duration, Date,
  Time and DateTime. A comparison is on the value, not on the text, so
  `90s > 1min` is true; a `DateTime` normalizes to an instant, and a value
  with no offset is read as UTC, because reading it as local time would make
  one script answer differently on two machines. `Ord` composes as `Num`
  does, so `let later a b = if a < b then b else a` stays polymorphic
  (`0be8d0e`)

### Changed

- **Breaking:** Comparing a type wand does not order is a type error where it
  is written, not a runtime error during the run. `100MB < 1GB` typechecked
  before and failed mid-run; two functions could be compared at all. Size,
  Version, Port and IPv4 are not ordered yet —
  `docs/design/ordering-domain-types.md` decides what each one needs
  (`0be8d0e`)
- **Breaking:** Equality normalizes with ordering. `60s == 1min` was false
  while `60s < 1min` and `60s > 1min` were both false as well — three answers
  no reader can hold at once. It is now true. This breaks anyone who relied
  on `60s != 1min`, which is not a fact to rely on. `List.sort` follows the
  same rule where wand defines an order, and keeps structural comparison
  everywhere else (`0be8d0e`)
- Equality walks into a value. `60s == 1min` was true and `[60s] == [1min]`
  was false; the walk now goes through tuples, lists, constructors and maps
  (`f58c626`)
- `wand f` brackets a `handle` body that wraps. It produced source it could
  not read back: `with` has to follow the body, and a body that opened a
  bracket on one line and closed it on a later one left text for the newline
  to cut off (`f58c626`)

### Note

Reading the clock is not here, a virtual clock does not shorten a real
deadline, and a killed command may leave children.

[0.25.0]: https://github.com/mjstahl/wand/releases/tag/v0.25.0

## [0.24.0] - 2026-08-21

### Added

- Add a type on a parameter: `let describe (p: Pod) = p.name`, and
  `fn (p: Pod) -> ...` with it. This is what lets a function read a field
  off a parameter. Dot access needs a named type, and wand generalizes a
  definition before it sees any call, so the type has to come from the
  definition. The annotation works in each place a pattern does: a `let`,
  a `fn`, an arm of a `match`, and a `with ... as`. It composes with the
  return annotation: `let describe (p: Pod) : String = p.name`. The
  parentheses are part of the syntax, because a `:` between expressions is
  cons (`bec0356`)

### Note

`(x : xs)` still reports the cons message. Cons in a pattern is `[h : t]`,
in brackets, so the parenthesised form was never a pattern. One token tells
the two apart: a type starts with `Upper`, `'a` or `(`.

A type variable in a parameter is a type error. Each annotation resolves its
own names, so `'a` in two parameters would be two variables. Write the type
of the whole definition instead: `let f : 'a -> 'a = ...`.

[0.24.0]: https://github.com/mjstahl/wand/releases/tag/v0.24.0

## [0.23.0] - 2026-08-21

### Changed

- **Breaking (text):** A type error names what it expected and what it got.
  It said `cannot unify Glob with Path`, and it now says
  `expected Glob, got Path`. "Unify" is a word from the type checker, not
  from a script. `unify` has no fixed argument order, so 37 call sites now
  state which side the reader wrote: an annotation, an application, an `if`,
  an arm of a `match`, a pattern, an element of a list or a map, a `$()`
  payload, a `|>` stage, a contract clause, a `with` resource, an operand.
  A site that cannot know says `Glob and Path are not the same type`
  (`f8437a2`)
- **Breaking (text):** An effect error names the difference. It said
  `cannot unify effects {Shell} with {Raise, Shell | ..}`, and it now says
  `the type allows {Shell}, but the body performs Raise`. At an argument it
  says `the parameter allows {}, but the function given performs Raise,
  Shell` (`f8437a2`)
- **Breaking (text):** Three more messages drop the word: a non-number in
  arithmetic reads `expected a number, got Bool`, the two members of `Num`
  read `Int and Float do not mix`, and the occurs check reads
  `this value would have to contain itself` (`f8437a2`)
- `README.md` and `docs/reference.md` are written in Simplified Technical
  English: short sentences, active voice, one idea in each. The reference
  went from 692 sentences with a median of 14 words to 1158 with a median of
  9. Sentences over 20 words: 218 before, 42 now. No code block, heading or
  link changed (`782d8d5`, `c99c382`..`18e0614`)

### Fixed

- Fix `docs/reference.md` stating that a newline always ends a statement. A
  line that starts with an operator continues the line above, which is what
  a pipeline that leads with `|>` needs. So `let a = 1` and then `-2` gives
  `-1`. The parser is right; the reference was wrong (`eb28ae5`)
- Fix three claims in `README.md`: the by-hand install named v0.10.0, the
  example error text did not match a run, and startup said 1.6 times
  `bash -c :` where three runs give about 2 times (`782d8d5`)

[0.23.0]: https://github.com/mjstahl/wand/releases/tag/v0.23.0

## [0.22.0] - 2026-08-21

### Changed

- **Breaking:** `FS.glob` and `FS.glob_in` do not walk through a symlink.
  A link out of the tree added files that the directory does not hold. A
  link to a parent made the walk repeat until the path was too long. A
  symlink that matches is still an answer. wand still follows the base
  directory (`74283b9`)
- **Breaking:** `FS.write_file` creates a file with mode 0644. It used the
  channel default of 0666. `FS.create_file` and `FS.append` already used
  0644. Under `umask 0` the file was writable by all users (`74283b9`)
- **Breaking:** `FS.copy` gives a new file the mode of the source file. A
  copied script keeps its executable bit. A copy of a 0600 file stays
  private. A destination that exists keeps its own mode (`74283b9`)
- **Breaking:** wand checks the type variables in an annotation.
  `let f : 'a -> 'a = fn x -> x + 1` is now a type error: the body accepts
  only `Int`. `let g : 'a -> 'b = fn x -> x` is an error too: the body
  makes the two types the same. An annotation with no type variable does
  not change (`db0ce43`)
- `--dry-run` answers with a new random path for each temp file and temp
  directory. It answered with `/tmp/wand-dry-run-dir` each time, and all
  users can write that directory (`74283b9`)

### Fixed

- Fix `String.join`: it dropped a first element that is empty.
  `String.join "," ["", "b"]` gave `b` and now gives `,b` (`db0ce43`)
- Fix `String.words`: it split on one space, so extra spaces became empty
  words and a tab split nothing. `String.words "  a  b  "` gave 7 elements
  and now gives 2. Any run of whitespace splits (`db0ce43`)
- Fix `Path.with_extension`: an extension without a dot removed the
  extension. `Path.with_extension "md" /a/b.txt` gave `/a/bmd` and now
  gives `/a/b.md`. `""` removes the extension (`db0ce43`)

[0.22.0]: https://github.com/mjstahl/wand/releases/tag/v0.22.0

## [0.21.0] - 2026-08-21

A security and honesty release. Every item below is a case where wand said
one thing and did another — a manifest that did not bound what ran, a type
that did not report a raise, an exit code that did not match the finding.

### Changed

- **Breaking:** A handler now discharges an effect only when it covers
  every operation carrying that effect. Effects are many-to-one over
  operations — Shell carries four, FS.Write ten — and a handler used to
  discharge the whole effect for each case it had, so the operations it
  did not name went on reaching the default handler and running for real
  with the signature saying they could not. A partial handler now keeps
  the effect, and a case naming an operation that does not exist is an
  error with the nearest real name suggested (`8f67f02`)
- **Breaking:** A function kept in a constructor field keeps its effects.
  A field's effects are inferred from the value it is built with, and
  three places threw that away, so `type Action = Action (Unit -> String)`
  holding `fn () -> $(touch x)` typechecked under `uses {}` and ran the
  command when the match took it back out (`7c02e94`)
- **Breaking:** `Env.load!` declares `FS.Read`. The primitive performs a
  real `FS!read_file`, but the effects it declared were written by hand as
  `{Env, Raise}`, so a file whose whole manifest was `uses {Env}` could
  read any path on disk (`60b09f7`)
- **Breaking:** A `Shell(...)` manifest bounds what runs inside a subshell
  `(...)`, a substitution `$(...)` and a backtick span, wherever they
  appear, including inside double quotes. Each was read as opaque text on
  the reasoning that a subshell belongs to the named binary's shell — it
  does not, the same shell runs it — so `Shell(echo)` admitted
  `$(echo $(whoami))`. `$((...))` stays arithmetic and is not checked
  (`8cb3cf2`)
- **Breaking:** A pattern that can fail makes its binding raise, whether
  the fields are named or positional. The rule is that a constructor
  pattern cannot mismatch when the value has no other constructor to be;
  it was applied to named patterns by spelling instead of by type, so
  `let area (Circle (radius = r)) = r` over `Circle | Square` claimed to
  be total. `let` bindings record it too: `let Ok v = r in ...` performs
  Raise. The same rule drops a false positive the other way — a
  positional pattern over a single-constructor type no longer carries a
  risk its type cannot hold, so a name like `unbox!` now trips V-BANG2
  (`083b2cb`)
- **Breaking:** `wand s` refuses a test file whose assertions are
  discarded. A test block answers with one outcome, so sequencing
  assertions with `;` threw away every one but the last and the file
  reported a pass however the run went. V-DROP2 reports it (`59d1d1c`)
- **Breaking:** `wand t --strict --json` exits 1 on a violation. The JSON
  called the finding an error and the command then reported success, so a
  CI step reading the exit code was told the file was clean by the run
  that had just failed it (`ab349c0`)
- A command given input on `|>` keeps its own stderr, as `$()` has always
  done. It went down a pipe and was discarded, so
  `report |> $(mail ops@example.com)` swallowed the one thing that would
  have said why it failed (`be21c28`)
- A closed reader downstream — `wand report.wand | head -3` — ends the run
  at 141 after unwinding, rather than killing wand where it stands. SIGPIPE
  is ignored, so `with` brackets release before the run ends (`be21c28`)

### Added

- Add written effects to type annotations: `! {Shell}`, `! {Shell | 'e}`
  and `! 'e` all parse, on the innermost arrow of a curried type as an
  inferred one carries them. They are checked rather than assumed, so an
  annotation cannot quietly narrow what a function does. This is what lets
  a declaration state that a field's effects are the caller's —
  `raises: ((Unit -> 'b ! 'e) -> TestOutcome ! 'e)` — which is what makes
  `t.raises (fn () -> $(cmd))` a type error in a file whose manifest is
  `uses {}` (`22380fb`)
- Add `--` as the end of wand's own arguments when running a script.
  `--dry-run` and `--trace` are wand's wherever they appear before it, so
  a script that takes a flag of the same name could not be given one: the
  run silently became a rehearsal and the script never saw the argument.
  `wand deploy.wand -- --dry-run` now runs for real and hands the flag on
  (`ab349c0`)

### Fixed

- Fix `$?()` and `|>` hanging forever on a command that writes more than a
  pipe buffer to stderr, or is fed more than one on stdin. The two pipes
  were drained one after the other, so the child blocked writing the pipe
  wand was not reading and never reached the end of the one wand was
  waiting on. All three streams now move together (`be21c28`)
- Fix `%{x}` written between quotes of your own not being quoted at all.
  Wrapping the value in single quotes quotes nothing inside `"..."`, so
  `$(echo "hi %{name}")` put the value into text the shell still read and
  a name holding `$(whoami)` ran it. The value is escaped for the quote it
  lands in now, and the author's word stays one word (`8cb3cf2`)
- Fix `$()` ending at a quoted `)`. `$(echo "a)b")` was cut in half and
  the rest of the line read as wand source (`8cb3cf2`)
- Fix `wand f` emitting source it cannot read back: three of the five
  string openers the lexer reacts to — `%!{`, `$!{` and `#{` — came back
  unescaped (`083b2cb`)

### Note

Effect sets are called effect sets throughout the compiler; "row" named
the encoding rather than the idea and is gone from comments and internal
names (`7a2523b`, `5695853`). No user-visible text changed.

[0.21.0]: https://github.com/mjstahl/wand/releases/tag/v0.21.0

## [0.20.1] - 2026-08-20

### Fixed

- Fix `wand f` emitting source that does not parse, at seven more sites:
  the `in` tail of a `let` and its value, a lambda's body, an operand of
  a binary operator, a branch of an `if`, a `match` scrutinee, a `with`
  resource, and a pipeline stage. Each is a place an expression that
  wrapped was written without the brackets that keep it whole. Two of
  them did something worse than fail: they changed what the code meant.
  A value could be reformatted into a different program, and a splice
  that wrapped inside `%{...}` dropped its argument, a newline there
  ending the string. Splices now render against a margin nothing reaches
  and come back on one line however long they are (`3db3700`)
- Fix a handler that declines to resume an operation performed inside a
  `with`'s release reaching the top level as
  `Fun.Finally_raised: Abandoned` instead of unwinding (`3db3700`)

### Added

- Add a margin sweep to the formatter's tests: all 69 corpus files are
  formatted at 20, 30, 40, 60 and 92 columns, and the result has to
  parse, and formatting it a second time has to change nothing. Every
  one of the parse bugs above needed a line long enough to wrap before
  it showed; a narrow margin makes every line long enough. It found all
  seven (`3db3700`)

### Note

The new guards are conservative — they bracket wherever a wrapped
application could be misread, and inside a bracket it could not — so ten
corpus files gain parentheses they do not strictly need.

[0.20.1]: https://github.com/mjstahl/wand/releases/tag/v0.20.1

## [0.20.0] - 2026-08-19

### Changed

- **Breaking:** `JSON.read_file`, `CSV.read_file` and `TOML.read_file`
  reached the disk through builtins of their own, declaring no effects
  at all — so a script read a file with nothing in its manifest saying
  so, a handler mocking the filesystem did not stand in for them, and
  `--dry-run` could not see them. All six now read through the same
  `FS!read_file` every other reader performs and parse the string with
  the parser each module already had, gaining `! {FS.Read}` and, for
  the `!` siblings, `! {FS.Read, Raise}`. A script that reads a config
  through any of them must now say `FS.Read`; `wand t --fix` writes the
  line. Error text for a missing file is now `FS.read_file`'s rather
  than each parser's (`507c134`)
- Change `wand f` to close a bracket that ran onto more lines on a line
  of its own, at the indent that opened it, rather than wherever the
  last line happened to end (`2cde06b`)
- Change `wand f` to stand a manifest and the leading block of plain
  imports off from what follows them, whether or not the source did,
  and to collapse several blank lines to one (`6fcae4c`)

### Added

- Add completion for effect operations: typing `FS!` in an editor lists
  all twenty, each with what a case binds and resumes with and the
  sentence a handler author wants — "handles the `FS.Write` effect of
  `FS.write_file` and `FS.write_file!`". Nothing was offered before, so
  what appeared came from the editor's own guess at words in the buffer
  (`6bb3f40`)
- Add an operations table as one definition of what a handler can catch.
  `effect_of_operation` and `operation_types` read from it, and it can
  be enumerated, which is what the editor needed. `test_operations.wand`
  proves every claim in it by running each performer under a handler for
  its operation (`6bb3f40`)

### Fixed

- Fix `wand f` emitting source that does not parse, at three sites: a
  wrapped application in a match case body, in a single-clause
  `let f x = ...`, and in a `let ... and ...` group. Each ends at its
  first line, so the argument below it read as something new. Bindings
  written as multiple equations have been guarded since the beginning;
  these paths never were (`a132dda`, `2cde06b`)
- Fix the format gate to cover `test/wand/` and `examples/` as well as
  `stdlib/` — 69 files against 22. Nothing was checking the other two,
  so seven fixtures had drifted. `tools/check_stdlib_fmt.wand` is
  `tools/check_fmt.wand` now (`a132dda`)
- Fix `wand f` measuring a list's and a tuple's items from the wrong
  column, so an item that broke internally wrapped to the left of the
  item itself (`2cde06b`)
- Fix the reference's table of interceptable operations, which had
  fallen four behind the binary. A drift test holds it there (`6bb3f40`)

### Note

`Shell!run_quiet` and `Shell!exit_code` have builtins behind them and
are answered by `--dry-run`, but nothing a script can write reaches
them. A handler case for either is legal and will never fire.

[0.20.0]: https://github.com/mjstahl/wand/releases/tag/v0.20.0

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
  so a long signature — a wide effect set especially — no longer wraps
  mid-type (`65319f5`)
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
- Add `wand lsp`: the language server, a subcommand on the compiler binary so the editor can never disagree with `wand t`. Diagnostics as you type, hover showing the signature with its effects plus the doc string, completion (a member of an unimported stdlib module carries its `import` on accept), quick fixes from every finding that knows its correction, whole-document formatting, and go to definition — including into the standard library, opened from the binary as read-only documents (`162ebcd`, `ac3be7f`, `f527cc9`)
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

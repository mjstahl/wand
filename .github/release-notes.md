## 0.21.0 - 2026-08-21

A security and honesty release. wand's claim is a narrow one — a script
cannot do what its first line did not declare — and a source review of the
compiler found thirty issues, several of them places where that claim did
not hold. This release closes every critical and every high finding: the
ways a script could reach past its manifest or its type, a deadlock that
could hang a production script, and the ways a command answered something
other than what happened.

If you have wand in CI, this release will fail files that used to pass.
That is the point of it: each one was passing on a check that was not
being made.

### The manifest bounds more than it did

A `Shell(git)` manifest is meant to name every binary a file can run. It
did not see inside a subshell, a `$(...)` or a backtick span, on the
reasoning that those belong to the named binary's own shell. They do not —
the same shell runs them — so this was admitted under `Shell(echo)`:

    $(echo $(whoami))

Each is now a command position of its own, wherever it appears. Arithmetic
`$((...))` is left alone: the shell runs nothing there.

A handler had the same shape of hole. Effects are many-to-one over
operations — Shell carries four, FS.Write ten — and a handler discharged
the whole effect for each case it had, so what it did not name went on
running for real:

    uses {IO}
    let out = handle (fn () -> $(touch /tmp/pwned)) () with
      | Shell!exit_code _ _ -> "intercepted"

`wand t --strict` exited 0 on that, and the file was created. A handler now
discharges an effect only by covering every operation of it.

Two more of the same kind: a function kept in a constructor field lost the
effects it was built with, so a field holding `fn () -> $(touch x)`
typechecked under `uses {}`; and `Env.load!` declared `{Env, Raise}` by
hand while performing a real file read, so `uses {Env}` could read any path
on disk.

### An interpolated value is quoted everywhere now

`%{x}` promises the value becomes exactly one argument and cannot change
what runs. Between quotes you wrote yourself, it did not: wrapping a value
in single quotes quotes nothing inside `"..."`, where a single quote is an
ordinary character.

    let name = "$(whoami)"
    $(echo "hi %{name}")     -- ran whoami

The value is now escaped for the quote it lands in, so it stays part of the
word you were building and nothing in it is read as syntax. Related: `$()`
used to end at the first `)`, even a quoted one, so `$(echo "a)b")` was cut
in half and the rest of the line read as wand source.

### A pattern that can fail says so

A constructor pattern cannot mismatch when the value has no other
constructor to be. That rule was applied to named fields by spelling rather
than by type, so this claimed to be total:

    type Shape = Circle (radius : Int) | Square (side : Int)
    let area (Circle (radius = r)) = r     -- Shape -> Int, no Raise

It is `Shape -> Int ! {Raise}` now, and wants an `!` in its name. `let`
bindings record it too — `let Ok v = r in ...` raises where it stands, the
one place in the language where a raise was invisible to the type. The same
rule cuts the other way: a positional pattern over a single-constructor
type is total, so a `let unwrap! (Wrap n) = n` is now told its `!` promises
a risk the type cannot hold.

### Commands, streams and the CLI

`$?()` hung forever on a command that wrote more than a pipe buffer to
stderr — the two pipes were drained one after the other, so the child
blocked on the one wand was not reading and never reached the end of the
one wand was waiting on. Feeding a command a large stdin hung the same way.
All three streams move together now.

Alongside that: a command given input on `|>` keeps its own stderr, as
`$()` always has, so `report |> $(mail ops@example.com)` no longer swallows
the reason it failed. And a closed reader downstream — `wand report.wand |
head -3` — ends the run at 141 after unwinding, rather than killing wand
between two instructions and leaving a temp directory or a lock behind.

`wand t --strict --json` exited 0 on a violation while the JSON called that
same finding an error. It exits 1.

`--` now ends wand's own arguments: `wand deploy.wand -- --dry-run` runs
for real and hands the flag to the script. Before, a script's own
`--dry-run` was read as wand's, so the run quietly became a rehearsal that
changed nothing and the script never saw the argument.

### Also

Type annotations can carry effects — `! {Shell}`, `! {Shell | 'e}`, `! 'e`
— checked rather than assumed, so an annotation cannot narrow what a
function does. This is what lets a declaration say that a field's effects
are its caller's, which is how `t.raises (fn () -> $(cmd))` became a type
error in a file whose manifest is `uses {}`.

`wand s` refuses a test file whose assertions are discarded: sequencing
them with `;` threw away every one but the last, and the file reported a
pass however the run went.

`wand f` emitted source it could not read back — three of the five string
openers came back unescaped.

---

One line installs it — platform detection, checksum verification, and a
smoke test included:

    curl -fsSL https://raw.githubusercontent.com/mjstahl/wand/main/install.sh | sh

Or download the archive for your platform, unpack it, and put `wand` on
your `PATH`. The binary carries its own standard library, so it runs from
any directory with nothing else installed.

| | |
|---|---|
| `linux-x86_64`, `linux-aarch64` | static musl builds; no libc on the machine is needed |
| `macos-aarch64`, `macos-x86_64` | not notarised, so a download is quarantined until you clear it |

On macOS:

    xattr -d com.apple.quarantine wand

Checksums are the `.sha256` files beside each archive. Verify one next to
the download with `shasum -c wand-<version>-<platform>.tar.gz.sha256`.

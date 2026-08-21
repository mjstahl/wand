# Known gaps

What wand cannot do today, and where each gap is decided. This list is
standing: an entry leaves it when the thing ships, not when someone plans
it.

Each entry says what is missing and what it blocks. Where a design doc
already treats a gap in full, the entry is one line and the doc holds the
argument. Nothing is duplicated between here and there.

## Waiting and the clock

**Reading the clock.** `Clock.sleep` waits, and nothing reads the current
instant. `Clock.now` would be nearly inert, because `DateTime` has no
arithmetic, and adding that arithmetic arms a trap: `now - mtime` is sound
and `now - an_earlier_now` is not, and they are the same operator. The two
land together, later.

Without it there is no timestamped name, no "older than thirty days", and no
"the last successful run was more than an hour ago". `FS.mtime` answers a
`DateTime` that can be compared against a literal written in the source, and
that is the whole of what can be done with an instant.

**A deadline cannot be tested against a virtual clock.** `Test.with_clock`
answers `Clock.sleep` at no cost, so a test of an hour of backoff runs in
microseconds. Two waits it does not shorten. `Shell.timeout` belongs to the
operating system, which does not take a handler. `Par.timeout` answers `Ok`
under a virtual clock, because a watched race is left-biased and the work
wins; firing a virtual deadline would need a clock handler that knows the
deadline. Test a deadline against real time.

**A killed command may leave children.** wand signals what it started. So
`Shell.timeout 1s (fn () -> $(sh -c "sleep 30"))` kills the `sh` and leaves
the `sleep`, and wand stops waiting on it rather than waiting for a process
it did not start. A wrapper script that spawns and exits leaves its work
running.

## Ordering

**Four domain types do not compare.** Size, Version, Port and IPv4 are a
type error under `<`, `>`, `<=` and `>=`. Each has one obvious total order,
so a script compares a size against a threshold, or a version against a
floor, by hand. Decided in
[`docs/design/ordering-domain-types.md`](design/ordering-domain-types.md):
one member and one normalizer each.

## The language

**A binding does not live past a `;`.** Inside parentheses `let ... in`
scopes over one expression, so a body that names two intermediates nests
twice. Designed in
[`docs/design/binding-in-a-sequence.md`](design/binding-in-a-sequence.md).

**A record pattern has no pun form.** `Repo(name = n, url = u)` matches by
name and is the form to use. There is no `Repo(name, url)` binding each
field to its own name, the way `{a, b}` already puns for maps. Noted in
[`docs/design/shell-corpus.md`](design/shell-corpus.md).

## The standard library

Found by porting shell scripts, and argued in
[`docs/design/shell-corpus.md`](design/shell-corpus.md) under the labels
below.

- **G3 — `FS` stops at a single file.** No recursive delete and no recursive
  copy, so `rm -rf build/` and `cp -r` shell out. `fs_delete_tree` is
  already written and used internally; exposing it needs a name and a
  decision about how deliberate that name should be.
- **G4 — no permissions, no symlinks, no ownership.** No `chmod`, `chown`,
  `symlink` or `readlink`, and no mode on a stat. An ssh key needs `0600`
  and a script needs `+x`, so provisioning is a row of `$()` calls.
- **G5 — no process surface beyond exiting.** `Proc` has `exit`. No pid, no
  "is it running", no signal, no listing. Managing a daemon goes through
  `$(ps)` and `$(kill)` and parses text.
- **G6 — no HTTP client.** Row 3 of the corpus goes through `$(curl ...)`.
  A decision, not necessarily work: "wand shells out to curl on purpose" is
  a fine answer if it is written down.
- **G7 — no archive story.** No `tar`, `zip` or `unzip`. Shelling out is
  fine; recorded so a port does not stall while someone wonders.
- **`ShellResult` has no `ok?`.** Checking whether a command worked is
  `r.code == 0`, and it is the first thing every ported script does.

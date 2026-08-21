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

That work brings back the monotonic-clock question, which nothing today
asks: every deadline wand has is a wait of a length, and a length needs no
clock. Measuring elapsed time is the one use a civil clock cannot serve,
and the choice is not free. On Linux `CLOCK_MONOTONIC` excludes time spent
suspended and `CLOCK_BOOTTIME` includes it; on macOS the names are
inverted. Whatever ships pins the semantics per platform and says which.

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

**A type you define does not compare.** Two `Circle`s are a type error
under `<`. Every ordered type is one wand knows about, and a deriving
mechanism is its own design. Nothing has asked for one yet.

Ordering the types wand knows is done: eleven of them compare, and
`List.sort` reads a value the same way rather than sorting its text.

## Decided against, for now

These are not missing so much as declined, each with a reason that would
have to change before anyone builds them.

- **A first-to-succeed race.** `Par.race` answers with the first thunk to
  *finish*, and a winner that raised comes back as `Error`. A `race_ok`
  that skipped past failures is a defensible second function, and one
  construct per problem holds until a script needs the other.
- **Scheduling.** No `Clock.deadline`, no repeat, no cron. A poll loop is
  `Clock.sleep` in a recursive function, and the machine already has a
  scheduler.
- **Syntax for timeouts.** `$(curl x) timeout 30s` would read well and is a
  far larger commitment than a label. `Shell.timeout` and `Par.timeout`
  have to earn it first.

## The language

**An effect in a module's top-level binding dies unhandled.** An import
evaluates a file's bindings, and it does so with no handler in scope, so
`let greeting = $(hostname)` at the top of an imported module ends the
program with `Unhandled(WandEffect ...)` rather than a wand error naming
the file. Work belongs in a function that the script's last line calls;
that runs when the file is the script and not when it is imported.

**A bare `None` still has to be bracketed.** Parentheses after a
constructor are its payload, whatever its arity, so `t.eq None (usage row)`
reads as `t.eq (None (usage row))` and `(None)` is the way to write it.
The checker now names the constructor and says to bracket it, where the
error used to be about the application. The parse stands: reading arity
here is what made `Ctor (a, b)` mean different things in different files.

**A pattern cannot carry a type inside a constructor's payload.** `(v: T)`
works as a parameter, as a lambda parameter, as a `let` pattern, in a bare
match arm and inside a tuple. `Ok (v: T)` is a parse error: the payload
branch reads `(` as the start of an argument list and never looks for a
`:`. One branch wide. Found porting `pod-restarts.wand`.

**A destructured import is replaced by a later one, above the line as well
as below it.** Every import binds before the file's own bindings, wherever
it is written, so the last import of a name decides every use of it:

```ocaml
let {f} = import ./a
let () = println (f 1)     -- ./b's f, not ./a's
let {f} = import ./b
```

`V-IMP1` warns when the first import is never used. It stays quiet here,
because `f` is used. Two files exporting one name at one type then differ
in nothing an error can catch. Found porting `pod-restarts.wand`, which
collided with earlier ports three times; a type error caught each, and
would not have if the types had matched.

**A record pattern has no pun form.** `Repo(name = n, url = u)` matches by
name and is the form to use. There is no `Repo(name, url)` binding each
field to its own name, the way `{a, b}` already puns for maps. Noted in
[`docs/design/shell-corpus.md`](design/shell-corpus.md).

## The standard library

Found by porting shell scripts, and argued in
[`docs/design/shell-corpus.md`](design/shell-corpus.md) under the labels
below.

- **G4 — no permissions, no symlinks, no ownership.** No `chmod`, `chown`,
  `symlink` or `readlink`, and no mode on a stat. An ssh key needs `0600`
  and a script needs `+x`, so provisioning is a row of `$()` calls.
- **G5 — no process surface beyond exiting.** `Proc` has `exit`. No pid, no
  "is it running", no signal, no listing. Managing a daemon goes through
  `$(ps)` and `$(kill)` and parses text.
- **G6 — no HTTP client, on purpose.** Row 3 of the corpus goes through
  `$(curl ...)`, and stays there. `curl` is on every machine a script runs
  on, it is named in the manifest as `Shell(curl)` like any other binary,
  and `Shell.decode` reads its output. A client inside wand would carry
  TLS, redirects, proxies and retries, and would still be behind curl.
- **G7 — no archive story.** No `tar`, `zip` or `unzip`. Shelling out is
  fine; recorded so a port does not stall while someone wonders.

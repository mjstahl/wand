# Known gaps

What wand cannot do today, and where each gap is decided. This list is
standing: an entry leaves it when the thing ships, not when someone plans
it.

Each entry says what is missing and what it blocks. Where a design doc
already treats a gap in full, the entry is one line and the doc holds the
argument. Nothing is duplicated between here and there.

## Waiting and the clock

**A deadline cannot be tested against a virtual clock.** `Test.with_clock`
answers `Clock.sleep` at no cost, so a test of an hour of backoff runs in
microseconds. Two waits it does not shorten. `Shell.timeout` belongs to the
operating system, which does not take a handler. `Par.timeout` is a race,
and a race inside a handler is refused, so the deadline is a real wait.
Put the handler inside the thunk — `Par.timeout 200ms (fn () ->
Test.with_shell mocks (fn () -> work ()))` — and the mock stands while the
deadline fires. A deadline too long to wait for stays untestable; firing a
virtual one would mean scheduling raced thunks as fibers in one domain.

**A killed command may leave children.** wand signals what it started. So
`Shell.timeout 1s (fn () -> $(sh -c "sleep 30"))` kills the `sh` and leaves
the `sleep`, and wand stops waiting on it rather than waiting for a process
it did not start. A wrapper script that spawns and exits leaves its work
running.

## Decided against, for now

These are not missing so much as declined, each with a reason that would
have to change before anyone builds them.

- **A first-to-succeed race.** `Par.race` answers with the first thunk to
  *finish*, and a winner that raised comes back as `Error`. A `race_ok`
  that skipped past failures is a defensible second function, and one
  construct per problem holds until a script needs the other.
- **Ordering a type you define.** Two `Circle`s are a type error under `<`,
  and there is no deriving mechanism. `List.sort` is what covers it, and
  deliberately: it takes a list of any type, so it sorts what the operator
  refuses. A type wand orders sorts on its value; everything else sorts on
  its shape, a variant by its declaration. Widening `Ord` to match would be
  a decision rather than a change — it would have to say what `Circle <
  Rect` means, and the shape's answer is arbitrary where the operator's is
  not.
- **Scheduling.** No `Clock.deadline`, no repeat, no cron. A poll loop is
  `Clock.sleep` in a recursive function, and the machine already has a
  scheduler.
- **Syntax for timeouts.** `$(curl x) timeout 30s` would read well and is a
  far larger commitment than a label. `Shell.timeout` and `Par.timeout`
  have to earn it first.
- **Renaming one constructor of several.** `let {Status = S} = import ./foo`
  renames the type, and renames its constructor where it has one. There is
  no way to rename `Live` alone, out of `Live | Gone`: the other would keep
  the old name, and the type would answer to two spellings in one file.
  Rename the type, or reach the constructor through the module.

## The language

**A destructured import is replaced by a later one, above the line as well
as below it — warned, not fixed.** Every import binds before the file's own bindings, wherever
it is written, so the last import of a name decides every use of it:

```ocaml
let {f} = import ./a
let () = IO.println (f 1)  -- ./b's f, not ./a's
let {f} = import ./b
```

`V-IMP1` warns on this, wherever the second import sits. Found porting
`pod-restarts.wand`, which collided with earlier ports three times; a type
error caught each, and would not have if the types had matched, so the
rule was widened to cover every import in the file rather than the leading
run.

**A usage line has no program name in it.** `T.usage` covers the flags and
the arguments. A type therefore describes its whole command line, and
nothing is written twice. The name at the front is still a literal.
`Env.args ()` gives the arguments only. There is no `argv[0]` to read. So
`probe-args.wand` writes `"usage: probe-args %{Opts.usage}"`. bash has `$0`
and C has `argv[0]`. Whether wand should have one is undecided.

**A usage line has no room for what a flag means.** It names each flag. It
brackets the ones that may be left out. It shows what each default holds.
There is nowhere to state what `--timeout` is for. The parser already
collects doc comments, so a comment above a field is the obvious source. The
shape of the output is not obvious. A line of flags becomes a block once each
one carries a description.

**The bound on nested calls is a count, not the stack.** A call with work
waiting on it keeps a frame, so nesting without end runs out of stack, and
OCaml's `Stack overflow` cannot be caught here: a handler that matches it --
even one whose guard rejects it -- hangs rather than unwinds, because the
guard runs on the stack that just ran out. So the depth is bounded before
the stack goes. The bound is a fixed count and the stack it stands in for is
not: the default holds millions of frames, and a run under
`OCAMLRUNPARAM=l=...` or a small `ulimit -s` holds far fewer, where the
bound never fires and the fatal comes back. `WAND_MAX_CALL_DEPTH` lowers it
to suit. Reading the stack's real headroom is what would close this, and it
is platform work.

## The standard library

Found by porting shell scripts, in `examples/ports/`. Each is a decision
rather than an omission: the corpus reached all twelve of the jobs it set
out to cover without them.

**No permissions, no symlinks, no ownership, on purpose.** No `chmod`,
`chown`, `symlink` or `readlink`, and no mode on a stat. They are POSIX
one-liners on every machine, so `provision-host.wand` calls them through
`$()` with the manifest recording `Shell(chmod, ln)`. The cost is that
`chmod` and `ln -sfn` exit 0 whether or not they changed anything, so a
step cannot report that it had nothing to do; reading a mode back is the
one part a shell cannot do portably (`stat -c '%a'` is GNU, `stat -f
'%Lp'` is BSD), and a mode wants a domain type rather than a string of
octal digits to be worth having. Revisit when something needs it.

**No process surface beyond exiting, on purpose.** `Proc` has `exit`. No
pid, no "is it running", no signal, no listing. Managing a daemon goes
through `$(ps)` and `$(kill)` and parses text. No port ever reached for
it, and signalling a process this program did not start is a different
authority from the rest of the effect set — which is about what this
program itself does — with no word for it in a manifest.

**No HTTP client, on purpose.** A script that talks to an API goes through
`$(curl ...)`, and stays there. `curl` is on every machine a script runs
on, it is named in the manifest as `Shell(curl)` like any other binary, and
`Shell.decode` reads its output. A client inside wand would carry TLS,
redirects, proxies and retries, and would still be behind curl.
[`examples/ports/http-retry.wand`](../examples/ports/http-retry.wand) is
that decision written out.

**No archive story.** No `tar`, `zip` or `unzip`. Shelling out is fine;
recorded so a port does not stall while someone wonders.

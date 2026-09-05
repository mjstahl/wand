# `FS.write_atomic` and `FS.lock`

A deploy publishes a file that must never be seen half-written. A cron job
must not run twice at once. wand has neither primitive, and the interesting
thing about both is that they look composable from what already exists.

One of them composes into something quietly wrong. The other does not
compose at all.

This document records what the evidence settles and, for everything it does
not, states the question so it can be answered rather than discovered. It is
written before the code and is not a specification.

- [write_atomic: the pattern is anticipated and unbuildable](#write_atomic-the-pattern-is-anticipated-and-unbuildable)
- [What is settled for write_atomic](#what-is-settled-for-write_atomic)
- [Questions: write_atomic](#questions-write_atomic)
- [lock: nothing to build on](#lock-nothing-to-build-on)
- [What is settled for lock](#what-is-settled-for-lock)
- [Questions: lock](#questions-lock)
- [Questions both share](#questions-both-share)
- [Order](#order)

## `write_atomic`: the pattern is anticipated and unbuildable

`FS.temp_file` already names this use in its own documentation:

```console
$ wand d FS.temp_file
Release tolerates the file already being gone, so a body may rename it
into place -- the way an atomic write publishes its result -- without
the cleanup failing on the way out.
```

So the library expects the pattern to be hand-rolled. Hand-rolling it is
wrong in three ways, and none of them shows up on the machine where the
script is written.

**The temp file is on the wrong filesystem.**

```console
$ wand ... with FS.temp_file "t_" ".txt" as t -> IO.println t
/var/folders/kx/.../T/t_5f79ec.txt
```

`FS.rename` is `Unix.rename` with no cross-device fallback. On a mac the
temp directory and the target are usually one device, so the rename works.
On a Linux box where `/tmp` is tmpfs it fails with `EXDEV`. The script
passes in development and fails in CI.

**The published file changes mode.**

```
existing file, before write_file! : 644
existing file, after  write_file! : 644     -- truncates, so the mode survives
FS.temp_file creates              : 600
```

`FS.write_file` preserves an existing file's permissions because it
truncates in place. Renaming a temp file over the target replaces the inode,
so a 644 configuration file silently becomes 600.

**A symlink is replaced rather than followed.**

```console
$ wand ... FS.write_file! /s/link.txt "through"
link is still a symlink: yes
target contents: through
```

`write_file` writes through a symlink. `rename` replaces the link itself. A
deploy publishing to a path that is a symlink into a versioned directory
gets the opposite of what it asked for.

None of this makes the pattern a bad one. It makes it a function rather than
a paragraph in the documentation, because the three calls a person composes
are not the three calls that are correct.

## What is settled for `write_atomic`

**The temp file goes beside the target**, in the same directory, so the
rename cannot cross a filesystem. This is what makes it a primitive rather
than sugar: it cannot be built on `FS.temp_file`, which is committed to the
OS temp directory.

**An existing target's mode is preserved.** Anything else is a silent
permission change on every write, and `FS.write_file` sets the expectation
that permissions survive a rewrite.

**The temp file is removed if the write fails.** `Resource` already gives
this shape and `FS.temp_file` already tolerates a release that finds the
file gone.

## Questions: `write_atomic`

**Q1. Does it `fsync`, and what does it sync?**

A rename buys atomicity: a reader sees the old file or the new one, never a
partial one. It does not buy durability: after a power loss the new contents
may be absent even though the rename completed. Durability needs an `fsync`
of the temp file before the rename, and strictly also of the containing
directory afterwards for the rename itself to survive.

The trade is real. A deploy writing five hundred files pays five hundred
syncs, and the thing most callers actually asked for is atomicity.

*Leaning: sync the temp file, not the directory, and say so in the doc.* No
strong recommendation — this is the question most worth someone else's
opinion.

**Q2. What mode does a file get when the target does not exist?**

`FS.write_file` produces 644 under a 022 umask, because it creates with 0666
and lets the umask cut it down. `write_atomic` should match, which means
creating the temp with 0666-and-umask rather than `temp_file`'s 600.

*Recommendation: match `write_file` exactly.* A new file should not depend on
which function wrote it.

**Q3. Does mode inheritance put `FS.Read` in the signature?**

Reading the target's mode is a stat, so the honest type is:

```ocaml
FS.write_atomic : Path -> String -> Result String Unit ! {FS.Read, FS.Write}
```

Every script that atomically writes a file then declares `FS.Read` in its
manifest, which it may not otherwise need. The alternative is a `mode`
argument with a default, which avoids the stat and moves the decision to
every call site.

*Recommendation: carry `FS.Read`.* The manifest getting noisier is a smaller
cost than permissions changing silently, and the label is true.

**Q4. What is the temp file called, and who can see it?**

It lives in the target's directory for the length of the write, so a
concurrent `FS.glob *.conf` in another process can match it, and a directory
watcher will report it. A leading dot and a distinctive suffix —
`.name.conf.wand-tmp-a1b2` — keeps it out of ordinary globs.

*Recommendation: dot-prefixed, with the target's name in it* so an
abandoned temp after a hard kill says what it was.

**Q5. Does it replace a symlink, or write through it?**

`write_file` writes through. Rename replaces. Writing through means
resolving the link and renaming onto its target, which is what a deploy
publishing to `/etc/app/config -> config.v3` wants. Replacing means the
symlink becomes a regular file, silently.

Resolving the link needs `FS.Read`, which Q3 may already have bought.

*Recommendation: write through, matching `write_file`.* Two functions that
differ only in atomicity should not differ in what they target.

**Q6. Does `FS.write_file` simply become atomic?**

It would remove the choice and the footgun. It would also make every write
cost a rename, change the inode of every file wand writes, and break any
caller relying on writing through an open file.

*Recommendation: no.* Atomicity has costs and the name should say when they
are being paid.

**Q7. Is there a streaming variant?**

`FS.write_lines` and `FS.append_lines` are proposed in the `Stream` design
record. An atomic streaming write is the natural fourth, and it should
follow whatever those settle rather than inventing its own shape here.

## `lock`: nothing to build on

There is no `flock`, no `lockf` and no `O_EXCL` anywhere in `lib/` or
`stdlib/`. This is a reach into `Unix`, which is already linked, rather than
a new dependency.

## What is settled for `lock`

**An operating-system lock, not a PID file.** A lockfile holding a PID is
what a shell script reaches for, and it goes stale the moment a cron job is
killed: the next run finds the file, tries to decide whether the process is
alive, and races everyone else doing the same. A kernel lock is released
when the process dies, which is the entire property a cron guard wants.

**It is a `Resource`,** so the shape follows from what exists:

```ocaml
with FS.lock /var/run/deploy.lock as _ ->
  deploy ()
```

## Questions: `lock`

**Q8. `lockf` or `flock`?**

`Unix.lockf` is in OCaml's standard `unix` library and needs no new code.
It also carries the POSIX locking footgun: the lock is released when *any*
descriptor to that file is closed by the process, not just the one that took
it. `flock` is better behaved and needs a C stub — which `lib/ext/` already
exists for, since `clock` lives there.

*Leaning: `flock` via a stub,* because the footgun is the kind that produces
a lock that looks held and is not. But it is a real cost against a build that
is deliberately dependency-light, and worth a second opinion.

**Q9. Blocking, non-blocking, or both?**

A cron job wants to exit quietly when the previous run is still going. A
deploy might rather wait a minute. A raising, non-blocking acquire plus
`try` covers the first with no new machinery and matches every other `!`
function. A waiting variant takes a `Duration` and carries `Clock`.

*Recommendation: non-blocking first, `FS.lock_wait d` later if asked.*

**Q10. Is the lock file removed on release?**

Removing it is the classic race: another process may have opened the file
and be waiting on it when the unlink happens, after which two processes hold
locks on two different inodes with the same name. Not removing it leaves an
empty file behind forever.

*Recommendation: never remove it.* The stale empty file is harmless and the
race is not. Say so in the doc, because it looks like a leak.

**Q11. What happens under `Par`?**

A kernel lock is held by a process. Two `Par` workers are two domains in one
process, so both acquire successfully and the guard does nothing. That is
surprising in a language whose parallelism story is `Par.map`.

Either wand tracks held locks in-process and makes the second acquire fail,
or the documentation says a lock guards against other processes only.

*No recommendation.* The first is more correct and more work, and which one
is right depends on whether anyone will actually lock inside a `Par`.

**Q12. How does a caller tell "already held" from "permission denied"?**

Both are failures of the acquire. With a raising acquire and `try`, both
arrive as a `String`, and a cron job that wants to exit 0 on the first and
1 on the second cannot branch on that without matching on message text.

*No recommendation, and this is the question most likely to be regretted.*
Options: distinct sentinel text the doc commits to, a `Result` with a small
sum for the reason, or a separate `FS.locked?` predicate that is honest
about being a racy hint.

## Questions both share

**Q13. What does `--dry-run` do?**

`write_atomic` is straightforward: it reports *would write* and writes
nothing, like every other `FS.Write`.

A lock is not. Holding it back means a rehearsal can run beside a real run,
which is the situation the lock exists to prevent. Taking it means a
rehearsal changes the world by creating a file and blocking other runs.

*Leaning: take the lock.* A rehearsal that trips over the guard has told the
author something true, and the world-change is an empty file.

**Q14. How is a locking script tested?**

`Test` has a double for every effect — `with_shell`, `with_lines`, `at`,
`without_writes`. A locking script needs one, and what the mock should do is
not obvious: pretend the lock was taken, pretend it was held by someone
else, or record the attempt the way `Test.shell_calls` records commands.

*Leaning: all three, following `with_shell` and `shell_calls`.* Whichever
answers Q12 also decides what "held by someone else" looks like to a test.

## Order

`write_atomic` first. It has a wrong-in-production story behind it rather
than a convenience story, its open questions are small, and nothing depends
on the answers to the lock questions.

`lock` after Q8 and Q12 are answered, because those two decide what the
function is, not merely how it behaves.

# Roadmap

The design records beside this one propose the work. This is the order to
take it in and why, ranked on four things that can be checked rather than
felt:

- **No workaround** — can a script do this today by other means?
- **Wrong today** — does something already ship that gives a wrong answer?
- **Deadline** — does the cost rise once anyone outside this repository
  writes a script?
- **Cost** — hours, days, or unknown.

It is a record of a decision and its reasons. It is not a schedule. A record
whose work is not scheduled has no row here, and `tour-design.md` is one.

- [The deadline is spent](#the-deadline-is-spent)
- [The order](#the-order)
- [One open question](#one-open-question)
- [The table](#the-table)

## The deadline is spent

"Breaking change, so do it before a first user" was the one cost here that
rose on its own, with every script anyone wrote. Two items carried it and
both have shipped: the `Command` value in 0.62.0, which made `$()` and
`$?()` short forms rather than primitives, and `Path` joining the ordered
set, which made two spellings of one file equal.

Nothing left on this list changes the meaning of code that already exists.
Adding a `Net` effect label is additive — every manifest written today keeps
parsing. Manifest glob patterns are near-additive, since a literal `*` in a
binary name is something nobody has written. YAML only adds.

The two `FS` primitives shipped in 0.64.0 and have left the list.
`FS.write_atomic` publishes a file whole rather than filling it, and
`FS.lock` is the kernel lock a cron guard wants. Both questions that blocked
the lock were answered on the way in: `flock` through a C stub rather than
`Unix.lockf`, and a `Result` carrying `Held` or `Denied`, so a caller can
tell "another run" from "this never worked" and choose an exit code.

So the order below is ranked on value alone, and the pull that decides it is
adoption: what would stand between wand and a first outside user. There is
no outside user yet, which is why the two that remain are the biggest items
and the ones that can wait.

## The order

### 1. `HTTP`, `Net`, and manifest globs

The adoption item. A first outside user writes a deploy script, and the
first thing they cannot do is call an API without `Shell(curl)` — which is
also the one place the README's central claim is weaker than it sounds. A
manifest that should say where bytes go says which binary ran.

The design defers TLS to a curl subprocess, so this is the language work
without the cryptography work: the label, the narrowing mechanism lifted out
of `check_shell_words` and given glob patterns, the `Request` type, and the
redirect rule.

> `http-design.md`

### 2. `YAML`

The other adoption blocker. CI glue is one of the four jobs wand names for
itself, and wand cannot read a workflow file, a compose file, or a
Kubernetes manifest.

It is last because Q5 has to be answered before anything starts: a
hand-written subset and a libyaml binding are different projects with
different schedules, and everything else in that document is downstream of
which one it is. Answering it early is what would let it move.

> `yaml-design.md`

## One open question

**The YAML parser's provenance.** Item 2 cannot start without it, and it is
the largest single piece of work on the list — a hand-written subset and a
libyaml binding are different projects with different schedules. Nothing
waits on the answer while YAML is last, so this one can be left open. It is
here because it is the question that decides whether item 2 is one release
or three.

## The table

| | item | no workaround | wrong today | deadline | cost |
|---|---|---|---|---|---|
| 1 | HTTP + Net + globs | no | claim is weak | no | weeks |
| 2 | YAML | no | no | no | unknown |

The short version: both are what would stand between wand and an outside
user, and there is no outside user yet. 1 is the one place the README's
central claim is weaker than it sounds. 2 cannot be scheduled at all until
the question above it is answered.

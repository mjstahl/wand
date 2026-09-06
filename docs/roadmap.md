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

- [What the deadline actually covers](#what-the-deadline-actually-covers)
- [The order](#the-order)
- [One open question](#one-open-question)
- [The table](#the-table)

## What the deadline actually covers

"Breaking change, so do it before a first user" is a smaller category than
it looks, and getting it wrong would distort everything below.

Adding a `Net` effect label is **additive** — every manifest written today
keeps parsing. Manifest glob patterns are near-additive, since a literal `*`
in a binary name is something nobody has written.

One item left here genuinely changes the meaning of code that already
exists: **`Path` joining the ordered set**, which flips `/a/b == /a//b` to
`true`. It has the deadline, and it leads the order below. Nothing else has
one, so everything after it is ranked on value.

It used to stand beside the `Command` value, which was the larger of the
two and which shipped in 0.62.0.

The deadline leads because it is the one cost here that rises on its own,
with every script anyone writes. The pull the other way is adoption, and
adoption is not the constraint yet: there is nobody to adopt. So the
breaking work goes first, while it is cheap, and the two open-ended items
go last.

## The order

### 1. `Path` into the ordered set

Self-contained, breaking, and it can land any time before a release. The
valuable half is `==` answering about files instead of about text.

> `path-ordering-design.md`

### 2. `FS.write_atomic`

Small, and the version people compose by hand is wrong three ways — the
temp file lands on another filesystem, the published file changes mode, and
a symlink is replaced rather than written through. Latent rather than
urgent, because nobody has written the broken version yet.

> `fs-primitives-design.md`

### 3. `FS.lock`

Genuinely blocked. Q8 — `flock` against `Unix.lockf` — and Q12 — how a
caller tells "already held" from "permission denied" — decide what the
function *is*, not merely how it behaves.

> `fs-primitives-design.md`

### 4. `HTTP`, `Net`, and manifest globs

The adoption item. A first outside user writes a deploy script, and the
first thing they cannot do is call an API without `Shell(curl)` — which is
also the one place the README's central claim is weaker than it sounds. A
manifest that should say where bytes go says which binary ran.

The design defers TLS to a curl subprocess, so this is the language work
without the cryptography work: the label, the narrowing mechanism lifted out
of `check_shell_words` and given glob patterns, the `Request` type, and the
redirect rule.

> `http-design.md`

### 5. `YAML`

The other adoption blocker. CI glue is one of the four jobs wand names for
itself, and wand cannot read a workflow file, a compose file, or a
Kubernetes manifest.

It is last because Q5 has to be answered before anything starts: a
hand-written subset and a libyaml binding are different projects with
different schedules, and everything else in that document is downstream of
which one it is. Answering it early is what would let it move.

> `yaml-design.md`

## One open question

**The YAML parser's provenance.** Item 5 cannot start without it, and it is
the largest single piece of work on the list — a hand-written subset and a
libyaml binding are different projects with different schedules. Nothing
waits on the answer while YAML is last, so this one can be left open. It is
here because it is the question that decides whether item 5 is one release
or three.

## The table

| | item | no workaround | wrong today | deadline | cost |
|---|---|---|---|---|---|
| 1 | Path ordering | no | **yes** | **yes** | days |
| 2 | write_atomic | no | latent | no | days |
| 3 | FS.lock | no | no | no | blocked |
| 4 | HTTP + Net + globs | no | claim is weak | no | weeks |
| 5 | YAML | no | no | no | unknown |

The short version: do 1 while it is still cheap, because it is the last one
whose cost rises on its own. Then 2, which is small. 3 needs two answers
before it is work at all. 4 and 5 are what would stand between wand and an
outside user, and there is no outside user yet — they are the biggest items
on the list and the ones that can wait.

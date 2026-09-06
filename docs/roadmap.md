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
binary name is something nobody has written. YAML and the `FS` primitives
only add.

So the order below is ranked on value alone, and the pull that decides it is
adoption: what would stand between wand and a first outside user. There is
no outside user yet, which is why the two biggest items are also the last.

## The order

### 1. `FS.write_atomic`

Small, and the version people compose by hand is wrong three ways — the
temp file lands on another filesystem, the published file changes mode, and
a symlink is replaced rather than written through. Latent rather than
urgent, because nobody has written the broken version yet.

> `fs-primitives-design.md`

### 2. `FS.lock`

Genuinely blocked. Q8 — `flock` against `Unix.lockf` — and Q12 — how a
caller tells "already held" from "permission denied" — decide what the
function *is*, not merely how it behaves.

> `fs-primitives-design.md`

### 3. `HTTP`, `Net`, and manifest globs

The adoption item. A first outside user writes a deploy script, and the
first thing they cannot do is call an API without `Shell(curl)` — which is
also the one place the README's central claim is weaker than it sounds. A
manifest that should say where bytes go says which binary ran.

The design defers TLS to a curl subprocess, so this is the language work
without the cryptography work: the label, the narrowing mechanism lifted out
of `check_shell_words` and given glob patterns, the `Request` type, and the
redirect rule.

> `http-design.md`

### 4. `YAML`

The other adoption blocker. CI glue is one of the four jobs wand names for
itself, and wand cannot read a workflow file, a compose file, or a
Kubernetes manifest.

It is last because Q5 has to be answered before anything starts: a
hand-written subset and a libyaml binding are different projects with
different schedules, and everything else in that document is downstream of
which one it is. Answering it early is what would let it move.

> `yaml-design.md`

## One open question

**The YAML parser's provenance.** Item 4 cannot start without it, and it is
the largest single piece of work on the list — a hand-written subset and a
libyaml binding are different projects with different schedules. Nothing
waits on the answer while YAML is last, so this one can be left open. It is
here because it is the question that decides whether item 4 is one release
or three.

## The table

| | item | no workaround | wrong today | deadline | cost |
|---|---|---|---|---|---|
| 1 | write_atomic | no | latent | no | days |
| 2 | FS.lock | no | no | no | blocked |
| 3 | HTTP + Net + globs | no | claim is weak | no | weeks |
| 4 | YAML | no | no | no | unknown |

The short version: do 1, which is small and is wrong three ways when it is
written by hand. 2 needs two answers before it is work at all. 3 and 4 are
what would stand between wand and an outside user, and there is no outside
user yet — they are the biggest items on the list and the ones that can
wait.

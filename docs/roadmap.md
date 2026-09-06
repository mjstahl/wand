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
- [Two open questions, one of them urgent](#two-open-questions-one-of-them-urgent)
- [The table](#the-table)

## What the deadline actually covers

"Breaking change, so do it before a first user" is a smaller category than
it looks, and getting it wrong would distort everything below.

Adding a `Net` effect label is **additive** — every manifest written today
keeps parsing. Manifest glob patterns are near-additive, since a literal `*`
in a binary name is something nobody has written.

Two items genuinely change the meaning of code that already exists:

- **`Path` joining the ordered set**, which flips `/a/b == /a//b` to `true`
- **the `Command` value**, which makes `$()` and `$?()` sugar over
  `Shell.run!` and `Shell.query` rather than primitives

The second is the one that matters most, because it redefines the two forms
every script already uses. Nothing about a script's text changes, but what
those forms *are* does, and every doc and message that names them moves with
it. That is work to do while the number of scripts is small.

Those two have the deadline, and they lead the order below. Nothing else
has one, so everything after them is ranked on value.

The deadline leads because it is the one cost here that rises on its own,
with every script anyone writes. The pull the other way is adoption, and
adoption is not the constraint yet: there is nobody to adopt. So the
breaking work goes first, while it is cheap, and the two open-ended items
go last.

## The order

### 1. The `Command` value

`$*(cmd)` denotes a command without running it, and `Shell.run`,
`Shell.query` and `Shell.stream` are ordinary functions over one. `$()` and
`$?()` become sugar for the first two.

It arrives here having grown. As a streaming form it was a small late item —
the only one with no workaround, since `$(tail -f app.log)` reads to EOF and
so accumulates forever and returns never. As a `Command` it also closes the
higher-order case, deletes the `Shell.exec` proposal, and redefines the two
command forms every script uses.

That last part is why it is first. The change is safe now and awkward once
there are scripts to migrate, even though no script's text changes, and it
is the largest of the two the deadline covers.

> `stream-design.md`

### 2. `Path` into the ordered set

Self-contained, breaking, and it can land any time before a release. The
valuable half is `==` answering about files instead of about text.

> `path-ordering-design.md`

### 3. `FS.write_atomic`

Small, and the version people compose by hand is wrong three ways — the
temp file lands on another filesystem, the published file changes mode, and
a symlink is replaced rather than written through. Latent rather than
urgent, because nobody has written the broken version yet.

> `fs-primitives-design.md`

### 4. `FS.lock`

Genuinely blocked. Q8 — `flock` against `Unix.lockf` — and Q12 — how a
caller tells "already held" from "permission denied" — decide what the
function *is*, not merely how it behaves.

> `fs-primitives-design.md`

### 5. `HTTP`, `Net`, and manifest globs

The adoption item. A first outside user writes a deploy script, and the
first thing they cannot do is call an API without `Shell(curl)` — which is
also the one place the README's central claim is weaker than it sounds. A
manifest that should say where bytes go says which binary ran.

The design defers TLS to a curl subprocess, so this is the language work
without the cryptography work: the label, the narrowing mechanism lifted out
of `check_shell_words` and given glob patterns, the `Request` type, and the
redirect rule.

> `http-design.md`

### 6. `YAML`

The other adoption blocker. CI glue is one of the four jobs wand names for
itself, and wand cannot read a workflow file, a compose file, or a
Kubernetes manifest.

It is last because Q5 has to be answered before anything starts: a
hand-written subset and a libyaml binding are different projects with
different schedules, and everything else in that document is downstream of
which one it is. Answering it early is what would let it move.

> `yaml-design.md`

## Two open questions, one of them urgent

**How a `Command` reconciles the word check with the effect check.**
Constructing one performs nothing, so a file that builds a `Command` and
never runs it needs no `Shell` label — yet `shell_scan` finds the command
words at the literal, so a narrowed manifest would still demand them. The
word check and the effect check would key off different sites, which `$()`
does not suffer because there they are one site.

`stream-design.md` leans toward checking words where a `Command` is
consumed rather than where it is written. That is the part of item 1 most
likely to be discovered late, and item 1 is next, so it should be settled
before the lexer work starts rather than after.

**The YAML parser's provenance.** Item 6 cannot start without it, and it is
the largest single piece of work on the list — a hand-written subset and a
libyaml binding are different projects with different schedules. Nothing
waits on the answer while YAML is last, so this one can be left open. It is
here because it is the question that decides whether item 6 is one release
or three.

## The table

| | item | no workaround | wrong today | deadline | cost |
|---|---|---|---|---|---|
| 1 | `Command` value | **yes** | no | **yes** | weeks |
| 2 | Path ordering | no | **yes** | **yes** | days |
| 3 | write_atomic | no | latent | no | days |
| 4 | FS.lock | no | no | no | blocked |
| 5 | HTTP + Net + globs | no | claim is weak | no | weeks |
| 6 | YAML | no | no | no | unknown |

The short version: do 1 and 2 while they are still cheap, because they are
the only two whose cost rises on its own. Then 3, which is small. 4 needs
two answers before it is work at all. 5 and 6 are what would stand between
wand and an outside user, and there is no outside user yet — they are the
biggest items on the list and the ones that can wait.

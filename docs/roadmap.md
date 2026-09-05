# Roadmap

Seven design records sit beside this one. This is the order to work them in
and why, ranked on four things that can be checked rather than felt:

- **No workaround** — can a script do this today by other means?
- **Wrong today** — does something already ship that gives a wrong answer?
- **Deadline** — does the cost rise once anyone outside this repository
  writes a script?
- **Cost** — hours, days, or unknown.

It is a record of a decision and its reasons. It is not a schedule.

- [What the deadline actually covers](#what-the-deadline-actually-covers)
- [The order](#the-order)
- [Two questions to settle first](#two-questions-to-settle-first)
- [The table](#the-table)

## What the deadline actually covers

"Breaking change, so do it before a first user" is a smaller category than
it looks, and getting it wrong would distort everything below.

Adding a `Net` effect label is **additive** — every manifest written today
keeps parsing. Manifest glob patterns are near-additive, since a literal `*`
in a binary name is something nobody has written. `List.sum` and an `Ord`
module are additive.

Three items genuinely change the meaning of code that already exists:

- **`String.chars` → `String.bytes`**, three occurrences in this repository
- **`Path` joining the ordered set**, which flips `/a/b == /a//b` to `true`
- **the `Command` value**, which makes `$()` and `$?()` sugar over
  `Shell.run!` and `Shell.query` rather than primitives

The third is the one that matters most, because it redefines the two forms
every script already uses. Nothing about a script's text changes, but what
those forms *are* does, and every doc and message that names them moves with
it. That is work to do while the number of scripts is small.

Those three have the deadline. Nothing else does, and the ordering below is
driven by value rather than by fear of breaking things.

## The order

### 1. The free tier — a day, no decisions left

`List.sum`, `List.max`, `List.min`, the `Ord` module, the five `Int`
functions, and every tier-0 `Stream` terminal — `count`, `last`, `any?`,
`all?`, `find`, `empty?`, `sum`, `max`, `min`.

All of it is written in wand. None of it needs a decision from anyone. It
deletes hand-rolled folds from `examples/ports/dir-budget.wand` and
`examples/ports/pod-restarts.wand`, and it closes a third of the outstanding
design records.

Do this first because it costs nothing and clears the board.

> `int-design.md`, `stream-design.md`

### 2. The two renames, and the byte-model reference section

`String.chars` becomes `String.bytes`. The reference gains a short section
saying a `String` is bytes: what is byte-safe, what is ASCII-only, that
`Regex` matches bytes.

Small, and the only work here with a real deadline.

> `strings-design.md`

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

It is fourth rather than third only because Q5 has to be answered before
anything starts: a hand-written subset and a libyaml binding are different
projects with different schedules, and everything else in that document is
downstream of which one it is.

> `yaml-design.md`

### 5. `Hash` and `Base64`

Bounded, published test vectors, and it lets wand's own release pipeline
stop shelling out to `shasum` — the `Makefile` writes a checksum and
`install.sh` carries a branch for the machine where neither `shasum` nor
`sha256sum` exists.

Not an adoption driver; nobody adopts a language for sha256. It has the
highest certainty per hour on the list, which makes it the right thing to
pick up in a week with less appetite than item 3 needs.

> `hash-design.md`

### 6. The `Command` value

`$*(cmd)` denotes a command without running it, and `Shell.run`,
`Shell.query` and `Shell.stream` are ordinary functions over one. `$()` and
`$?()` become sugar for the first two.

It arrives here having grown. As a streaming form it was a small late item —
the only one with no workaround, since `$(tail -f app.log)` reads to EOF and
so accumulates forever and returns never. As a `Command` it also closes the
higher-order case, deletes the `Shell.exec` proposal, and redefines the two
command forms every script uses.

That last part is why it is not later. The change is safe now and awkward
once there are scripts to migrate, even though no script's text changes.

> `stream-design.md`

### 7. `FS.write_atomic`

Small, and the version people compose by hand is wrong three ways — the
temp file lands on another filesystem, the published file changes mode, and
a symlink is replaced rather than written through. Latent rather than
urgent, because nobody has written the broken version yet.

> `fs-primitives-design.md`

### 8. `Path` into the ordered set

Self-contained, breaking, and it can land any time before a release. The
valuable half is `==` answering about files instead of about text.

> `int-design.md`

### 9. `FS.lock`

Genuinely blocked. Q8 — `flock` against `Unix.lockf` — and Q12 — how a
caller tells "already held" from "permission denied" — decide what the
function *is*, not merely how it behaves.

> `fs-primitives-design.md`

## Two questions to settle first

Neither is on the critical path for item 1, and both get more expensive the
longer they wait.

**The YAML parser's provenance.** Item 4 cannot start without it, and it is
the largest single piece of work on the list. Deciding it early lets it run
in parallel with items 2 and 3.

**How a `Command` reconciles the word check with the effect check.**
Constructing one performs nothing, so a file that builds a `Command` and
never runs it needs no `Shell` label — yet `shell_scan` finds the command
words at the literal, so a narrowed manifest would still demand them. The
word check and the effect check would key off different sites, which `$()`
does not suffer because there they are one site.

`stream-design.md` leans toward checking words where a `Command` is
consumed rather than where it is written. That is the part of item 6 most
likely to be discovered late, and it should be settled before the lexer work
starts rather than after.

## The table

| | item | no workaround | wrong today | deadline | cost |
|---|---|---|---|---|---|
| 1 | free tier | no | no | no | a day |
| 2 | renames + docs | no | yes | **yes** | hours |
| 3 | HTTP + Net + globs | no | claim is weak | no | weeks |
| 4 | YAML | no | no | no | unknown |
| 5 | Hash + Base64 | partly | no | no | days |
| 6 | `Command` value | **yes** | no | **yes** | weeks |
| 7 | write_atomic | no | latent | no | days |
| 8 | Path ordering | no | **yes** | **yes** | days |
| 9 | FS.lock | no | no | no | blocked |

The short version: spend a day on 1 and 2 to clear the board, then put real
time into 3 and 4, because those two are what stand between wand and someone
using it for the job it describes. Everything below that is polish on a
language that already works.

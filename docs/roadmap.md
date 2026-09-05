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
in a binary name is something nobody has written. A `$*(...)` command form
is additive. `List.sum` and an `Ord` module are additive.

Two items genuinely change the meaning of code that already exists:

- **`String.chars` → `String.bytes`**, three occurrences in this repository
- **`Path` joining the ordered set**, which flips `/a/b == /a//b` to `true`

Those two have the deadline. Nothing else does, and the ordering below is
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

### 6. `$*(...)`, streaming commands

The only item where no workaround exists at all. `$(tail -f app.log)` must
read to EOF to return a `String`, so it accumulates forever and returns
never; the only bound available is `Shell.timeout`, which kills the command
and gives you an `Error` instead of the lines.

It ranks here rather than higher because wanting it means having already
adopted wand for something.

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

**What `$*(...)` answers.** The spelling is settled — `$*` because bash's
`"$*"` joins the arguments into a single string where `"$@"` expands to a
list, and a wand command is one quoted command line rather than an argument
vector. What it evaluates to is not settled, and the two answers are
different projects.

Under the narrow design it is a `Stream`, and item 6 is as described.

Under the structural design it is a `Command` — a value that denotes a
command without running it:

```ocaml
let backup = $*(pg_dump -Fc %{db})     -- assigned. Nothing has run.
let out    = Shell.run!   backup
let s      = Shell.stream backup
```

Those functions stay injection-safe because a `Command` cannot be built from
a `String`, so the quoting stays syntactic. It closes the streaming
question, `Shell.exec` and the higher-order case together, and `$()` and
`$?()` become sugar over it.

It matters here because it *replaces* item 6 rather than extending it, and
it removes `Shell.exec` from the list entirely. Decide it before that work
rather than after.

## The table

| | item | no workaround | wrong today | deadline | cost |
|---|---|---|---|---|---|
| 1 | free tier | no | no | no | a day |
| 2 | renames + docs | no | yes | **yes** | hours |
| 3 | HTTP + Net + globs | no | claim is weak | no | weeks |
| 4 | YAML | no | no | no | unknown |
| 5 | Hash + Base64 | partly | no | no | days |
| 6 | `$*(...)` | **yes** | no | no | days |
| 7 | write_atomic | no | latent | no | days |
| 8 | Path ordering | no | **yes** | **yes** | days |
| 9 | FS.lock | no | no | no | blocked |

The short version: spend a day on 1 and 2 to clear the board, then put real
time into 3 and 4, because those two are what stand between wand and someone
using it for the job it describes. Everything below that is polish on a
language that already works.

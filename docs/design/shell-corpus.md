# Design: porting a shell corpus

**Status: proposal — not implemented.** A plan for what to port, where
the port will hit a wall, and what each wall costs to remove. The doc
retires when the corpus lands in `examples/` and the gaps it names are
either closed or deliberately declined.

## The problem

wand is pitched as a bash replacement and has 275 lines of examples to
show for it. Twelve files, none longer than a screen, most of them
demonstrating a language feature rather than doing a job. Nothing in the
tree answers the question a sysadmin actually asks, which is not "how do
records work" but "show me the backup script."

That is a marketing problem and a design problem at once, and the second
one matters more. A language for replacing shell scripts is only as good
as its coverage of what shell scripts do, and right now nobody knows what
that coverage is. There is no list of the jobs, no port of a real one,
and so no evidence — for us or anyone else — about which of them wand
does better, which it does merely differently, and which it cannot do at
all. This doc proposes finding out by porting a corpus, and treats every
place the port stalls as the actual deliverable.

## Two things this doc is for

**A source list**, so the porting work draws on tasks that real people
really do, weighted by how often they do them, rather than on whatever
occurred to us that afternoon.

**A friction inventory**, which is the point. Every bash script that
resists translation is telling us something: a missing builtin, a missing
type, an idiom that wand deliberately refuses, or a wart. The last
section is the honest version of that list as it stands today, and it is
longer than it looks from inside the language.

---

## Where the examples come from

### Books

[Wicked Cool Shell Scripts, 2nd ed.][wcss] (Taylor & Perry, No Starch,
2016) is the best single source: 101 complete scripts, and — the part
that matters — the full source is on GitHub under MIT, so it can be
quoted, diffed against, and shipped beside the port. Complete scripts are
what exercise a language. One-liners test a pipeline; a whole script
tests argument parsing, the error path, cleanup, and what happens on the
third failure.

[bash Cookbook, 2nd ed.][cookbook] (Albing & Vossen) contributes 300-plus
recipes in problem/solution shape, with [examples on GitHub][cookbook-gh].
Its table of contents is more valuable than its code: read as a checklist,
each recipe title is a task wand should have an answer for, and the titles
with no answer are this project's backlog.

*Classic Shell Scripting* and *The Linux Command Line* teach well but lean
on text-processing pipelines that flatter awk more than they describe
modern operations. The Nemeth *UNIX and Linux System Administration
Handbook* is the right book for the taxonomy of the job and the wrong one
for source to port. Read them; don't mine them.

### Corpora

| Source | Size | License | What it gives |
|---|---|---|---|
| [tldr-pages][tldr] | ~4k commands, ≤8 examples each | CC BY 4.0 | The most common invocation of each tool, curated. Best signal-to-noise for "what people type." |
| [NL2Bash][nl2bash] | ~12k one-liners with English descriptions; 102 utilities, 206 flags | research release | Already paired with intent, so each row is a ready-made porting task. Its utility histogram says which builtins earn their place. |
| Stack Overflow `bash` dump | large | CC BY-SA | Vote-ranked, so frequency-weighted by real pain rather than by editorial taste. |
| Ansible builtin modules | ~80 modules | GPL docs | The taxonomy of configuration management: `file`, `copy`, `template`, `service`, `user`, `cron`, `lineinfile`, `unarchive`, `git`, `systemd`. A coverage checklist for the standard library. |
| Public GitHub Actions `run:` blocks | millions | mixed | The largest body of *modern* shell that exists. No published histogram, so mining it is our own work — but this is where today's shell actually lives. |

For phrasing the same task in a typed language, [Nushell's "Coming from
Bash"][nushell] is a direct mapping table, and Python's `plumbum` and
`invoke` show what the job reads like when the language has real values.
Useful for calibration, not for copying.

### On licensing

Treat the books as a task list. Source is lifted verbatim only from the
MIT (Wicked Cool) and CC BY (tldr) sources, and a ported file names its
origin in a header comment. Everything else contributes titles and ideas,
which are not copyrightable, and no lines.

---

## What the shell is actually used for

Ranked by how much of the modern working day each accounts for, with the
wand surface it lands on. The middle column is the reason a port is worth
reading: a bash script's failure mode is not incidental, it is the thing
wand is claiming to fix.

| # | The job | How bash gets it wrong | Where it lands in wand |
|---|---|---|---|
| 1 | CI glue: run build/test/lint, wire env, propagate status | `cmd; echo ok` succeeds after `cmd` fails; `set -euo pipefail` is a ritual, not a guarantee | `$?()` yields a `ShellResult`; dropping it is `V-DROP1` |
| 2 | Extract from logs and API output | `grep \| sed \| awk \| jq` re-parses text at every stage, silently empty on a schema change | `Regex`, `Decode`, `Stream` |
| 3 | HTTP with auth and retry | `curl` without `--fail` returns 0 on a 500; retry loops are hand-rolled | `Shell(curl)` plus `Decode`, and `Shell.timeout` for the retry |
| 4 | File munging: `find`/`xargs`, `rsync`, `tar`, permissions | filenames with spaces; `-print0` as folklore | `FS`, `Glob`, `Path` — but see **G3**, **G4** |
| 5 | Wait for a port or health endpoint | busy loop with `sleep`, no deadline, hangs forever | `Clock.sleep`, `Par.timeout`, `Par.race` |
| 6 | Wrap a cloud CLI: `aws`/`gcloud`/`kubectl … -o json \| jq` | untyped JSON, unpinned binaries, no record of what the script may invoke | `Shell(kubectl, aws)` in the manifest plus a derived decoder — wand's strongest showing |
| 7 | Clean up on exit | `trap … EXIT` fires on some paths and not others; nested traps clobber | `with r as x -> body`, released however the body ends |
| 8 | Parallel fan-out | `xargs -P` and `&`/`wait`, with interleaved output and lost exit codes | `Par.map limit f xs` |
| 9 | Backups, rotation, cron | timestamped names built by `date +%F`; `find -mtime -delete` | still blocked — **G2** |
| 10 | Threshold alerting on disk or memory | `df \| awk '{print $5}' \| tr -d %` | `Size` literals, but `Size` does not compare yet — see `ordering-domain-types.md` |
| 11 | Argument parsing and usage | `getopts` handles short flags and nothing else; usage text drifts from the parser | `Args.parse` over a derived decoder |
| 12 | Provisioning: users, packages, keys, firewall | idempotence by hand; every step re-run unsafely | mostly shelling out — **G4** |

Rows 6, 7, 8 and 11 were expected to be where wand does not merely
match bash but embarrasses it, and rows 5 and 9 where it plainly loses.
Porting the four strong rows revised that — see the next section, which
is the reason this doc exists.

---

## What porting four scripts actually found

Rows 6, 7, 8 and 11 were ported by hand, because they were the rows that
needed no language changes. All four typecheck today. Three of them read
the way the pitch promises. The fourth does not, and the reason is not a
missing library — it is the type system's front door.

### The finding: a parameter cannot carry a type

Field access on a function parameter is a type error, and inference does
not flow from the call site to fix it:

```
type Pod(name: String, phase: String)

let describe p = p.name        -- type error: field access requires a
                               -- named type, got 'a
```

Applying `describe` to an actual `Pod` in the same file does not help;
the definition is generalized before the use site is seen. And there is
no annotation syntax to say what `p` is — `let describe (p: Pod) = ...`
is a parse error, and a misleading one, because the parser reads `(p: Pod)`
as an attempted cons pattern and suggests square brackets.

Two workarounds exist. Re-bind through an annotated `let`:

```
let describe p = let pod : Pod = p in pod.name
```

or destructure with `match`, which is what the ported row 6 had to do.
The cost compounds with nesting, and cloud-CLI JSON is nothing but
nesting. Printing three fields out of a two-level record:

```
List.each
  (fn p -> match p with
    | Pod(metadata = m, status = s) -> (match m with
      | Meta(name = n) -> (match s with
        | Status(phase = ph, restartCount = rc) ->
          IO.println "%{n} %{ph} restarts=%{rc}")))
  flapping
```

That is the row advertised as wand's strongest showing. It is a pyramid
of `match` arms that exist only to read fields, and it is what a reader
coming from `kubectl get pods -o json | jq '.items[]'` would be shown.

The gap is narrow, which is the encouraging part. Chained access works
perfectly the moment the type is known:

```
IO.println "%{p.status.restartCount}"      -- 9
```

So the whole of the above is one line — `fn (p: Pod) -> ...` — behind a
parameter annotation the grammar does not currently have. **This
outranks every library gap below.** A corpus of ops scripts is a corpus
of records being passed to helpers, and today every one of those helpers
is either a `match` pyramid or an annotated re-binding.

### Three smaller ones, same exercise

**`let … in` does not carry across `;`.** Inside a parenthesised
sequence, `let x = e in` scopes over the *single* next expression, so
naming two intermediates and using them in four statements needs two
levels of nesting:

```
let stage = Path.join work (Path.of_string "pkg") in (
  let archive = Path.of_string "./dist/%{release}.tar.gz" in (
    FS.mkdir! stage;
    ...
  )
)
```

Every ported script that names anything drifts rightward. The reading
everyone expects — `let` at the head of a sequence scoping over the rest
of that sequence — is also what the `;` form's own documentation implies.

**A record pattern has no pun form.** `Repo(name = n, url = u)` matches
by name and is the form to use; `Repo n u` matches by position and is
what a hurried port reaches for, which is how a two-`String` record ends
up matched with its fields swapped. What is missing is the shorthand —
`Repo(name, url)`, binding each field to its own name, the way `{a, b}`
already puns for maps. Minor next to the annotation, and it disappears
almost entirely once a parameter can carry a type, since the reason to
destructure at all is usually just to reach a field.

**`ShellResult` has no `ok?`.** Checking whether a command worked — the
single most common thing done with a `$?()` — is `r.code == 0`. Minor,
but it is the first thing every ported script does.

### What went right

Worth recording, because it is most of it. `Par.map 4 sync repos` is the
whole of row 8. `with FS.temp_dir "release_" as work ->` is the whole of
row 7's cleanup, and it releases on every path out. Row 11's argument
parsing is four lines and gets `--port http` rejected by type. The
manifest narrowed itself correctly in all four, and `A-USES1` caught a
`Shell` declaration that a draft no longer needed. `V-BANG2` caught a
`sync!` that could not actually raise, because `$?()` does not — a lint
firing on a real mistake, unprompted, in the first script that made it.

For row 6 specifically, the idiomatic answer is the one
`examples/decode-nested-fields.wand` already gives: mirror the document's
shape in types and let every decoder derive. That part is genuinely
excellent. It is only *reading the result back out* that collapses.

---

## Where the port hits a wall

The gaps below were found by reading `stdlib/` against the twelve rows.
They are library gaps; the language findings above outrank all of them,
and G1 was the only one that came close — it is closed. Each is stated
with what it blocks and what closing it would cost. The open ones are
listed with the rest in [`../gaps.md`](../gaps.md), which is the standing
list; the argument for each stays here.

### G1 — wand cannot wait — closed

**Closed in 0.25.0.** `Clock` is an eighth effect label. `Clock.sleep`
waits, `Shell.timeout` bounds a command, `Par.race` takes the first thunk
to finish, and `Par.timeout` bounds wand code. Retry with backoff, polling
and "whichever mirror answers first" are all writable, and the temporal
types compare by value, so a backoff loop can stop at a ceiling.

`clock-and-timeouts.md` retired with it. Two limits remain, recorded in
[`../gaps.md`](../gaps.md): a virtual clock does not shorten a real
deadline, and a killed command may leave children.

### G2 — there is no clock to read, either

`Date`, `Time` and `DateTime` are types with literal syntax, and
`FS.mtime` returns a `DateTime` — but there is no `Date` module, no
`now ()`, no arithmetic on an instant, and no formatting. The types can
be parsed, decoded and — since 0.25.0 — compared by value against each
other. There is still no way to obtain an instant that is not already
written in the source or read off a file.

So the whole of row 9 is unwritable. A timestamped backup name, "delete
files older than thirty days," "alert if the last successful run was more
than an hour ago," a log line with a time in it — every one of them needs
a current instant and duration arithmetic over it.

The clock effect that waits is the clock effect that would be read, and
it now exists. So what is left is a member on `Clock` and the `DateTime`
arithmetic behind it. That arithmetic is why this did not ship with the
rest: `now - mtime` is sound and `now - an_earlier_now` is not, and they
are the same operator.

### G3 — `FS` stops at a single file

`FS.delete` removes a file or an *empty* directory. Recursive delete
exists as the builtin `fs_delete_tree` and is used internally by
`FS.temp_dir`'s release, but is not exposed. `FS.copy` copies one file;
there is no recursive copy, and nothing resembling `rsync`. So `rm -rf
build/` and `cp -r` — two of the most-typed commands in existence — have
no wand spelling and must shell out.

Cheap to close: `fs_delete_tree` is already written and already typed.
Exposing it needs a name and a decision about whether the danger of `rm
-rf` deserves a more deliberate one than `FS.delete_tree`.

### G4 — no permissions, no symlinks, no ownership

No `chmod`, no `chown`, no `symlink`, no `readlink`, no mode on a stat.
An ssh key needs `0600` or ssh refuses it; a script needs `+x` or it does
not run; half of provisioning is links into `/etc`. Row 12 is
consequently a row of `$()` calls, which is a legitimate answer — the
manifest still records `Shell(chmod, ln)` — but it means the ported
script is bash with extra steps, and reads that way.

Closing it is unglamorous surface area: a `Mode` type or an octal
literal, and six or so `FS` functions.

### G5 — no process surface beyond exiting

`Proc` has `exit` and nothing else. No pid, no "is it running," no
sending a signal, no process listing. Anything that manages a daemon
rather than merely invoking one — which is most of what a service script
does — goes through `$(ps)` and `$(kill)` and parses text, which is the
practice wand exists to end.

### G6 — no HTTP client

Row 3 goes through `$(curl …)`. That is defensible and the manifest makes
it honest, but a `Url` type and a decoder story this good sitting next to
a shelled-out curl is a visible seam. Worth a decision, not necessarily
work: "wand shells out to curl on purpose" is a fine answer if we say so.

### G7 — no archive story

`tar`, `zip`, `unzip`. Shelling out is fine. Noting it so the port does
not stall while someone wonders.

---

## Problems with the approach itself

Separate from what wand is missing, four ways this project could produce
a corpus that is worse than none.

**Porting bash idiom instead of bash intent.** A faithful translation of
a script built out of mutable counters, `eval`, word-splitting and
subshell tricks produces terrible wand and teaches the wrong lesson. The
rule is that a port reproduces what the script *achieves*, and is free to
restructure completely to get there. Where the restructuring is the
interesting part — a `trap` becoming a `with`, an accumulator loop
becoming a fold — the port should say so in a comment, because that is
the migration guide writing itself.

**Porting trivia.** The Wicked Cool collection is of its moment, and its
moment was 2016: several scripts scrape websites that no longer exist or
work around tools nobody runs. Filter hard. A script only earns a port if
the *job* is still done.

**Examples that cannot be verified.** Anything in `examples/` that shells
out to the network, mutates the machine, or depends on the day's date
cannot be checked in CI, and an example that silently rots is worse than
an absent one. Ports should be structured so the effectful edge is thin
and the rest is testable, which is a constraint worth designing for
rather than discovering — and which will itself produce feedback about
how testable the language actually makes ops code.

**Declaring victory on the easy rows.** The temptation is to port rows 6,
7, 8 and 11, publish, and quietly skip 5, 9 and 12. The gap list above
exists so that the skipping is a recorded decision instead of an
accident.

---

## Shape of the deliverable

`examples/ports/`, one file per task, each carrying a header naming its
origin and license and — where the original is MIT or CC BY — the bash it
replaces, so the file is a side-by-side migration guide as well as a
program.

```
-- from Wicked Cool Shell Scripts 2e, "trimming old files" (MIT)
-- bash:  find "$DIR" -type f -mtime +30 -print0 | xargs -0 rm -f
```

Every file typechecks, formats as a fixed point, and is covered by
`tools/check_fmt.wand` the way `stdlib/` and `examples/` already are.
Ports whose job is genuinely effectful get a `test_*.wand` beside them
using `Test.with_shell` and `Test.without_writes`, which is what those
helpers are for.

Target roughly forty files: the Wicked Cool scripts that survive the
relevance filter, plus the top tldr entries for the tools named in the
twelve rows, plus at least one script per row so the table above is
covered end to end.

## Order of work

1. ~~**Fix the parameter annotation.**~~ Shipped: `fn (p: Pod) ->` and
   `let f (r: Repo) = …` both parse, and the cons message still meets the
   mistake it was written for. See "A type on a parameter" in
   `docs/reference.md`.
2. **Decide `let … in` across `;`.** Second-largest readability win, and
   likely a small parser change. Now designed: see
   [`binding-in-a-sequence.md`](binding-in-a-sequence.md), which proposes
   `let p = e;` binding for the rest of its block, and records the one
   program whose meaning changes.
3. **Port ten more scripts**, now from rows 1, 2, 4 and 10, which need no
   language changes either. Keep updating this list — the four already
   done changed it substantially, and the reading of `stdlib/` that
   produced G1–G7 will be wrong in places that only code reveals.
4. ~~**Decide `Clock` (G1)**~~ Shipped in 0.25.0, ahead of this order,
   because the ports kept meeting it. **Reading the clock (G2)** is still
   open, and unblocks row 9 on its own.
5. **Close the cheap ones** — G3 in particular is nearly free, and
   `ShellResult.ok?` is a one-liner.
6. **Port the rest**, in row order.

The original plan had step 3 first and no steps 1 or 2 at all, which is
the argument for doing a handful of ports before designing anything: four
scripts moved a language change ahead of every library gap on the list.

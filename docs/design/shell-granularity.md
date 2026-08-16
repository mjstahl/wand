# Design: subdividing the `Shell` effect

**Status: proposal — not implemented.** Review this document before any
code changes.

## The problem

`Shell` is one bit. A deploy script's manifest reading `uses {Shell,
FS.Write}` bounds almost nothing, because deploy scripts are mostly
shell-outs: `curl` to production, `rm -rf`, and `echo` are
indistinguishable in the manifest. The docs call this inherent ("the
manifest says the file runs commands; it cannot say which") — but it is
only inherent for commands whose first word is computed. Most first words
in real scripts are literals, and a literal is checkable.

The goal is the same one the manifest already serves: a reader decides
what a file may do to their machine from its first line, and the checker
holds the file to it.

## What this is, and is not

The manifest is an **audit surface, not a sandbox**. It defends against
drift and accident — the curl that crept into a backup script, the
`rm -rf` a reviewer would have caught — and it makes intent legible at
the top of the file. It does not confine adversarial code: adversarial
code writes `Shell(sh)` (or `PATH=/evil git`), and both of those are
*visible*, which is the defense this design actually offers. Every rule
below is chosen for legibility under that threat model, not for
containment it cannot deliver.

## Proposed syntax

```
uses {Shell(git, curl), FS.Write}
```

The manifest names the binaries the file may invoke. Bare `uses {Shell}`
stays legal and means *any binary* — backward compatible, and the honest
spelling for genuinely open-ended scripts.

- Entries are bare words when they lex as one (`git`, `rsync`); anything
  else is quoted: `Shell(git, "docker-compose", "/opt/bin/deploy")`.
- `Shell()` (empty list) is a parse error: a file that runs nothing
  drops the label instead.
- Duplicate entries are an error, like a duplicated label is today.

## What is checked, and when

Three cases, from the shape of the command text in `$()` / `$?()`:

1. **Literal first word** — `$(git status)`, and the first word after
   each top-level `|`, `&&`, `||`, and `;` in the same command line.
   Checked statically at `wand t`. A word not in the allowlist is a type
   error naming the word and the manifest line that would admit it.

2. **Interpolated first word** — `$(%!{cmd} --version)` or a command
   that is entirely `%!{...}`. Statically unknowable. **Policy: checked
   at runtime, at the point of actual spawn**, against the same
   allowlist; a miss raises (an ordinary `EvalError`, catchable with
   `try`) without spawning.

3. **Data interpolation in argument position** — `$(git commit -m %{msg})`
   never affects the command word and is not this design's business.
   `%{...}` *in command position* splices a quoted argument, so the word
   it produces is data; it is checked at runtime like case 2.

Why runtime rather than "interpolated command position requires bare
`Shell`": requiring bare `Shell` would mean one `%!{tool}` anywhere pushes
the whole file back to the unbounded manifest — the design would punish
exactly the scripts trying to narrow. And why not static-only with
interpolation unchecked: an allowlist the interpreter does not enforce at
the one place it could is a promise the runtime knows how to break.

The residue is surfaced, not hidden: a new lint `V-SHELL1` flags every
interpolated command position in a file with a narrowed manifest. It is
a violation, not an advisory, precisely for its `--strict` semantics:
a warning in the ordinary loop, an error under `wand t --strict`
(`Lint.fails_strict` gates on violations only), so audit-critical
repositories can hold themselves to fully static command words.

### Shell control flow is a static error under a narrowed manifest

`$(for f in *.txt; do git add $f; done)` puts the reserved word `for`
in command position. Neither check can bound it: statically the
commands live inside the compound body, and at spawn time the word
never resolves to a binary — checking `for` against an allowlist would
just always fail. Since the keyword is literal text, wand knows all of
this at `wand t` time, so under a narrowed manifest a compound command
(POSIX reserved word in command position: `if`, `for`, `while`,
`until`, `case`, `{`, `!`, `time`) is a **type error**, and the message
says the quiet part:

```
this $() uses shell control flow, which Shell(git) cannot bound.
Write the loop in wand (List.each over one $() per item), or declare
bare Shell.
```

Under bare `Shell` it stays legal, unchanged from today. This is the
language's own pitch applied to its own feature: control flow belongs
in wand, `$()` is for commands.

## What counts as "the binary"

wand parses the command text with a small shell-word scanner for
**top-level command positions only**: the first word of the line and the
first word after each top-level `|`, `&&`, `||`, `;`. The scanner is
quote-aware exactly as far as it must be — a `|` inside single or double
quotes separates nothing — but everything else about the text
(redirections, arguments, `$(...)` subshells inside it) is the named
binary's business, not wand's.

Consequences, stated as rules:

- **Prefix assignments are skipped.** In `$(FOO=1 cmd ...)` the command
  word is `cmd`: leading `NAME=value` words are environment prefixes in
  shell grammar, and an assignment cannot execute anything. (`PATH=...`
  games fall under the threat-model section above: visible, not
  confined.) A line that is *only* assignments has no command word and
  nothing to check.
- **Wrappers are the thing you allow.** `env X=y cmd`, `xargs cmd`,
  `sudo cmd`, `sh -c '...'`, `time cmd` allow `env`, `xargs`, `sudo`,
  `sh`, `time`. wand does not peel wrappers to find the "real" command,
  because every peeling rule is an escape hatch (`sh -c` trivially
  defeats any deeper analysis). Allowing `sh` means allowing anything —
  **and that is visible in the manifest, which is the point.** The lint
  can note that `Shell(sh)` is `Shell` wearing a costume.
- **Path resolution is suffix-based.** An entry without a slash matches
  the final path component: `git` admits `git` and `/usr/bin/git`. An
  entry with a slash matches the whole word exactly.
- **Builtins are words like any other.** `cd`, `echo`, `set` are
  allowed by name; wand does not distinguish builtin from binary,
  because the distinction belongs to the shell that runs the line.
- **Subshells are not scanned.** `$(git log $(git merge-base a b))` is
  one command position (`git`); the inner `$(...)` is text handed to the
  shell. The reader's guarantee is "this file hands lines to these
  programs", not "no program this file runs can reach another".

## Inference and error messages

`wand t` already prints the manifest line to paste. It now prints the
narrowed form whenever every command position in the file is literal:

```
warning: 1:1: A-USES2: this file performs Shell and does not say so;
it could declare "uses {Shell(git, curl)}"
```

and falls back to bare `Shell` (with the interpolated site's location in
the message) when one is not. `A-USES1` symmetrically suggests dropping
an allowlisted binary that no command position names — but **only when
every command position in the file is literal**. One interpolated site
and the narrowing suggestion is off: the binary it spawns at runtime may
be exactly the one that looks unused.

## Effect rows are unchanged

The row machinery (`lib/effect_row.ml`) keeps the flat `Shell` label.
Binaries are a **per-file, syntactic fact** — collected from the file's
own `$()`/`$?()` sites and checked against the file's own manifest — not
a property that flows through unification. Two reasons:

- Rows flow through higher-order code (`List.each (fn p -> backup! p)`),
  where a binary set would either explode or degenerate to "any" and
  give a false sense of precision.
- The audit story stays compositional and stays readable: each file's
  manifest bounds the text of that file. A file that imports `deploy!`
  declares `Shell` because the row says so, but *which* binaries is
  answered by the imported file's own first line. To know what a program
  may run, read each file's manifest — the same rule as today, one level
  sharper.

## Handler interaction

`Shell!run` interception is unchanged: handlers receive the command text
exactly as today (`lib/evaluator.ml` performs `WandEffect ("Shell!run",
cmd)`), and the runtime allowlist check happens **in the default handler,
at the moment of spawn** — not at `perform`. So:

- `Test.with_shell` mocks and `--dry-run` rehearsals never trip the
  check; a sealed test can exercise a script whose environment lacks the
  binaries entirely, which is the point of sealing.
- **Jurisdiction:** the spawn-time check applies the manifest of the
  file whose text contains the `$()` site — not the caller's. This is
  what makes the compositional reading true: each manifest bounds its
  own file's text, an imported helper is bounded by the helper's own
  first line, and a helper with no manifest is unbounded (exactly as a
  bare-`Shell` file is). The audit rule stays "read each file's
  manifest", one level sharper.
- `--trace` prints the resolved command word alongside the line it
  already prints, since the scanner's result is available.
- Handlers do not receive the parsed binary name as a separate value in
  this iteration; the scanner is cheap and a handler that wants the word
  can take it the way the runtime does.

## Migration

- Existing manifests with bare `Shell` keep working, meaning *any*.
- The linter may suggest the narrowed form (an advisory, not a warning)
  when a file with bare `Shell` has only literal command positions.
- `render_manifest` output (what `wand t` tells people to paste) moves
  to the narrowed form immediately — new files get the sharper manifest
  by default, old files change only when regenerated.

## Test plan (for the implementation, when approved)

- Literal commands: allowed word, refused word, refused word's error
  names the manifest fix.
- Pipelines and `&&`/`;` chains: every top-level position checked; a
  refused second stage names that stage; a quoted `|` inside an argument
  separates nothing.
- Prefix assignments: `$(FOO=1 git status)` checks `git`; an
  assignment-only line checks nothing.
- `sh -c`, `env`, `xargs`: the wrapper is the checked word.
- Compound commands: `$(for ...)` under `Shell(git)` is a type error
  whose message names both exits (wand loop, bare `Shell`); the same
  text under bare `Shell` runs unchanged.
- Interpolated first word: runs under bare `Shell`; under `Shell(git)`
  raises at spawn, catchable with `try`; never raises under a mock or
  `--dry-run`. The check applies the manifest of the file containing
  the site, exercised through an import.
- Path-qualified words: `/usr/bin/git` vs `git`, slash-entries exact.
- Inference: narrowed suggestion when fully literal, bare fallback with
  location otherwise; `A-USES1` narrowing suggestion only in fully
  literal files; `V-SHELL1` on interpolated positions under a narrowed
  manifest — warning by default, exit 1 under `--strict`.
- Formatter round-trips `Shell(git, "docker-compose")`.

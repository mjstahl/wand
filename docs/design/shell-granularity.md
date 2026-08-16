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

The residue is surfaced, not hidden: a new advisory lint (`A-SHELL2` —
`A-SHELL1` is taken by the long-pipeline advisory) flags every
interpolated command position in a file with a narrowed manifest, so
`wand t --strict` can hold audit-critical repositories to fully static
command words.

## What counts as "the binary"

wand parses the command text with a small shell-word scanner for
**top-level command positions only**: the first word of the line and the
first word after each top-level `|`, `&&`, `||`, `;`. Everything else —
redirections, arguments, quoting, `$(...)` subshells inside the text — is
the named binary's business, not wand's.

Consequences, stated as rules:

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
the message) when one is not. `A-USES1` symmetrically: a `Shell(git,
curl)` manifest where `curl` never appears in a command position suggests
`Shell(git)`.

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
  refused second stage names that stage.
- `sh -c`, `env`, `xargs`: the wrapper is the checked word.
- Interpolated first word: runs under bare `Shell`; under `Shell(git)`
  raises at spawn, catchable with `try`; never raises under a mock or
  `--dry-run`.
- Path-qualified words: `/usr/bin/git` vs `git`, slash-entries exact.
- Inference: narrowed suggestion when fully literal, bare fallback with
  location otherwise; `A-USES1` narrowing suggestion; `A-SHELL2` on
  interpolated positions under a narrowed manifest.
- Formatter round-trips `Shell(git, "docker-compose")`.

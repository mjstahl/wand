# wand — Language Server & VS Code Extension Design

**Date:** August 2026 · **Scope:** `wand lsp` (the server) and `editors/vscode/`
(the client). VS Code only for now; the server is editor-neutral by
construction, so other editors are a client problem, later.

This document is written to be actionable by a future working session. File
and line references point at the current source. Delete the document when the
work ships.

---

## 1. Posture

Four decisions shape everything below.

**One binary.** The server is `wand lsp`, a subcommand on the existing
executable, not a separate artifact. Version skew between compiler and server
becomes impossible by construction — the same argument that embedded the
stdlib — and the server is just another consumer of `Runner`, beside the CLI
and the REPL.

**Hand-rolled protocol, no new dependencies.** LSP over stdio is
Content-Length framing plus JSON-RPC, and the v1 surface needs about ten
methods: `initialize`, `shutdown`/`exit`, `textDocument/didOpen`,
`didChange`, `didClose`, `publishDiagnostics`, `hover`, `completion`,
`codeAction`, `formatting`, `definition`, and `workspace/applyEdit` going the
other way. That is a few hundred lines over yojson, which is already a
dependency. The opam `lsp` package would be the largest dependency in the
tree and moves with ocaml-lsp's needs, not ours. `lib/lsp.ml` holds the
protocol; `bin/wand.ml` gains the dispatch line.

**Full re-check per change; no incrementality.** wand scripts are 20–300
lines and the measured frontend cost is ~10–16ms for a file with imports,
with the content-hash compile cache covering import re-checks. Re-lexing,
re-parsing, and re-inferring the whole buffer on every change is under a
frame. The hard part of most language servers — incremental analysis — does
not apply at wand's scale, and building it would be capacity nobody asked
for.

**Single-threaded, sequential.** Every request answers in milliseconds, so
there is no cancellation machinery, no request queue, no worker pool. One
loop: read a message, handle it, write the reply. If a future feature is
slow enough to need more, that feature pays for it then.

---

## 2. Two tiers: what the token stream proves, and what inference proves

The CLI loop is *generate → `wand t` → paste what it suggests*. The editor's
job is to shorten that loop — to zero keystrokes where the fix is provable,
to one click where it needs consent. The most basic omissions should never
wait for a typecheck, because they are visible in the token stream alone.

### 2.1 The lexical tier — edits applied as you type

On every `didChange` the server lexes the buffer (microseconds) and looks
for a newly **completed qualified name**: `N.member` where the character
after `member` is a non-identifier — the space in `List.map!<space>`, but
equally `(`, a newline, or a pipe. It acts only when all three hold:

1. `N` is not bound in the buffer (no `import N`, no `let N = ...`),
2. `N` is a stdlib module (`Stdlib_embed.table`, `module_types.ml:42`),
3. `member` exists in `N`'s signature.

All three are decidable without inference, and together they make the fix
unambiguous — which is the bar for editing without a gesture. The server
then sends `workspace/applyEdit`:

- **Insert `import N`** into the contiguous block of plain imports at the
  top of the file (after the manifest line if present, creating the block
  if absent), placed so the block stays in **alphabetical order**. Existing
  lines are never reordered by this edit — insertion keeps a sorted block
  sorted; an unsorted block gets the least-wrong position.
- **Extend the manifest** when the member's scheme carries manifest-relevant
  effect labels the manifest lacks: `FS.write_file!<space>` in an unimported
  file adds `import FS` *and* puts `FS.Write` into `uses {...}`, rendered
  through the same canonical form the typechecker suggests
  (`render_manifest`, `typechecker.ml:2199`; `Raise` excluded per
  `manifest_relevant`, `:2193`). Polymorphic rows contribute nothing — only
  concrete labels are added.

Deliberate limits, each load-bearing:

- **Fires only on resolution.** `FS.foo` (no such member) gets a diagnostic
  from the checked tier, never an auto-edit. A guessed edit that is wrong
  once teaches the user to distrust every edit.
- **Never touches `Shell`.** Any change to the `Shell` label — adding it,
  adding a binary, widening, narrowing — goes through the visible code
  action (§2.2), never an applyEdit. Non-`Shell` labels are safe to add
  automatically because the human at the keyboard just typed the call that
  requires them — the code *is* the consent. The cases are spelled out
  after this list.
- **Extends a manifest; never creates one.** A file with no `uses` line is
  legal, and conjuring line 1 uninvited is more surprising than extending
  it. Creating the manifest is the "Update manifest" code action.
- **Stdlib modules only in v1.** Auto-importing `./util` means guessing
  which file on disk the name refers to; that ambiguity disqualifies it
  from the no-gesture tier.
- Each applyEdit is its own undo step, and both edits land at the top of
  the file, far from the cursor.

The `Shell` rule deserves its cases spelled out, because it is the
judgment a future session is most likely to second-guess:

- *Adding a binary to an existing list.* `uses {FS.Read, Shell(git)}` and
  the buffer gains `$(curl -s %{url})`: the quick fix offers
  `uses {FS.Read, Shell(curl, git)}`. One click, but a click — the binary
  list is the finest-grained audit statement in the language, and a list
  that grows without a gesture stops bounding the code and starts
  following it.
- *Widening to bare `Shell`.* `uses {Shell(git)}` and a command whose
  first word is computed — `$(%!{tool} --version)`. No narrowed manifest
  is honest anymore, so the suggestion becomes bare `Shell` — and
  auto-applying it would silently erase a narrowing the author
  deliberately wrote. Quick fix only; `V-SHELL1` still flags the
  spawn-time check.
- *First `$()` in a file whose manifest lacks `Shell`.* `uses {FS.Read}`
  and the buffer gains `$(git status)`. The borderline case: the word is
  literal and was just typed, so the consent-by-typing argument nearly
  applies. It stays a quick fix for one reason: `FS.Write` is a fixed,
  coarse label, while `Shell(git)` is an open-ended allowlist — each
  occurrence blesses a specific new capability, and pasted or AI-inserted
  text fires `didChange` exactly like typing does. A paste containing
  `$(curl ...)` should produce a diagnostic to acknowledge, not a
  manifest that quietly pre-approved it.
- *Narrowing.* Deleting the last `curl` call fires `A-USES1`, whose
  existing `ReplaceLine` fix removes the entry. Removal is never
  automatic either.

Where `Shell` *does* change: the "Update manifest" code action (§2.2) in
all four cases, and `wand t --fix` (§3) — there the consent is the
invocation itself. The line being held is zero-gesture `Shell` changes,
not `Shell` changes generally. And if a stdlib member typed through this
tier ever carries a concrete `Shell` label in its row, the import is
still inserted automatically while the label goes to the quick fix — the
edits split across the tiers rather than the safe one waiting on the
sensitive one.

Completion covers the other entry path: accepting `write_file!` from the
completion list for an unimported module carries the same import-plus-
manifest change as `additionalTextEdits` on the item, so the edit happens
on accept.

### 2.2 The checked tier — diagnostics and quick fixes

Everything the lexical tier cannot prove flows through the normal check on
the buffer text (§4.1). Diagnostics carry the existing rule codes
(`E-TYPE`, `V-*`, `A-*`) plus hole reports, and code actions come from
structured fixes:

- **"Update manifest: `uses {…}`"** — from a manifest type error or `A-USES1`.
  The typechecker already renders the exact line
  (`typechecker.ml:2295`); the error path needs to carry it structurally
  (today it is embedded in the message string) so the action can apply it.
  This is the quick fix for manifest *creation* and for anything involving
  `Shell` — the cases the lexical tier deliberately refuses.
- **Lint autofixes** — every finding with a `fix` (`InsertLine` /
  `ReplaceLine`, `lint.ml:10`) becomes a quick fix.
- **Hole types** — a `?` produces an information diagnostic stating the
  hole's inferred type, so the answer sits inline instead of in a terminal.

### 2.3 What `wand fmt` canonicalizes

The auto-edits insert into sorted positions, but "stays alphabetical"
should be a property the blessed formatter enforces, not one that
insertion discipline maintains. Three companion changes to
`formatter.ml`:

- **The leading import region is grouped and the plain block sorted.**
  In the run of imports at the top of the file (after the manifest,
  before the first non-import item): plain `import M` statements first,
  alphabetized, then let-imports (`let [test] = import Test`,
  `let u = import ./util`) in source order. Plain imports may be sorted
  because each binds only its own namespace name — no two can bind the
  same thing — and they may be hoisted above let-imports because an
  import's right-hand side depends on nothing file-local. Let-imports
  are never reordered among themselves: they are ordinary bindings, and
  two of them may bind the same name — rebinding order is program
  meaning, and a formatter must not touch it. (In the leading region
  that collision is also a dead first binding, which `V-IMP1` flags;
  the formatter still doesn't reorder — it formats the program that is,
  lint tells the author what it should be.) Imports appearing past the
  leading region are left where they are.
- **The manifest is canonicalized**: labels in canonical order, and the
  binaries inside `Shell(...)` sorted alphabetically. Today the formatter
  re-emits the manifest in source order (`formatter.ml:1033`), while the
  suggestion path already sorts binaries (`typechecker.ml:2314`) — this
  makes the two agree, so a suggested manifest is always already
  formatted.
- **The manifest wraps like every other bracketed form**: one line while
  it fits the column budget (`max_width = 92`, `formatter.ml:20`), one
  label per line when it does not, and an over-long `Shell(...)` list
  wrapping one binary per line the same way. A wrapped manifest already
  parses — the newlines sit inside braces, at bracket depth — so this is
  emission only. Today the formatter emits the manifest as a single line
  regardless of length.

Canonical label order gets exactly one definition. Today that is
`display_order` (`effect_row.ml:28`) — `Shell` first — and it governs
rendered effect rows and `render_manifest` alike through the `EffSet`
compare. Rather than alphabetize manifests apart from signatures, change
`display_order` itself to alphabetical
(`Env, FS.Read, FS.Write, IO, Proc, Raise, Shell`), so manifests, hover
rows, `:t` output, and suggestions all agree by construction. This
changes displayed signatures too; doing it before the LSP quotes them in
every hover is the cheap moment.

Formatter changes ⇒ the corpus fixed-point-and-still-runs check applies,
per CLAUDE.md.

---

## 3. `wand t --fix`

Does not exist today (`bin/wand.ml` knows `--strict` and `--json`), and the
fix data has no CLI consumer — findings carry `InsertLine`/`ReplaceLine` and
nothing applies them. Add `--fix`:

- Applies every finding's fix to the file in place (like `fmt`), edits
  ordered bottom-up so line numbers stay valid, then **re-checks and
  repeats to a fixed point** — a fix can unlock a further finding — with a
  small iteration cap.
- The fix repertoire is `InsertLine`/`ReplaceLine` today (`lint.ml`);
  `V-IMP1`'s fix — deleting the dead import — wants a `DeleteLine`
  alongside them.
- Requires `--file`; refuses on a parse or type error it has no fix for
  (fixing around a broken file is guesswork).
- Prints one line per applied fix (`rule: line — what changed`); with
  `--json`, the applied set in the existing diagnostics shape.
- The manifest suggestion, once carried structurally (§2.2), is applied by
  `--fix` too — so the AI loop's "paste exactly what it suggests" becomes
  `wand t --fix --file script.wand`.

One fix representation, two consumers: `--fix` for the generate/typecheck
loop, `codeAction` for the human in the editor. A fix that behaves
differently in the two paths is a bug.

---

## 4. The v1 surface

| LSP feature | Source of truth | New work |
|---|---|---|
| Diagnostics (push, on open/change) | The `wand t` pipeline on buffer text | `Runner.typecheck_source` (§4.1); ranges (§4.2) |
| Hover: type **with effect row** + doc string | Type env schemes (`lookup_type`, `runner.ml:1208`), docs table, loc→type table | loc→type recording (§4.3) |
| Completion (+ auto-import on accept) | REPL completion logic (`repl.ml:136`) | Extract to a pure shared function (§4.4) |
| Code actions | Structured fixes (§2.2) | Manifest suggestion carried structurally |
| Formatting | `formatter.ml` on buffer text | Whole-document edit; §2.3 canonicalization |
| Go to definition | `Located` AST + a def-site index from checking | Def index; stdlib jump lands later via virtual documents |
| Auto-edits (§2.1) | Lexer + `Stdlib_embed.table` + schemes | The lexical scanner |

Hover is the flagship because it is where wand differs from every other
language a VS Code user has installed: hovering `deploy!` shows
`String -> String ! {Shell(git, rsync), FS.Write}` — the signature that
can't lie, under the cursor. The same table later feeds inlay hints; not v1.

Explicitly **not v1**: rename, find-references, signature help, semantic
tokens, workspace symbols, pull diagnostics, incremental sync beyond what
`didChange` full-text sync gives. Scripts are one file plus imports;
workspace-scale features solve a problem wand's domain does not have.

---

## 5. Compiler prerequisites

Each lands independently and is useful before the server exists.

1. **`Runner.typecheck_source ~path src`** — the per-buffer entry point
   (`typecheck_file` reads from disk, `run_session` accumulates
   REPL-style). **Done** (`84b5763`): returns a `source_check` record —
   type, holes, findings, the file's own type env and docs — and
   `typecheck_file` reads a file into it. Still to grow, as item 3
   lands: the def-site index, hole locations, the manifest suggestion,
   the loc→type table.
2. **A structured diagnostic type**, with `wand t`'s text and `--json`
   output re-expressed over it. **Done** (`f06a293`): `Diag.t` carries
   severity/code/loc/message/fix; `typecheck_source`, `typecheck_file`
   and `typecheck_session` fail with one, and positions travel from the
   raise sites as data (`ParseError` carries a `Token.loc option`,
   `TypeErrorAt` is stamped by the nearest `Located`, lex errors point
   at the failing token's start). Nothing re-parses a message string
   for a position. Not included: the manifest suggestion is still prose
   inside the E-TYPE message — carrying it as a `Diag.fix` lands with
   the code-action work (§2.2) or `--fix` (§3).
3. **End positions.** **Done** (`a1f71e0`): `Token.loc` is an extent —
   `end_line`/`end_col`/`end_offset`, exclusive — rather than a point.
   The lexer stamps token ends, the parser widens each `Located` to the
   whole expression it wraps (`locate`/`span_to_here`), findings span
   their item, and the manifest loc spans `uses {...}` exactly. `--json`
   emits `end_line`/`end_col` when a diagnostic has real width. Holes
   still have no locations (item 1's list).
4. **Completion as a pure function** shared by REPL and LSP. **Done**
   (`a880914`): `Complete.ident_at` returns the prefix start plus
   candidates (the LSP's text-edit shape); `Complete.line_completions`
   rebuilds whole lines for linenoise, `:` commands included. The REPL
   callback is three lines of feeding, and the logic has direct tests
   in `test_complete.ml` — no pty involved.
5. **Effect labels of a member** — scheme → manifest-relevant label set,
   for §2.1's manifest extension. `manifest_relevant` and `render_manifest`
   exist; this is a small query over them.
6. **`wand t --fix`** (§3).
7. **Order and formatter canonicalization** (§2.3) — alphabetical
   `display_order` in `effect_row.ml`, import-block sorting, manifest
   sorting and wrapping. Standalone and user-visible before any server
   exists, like `--fix`.

---

## 6. The VS Code extension — `editors/vscode/`

In-repo, not a separate repository: the TextMate grammar duplicates
knowledge of the lexer, and the same-commit-migration discipline this repo
runs on only works if the grammar lives where lexer changes land.

- **TextMate grammar.** Domain literals get real scopes — `30s`, `100MB`,
  `/etc/hosts`, `r/pat/i`, `1.2.3`, `:8080` colored as constants, not
  identifiers. The twelve literal types are the identity of the language
  and should look typed before the server even starts. Inside `$()` /
  `$?()`, inject the shell grammar so embedded commands highlight as shell,
  with `%{}` splices popping back to wand.
- **Language configuration**: `--` line comments, `(* *)` block comments,
  bracket pairs and auto-closing.
- **Client**: ~50 lines over `vscode-languageclient`; spawns `wand lsp`
  from `PATH`, overridable by a setting. Format-on-save works through the
  standard capability.
- **"Rehearse" code lens** on the `uses {...}` line, running
  `wand --dry-run <file>` in the integrated terminal. Client-side only,
  near-zero cost, and it puts the language's headline feature one click
  from every script.

Marketplace publishing joins `release.yml` once the extension is stable;
until then, `vsce package` and a sideload note in the extension README.

---

## 7. Testing

- **Server**: in-process Alcotest — feed request JSON, assert response
  JSON. No pty, no subprocess; the server loop takes an input/output pair,
  and stdio is just the production instantiation.
- **Lexical tier**: pure-function tests — buffer text in, expected edits
  out — covering the trigger rules and every deliberate limit in §2.1
  (unresolved member: no edit; `Shell`: no edit; sorted insertion).
- **Completion**: direct tests on the extracted function (§5.4).
- **`--fix`**: fixture files, fixed-point behavior, refusal on unfixable
  errors.
- **Grammar**: defer; the grammar is declarative and drifts visibly.

---

## 8. Sequencing

**A — compiler prep** (§5, each item standalone; `wand t --fix` ships to
users here, before any editor exists).

**B — server core**: framing, lifecycle, `typecheck_source` wiring,
published diagnostics. A usable "errors in the Problems pane" milestone.

**C — the loop-closers**: hover, completion, code actions, the lexical
tier's auto-edits, formatting.

**D — the extension**: grammar, client, Rehearse lens; then definition and
stdlib virtual documents.

The acceptance bar for C is the demo moment: open a new `.wand` file, type
`FS.write_file!<space>` — the import block and the manifest update
themselves, and hovering the name shows the effect row that explains why.

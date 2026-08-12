# wand — Review & Roadmap

**Date:** August 2026 · **Reviewed at:** `mjstahl/wand@main` (112 commits) · **Reviewer:** Claude, with full source inspection (`lib/`, `stdlib/`, `examples/`, `test/`, `bin/`)

This document reviews wand against its vision, identifies what doesn't yet land, proposes new features with concrete designs, and recommends removals of features that contradict the vision. It is written to be actionable by a future working session: file and line references point at the current source.

---

## 1. The Vision

wand is **a typed ML-style scripting language for Human-AI collaboration**, designed as a bash replacement. Unpacked into testable claims, the vision is:

1. **Replace bash** for the 20–300 line script: deploys, CI glue, cron jobs, log munging — for a human author who is bad at (and rightly distrusts) bash.
2. **Be easy for an AI to write.** Types tell the truth; errors are values with explicit control flow; a typecheck (`wand t`) gives the model honest feedback without execution; typed holes let the model ask the type system questions.
3. **Be easy for a human to audit.** The emerging differentiator (from design discussions): *the signature tells you what a script will do to your machine, and the runtime can prove it by rehearsing.* Scripts that can't lie about their blast radius.
4. **Design DNA** — five principles that every feature, removal, and rule in this document is tested against:
   - *Inference does the work.* Full static typing with no mandatory annotations; the same rule governs new features (effect rows are inferred from builtins and displayed, never hand-written; decoders derive from type definitions).
   - *Literals over ceremony.* Domain values are written directly (`30s`, `/etc/hosts`, `*.wand`, `100MB`), not constructed through parse calls — the value's written shape carries its type.
   - *One blessed construct per problem.* Cleanup gets `with` and nothing else; parallelism gets `Par.map` and nothing else; error capture gets `try` and nothing else. A second construct for a solved problem is a defect — this principle drove the §5 removals.
   - *`Result` everywhere, `!` escape hatches.* Fallible operations return `Result`/`Option` by default; every one has a raising `!`-named sibling, so risk is legible in the name at the call site (and checked, not social, once W-BANG1/2 land).
   - *Redundant, adjacent, checkable structure.* Important facts are stated through two channels so slips surface as visible disagreement (name + effect row; manifest + inference); information lives next to where it's consumed, not across a file join; and rules are enforced by tooling, not convention (§4.10). Where one of the three is missing, this document's bug list is what results: README/impl drift was redundancy without checking; `FS.glob!` was convention without enforcement.

Claims 1–2 are substantially delivered. Claim 3 is *further along than the README admits* — the runtime half already exists — but the type-level half is absent. Claim 4 is mostly honored with a few violations worth fixing (§3).

---

## 2. What's There — Scorecard Against the Vision

### 2.1 Delivered and solid

- **HM inference with good ergonomics.** Multi-equation function definitions, inferred recursion, constructor checking, types flowing through pipelines. `lib/typechecker.ml` (~1,150 lines) includes **match exhaustiveness checking** (line 402+), with a deliberate, documented carve-out: map patterns are partial by design and never flagged. That's the right call and correctly reasoned in the source comments.
- **Lexical domain types** (`Path`, `Glob`, `Duration`, `Url`, `Size`, `Version`, `IPv4`, `CIDR`, `Port`, `Date`/`Time`/`DateTime`). This is wand's most distinctive shipped idea — a direct attack on stringly-typed scripting. `Glob` vs `Path` as distinct types with `FS.glob` accepting only `Glob` is exactly the kind of mistake-prevention the vision calls for.
- **Shell integration that keeps the ecosystem.** `$()` raises on failure, `$?()` returns a `ShellResult`, `|>` threads stdin, interpolation works. The escape hatch is first-class rather than bolted on.
- **`Result`-centric stdlib** with a consistent-ish `?`/`!` naming convention, `Option` module, `to_result` bridges.
- **Tooling breadth for a young language:** REPL with `:type`/`:doc`/`:load`, one-shot `e`/`t`/`d` commands, `wand env`, doc strings on stdlib functions, shebang support, a formatter (`wand fmt`), and a test suite covering lexer/parser/exhaustiveness/imports/CLI/formatter.
- **Self-hosting posture:** the stdlib is written *in wand* (641 lines of `.wand` over OCaml builtins), which keeps the surface honest — if the stdlib is pleasant to write, the language is.

### 2.2 Implemented but invisible — the README/code gap

This is the single most important finding of the review. **The implementation is roughly one major release ahead of the documentation.** Present in source, absent from README:

| Feature | Where | State |
|---|---|---|
| **Algebraic effect handlers** (`handle ... with \| op args, k -> ...`, `return` arms) | `lib/evaluator.ml:106+` (OCaml 5 `Effect.Deep`), `lib/parser.ml:802+`, typechecked at `typechecker.ml:781` | Working. `$()`, `$?()`, stdin-threaded variants, `write_file`, `fs_append`, `fs_remove` all `perform` interceptable effects (`process_run`, `write_file`, `fs_remove`, ...) |
| **Contracts** (`requires` / `ensures`, with `result` bound in postconditions) | `evaluator.ml:374–391`, typechecker enforces `Bool` at `:794` | Working, runtime-enforced |
| **`try` expression** (raise → `Result`) | `evaluator.ml:393+` via effect handlers | Working |
| **Typed holes** (`?`) + `Types.holes` | `ast.ml:59`, `stdlib/Types.wand` | Working — the "AI sketches, type system fills in" feature from the README pull-quote, undocumented |
| **`Types` module** (reflection: `check`, `check_program`, `holes`, `ok?`, `fails?`) | `stdlib/Types.wand` | Working |
| **`Test` module** (labeled assertions, `raises`) + test runner | `stdlib/Test.wand`, `test/test_test_runner.ml` | Working |
| **`Option` module** | `stdlib/Option.wand` | Working |
| **Formatter** (`wand fmt`) | `lib/formatter.ml` (620 lines) | Working with admitted gaps — its own help text says `requires`/`ensures`, `handle`, `$()`/`$?()`, `try` have no formatting rule yet |
| **`;` statement separators, shebang** | `token.ml:92`, `examples/log-summary.wand` | Working |

**Why this matters more for wand than for most projects:** the README *is the language reference* — `CLAUDE.md` explicitly tells AI sessions to learn wand from it. An AI writing wand today literally cannot use `handle`, `try`, contracts, or holes, because its only reference omits them. For a language whose pitch is AI-writability, doc drift isn't a housekeeping issue; it's a functionality regression. The vision's own principle applies: the README and the implementation are two sources of truth, currently disagreeing, with no check to catch it (see §4.7 for the fix).

### 2.3 The strategic surprise: dry-run is ~70% built

The design discussions treated effects/capabilities/dry-run as future work. In fact:

- The **runtime effect layer exists**: every shell execution and the mutating FS builtins route through `WandEffect`, interceptable by `Effect.Deep` handlers (`evaluator.ml:325, 541, 814, 1020–1023, 1237+`).
- What's missing is the **type-level half** (no effect rows anywhere in `typechecker.ml` — signatures don't mention effects), the **built-in interpreters** (`--dry-run`, `--trace` CLI modes), the **manifest** (`uses {...}`), and a **coverage audit** (which builtins still bypass `perform` — e.g., verify `fs_mkdir`, `fs_rename`, `fs_copy`, `fs_cd`, `Env.set`).

This changes the roadmap: the question is no longer "should wand add effects" but "wand has runtime effects; finish the visible half." §4.1–4.3.

---

## 3. What Doesn't Land — Fix Before Building New

Ordered by severity.

### 3.1 Broken examples (trust killers)

`examples/log-summary.wand` does not run against the current stdlib:

- It calls `String.contains` — the stdlib defines `contains?` (`stdlib/String.wand:31`).
- It imports `Exe` and calls `Exe.stdin ()` — no `Exe` module exists anywhere in `lib/` or `stdlib/` (grep confirms). Either an `Exe`/`Stdin` capability was removed or never landed. `IO.read_all` may be the intended replacement.

For a 0-star project courting adoption, a visitor's first move is running an example; a crash on example #2 ends the evaluation. **Recommendation:** fix both, then add a CI job that *executes every file in `examples/`* (with shell-dependent ones gated or mocked via `handle` — see §4.4). Examples must be tests.

### 3.2 The `!` convention is inconsistent — and unchecked

The convention (implied throughout): `?` = predicate, `!` = raises instead of returning `Result`. It's load-bearing — it's how a reader audits control flow without reading bodies. Violations found:

- **`FS.glob!`** (`stdlib/FS.wand`): here `!` means "takes an explicit directory argument," not "raises." Same name, opposite meaning of `Map.get!`/`JSON.parse!`. Rename to `FS.glob_in dir pattern` (or make `glob` take an optional dir).
- **`List.head`** (used in `log-summary.wand` on a possibly-empty list): if it raises on empty it should be `head!` with a `Result`-returning `head`; if it returns `Option`, the example's interpolation of it is wrong. Audit the whole stdlib: every function that can raise must carry `!`; every raising function should have a non-`!` sibling.
- Longer term, the convention should be *checked*, not social — once effects are typed (§4.1), "function without `!` in its name has `Raise` in its inferred effect" becomes a lint. Name + inferred effect = redundant structure that catches drift.

### 3.3 Effects exist at runtime but signatures still lie

Today `wand d`/`:t` show `Path -> String` for something that executes shell commands. The vision's core promise — the signature tells the truth about what a function *does*, not just its data shape — is unmet, and the gap is now uniquely closable because the runtime half exists. This is the roadmap centerpiece (§4.1).

### 3.4 `handle` is powerful, undocumented, and un-positioned

User-facing algebraic effect handlers are a double-edged feature: they enable test mocking and custom interpreters, but unrestricted deep handlers make control flow non-local — the exact property wand avoids elsewhere. Right now `handle` exists with no documentation, no formatter support, and no stated intent. **Resolved positioning** (full power retained, aimed deliberately):

1. **Documentation leads with mocking.** The first `handle` example in the reference should be "test your deploy script without touching the network," not a general effects tutorial. How the docs frame it determines how the community — and, critically, AI sessions learning from the README — will use it. Legitimate production uses (retry wrappers re-performing `process_run`, audit interceptors logging a third-party module's shell attempts, sandboxing an import's `FS.Write`) are all interception-at-boundaries and stay in-bounds; using `handle` for general control flow does not.
2. **Keep `perform` closed — deliberately.** There is no `perform` keyword in the parser today, so users can only handle *builtin* effects; they cannot define effect operations. This is the load-bearing restriction that prevents handlers from becoming generators/coroutines/exceptions-by-another-name. Hold the line on purpose: treat any future user-`perform` proposal as a major design decision requiring a compelling scripting use case.
3. **Built-in modes are the blessed rehearsal path.** `--dry-run`/`--trace` as runtime flags, never "paste this handler at the top of your script" — a runtime-implemented dry-run is a guarantee an auditor can trust at a glance; a user-handler one is only as good as its effect-operation coverage. Manifests and flags are for reviewers; `handle` is for test and library authors.

The failure mode being designed against is not "someone uses `handle` in production" — it's `handle` becoming the idiomatic path for things wand has better constructs for: error handling (`try`/`Result` owns it) and cleanup (`with` brackets will own it, §4.6). Suggested validation: write the retry-wrapper and audit-logger examples in current wand; if they work cleanly without user-defined effects, the closed-`perform` design holds.

### 3.5 Contracts: good bones, undecided role

`requires`/`ensures` with `result` binding is a tasteful, small contract system. Undecided: interaction with `try` (a failed postcondition raises an `EvalError` — should `try` catch contract violations? Arguably no: a broken contract is a bug, not a fallible operation, and swallowing it into `Error` hides bugs). Also: error messages print the AST of the failed clause via `Ast.show` — verify these read as *wand* syntax, not internal notation. Document contracts with a scripting-flavored example (`requires FS.exists? src`), and add formatter support.

### 3.6 Smaller warts

- **`else ()`** (`examples/repo-status.wand`): the classic ML wart, noisy in scripting where one-armed conditionals are constant. Add `if cond then expr` sugar for `Unit`-typed branches, or a `when cond -> expr` statement form.
- **Formatter gaps** are self-admitted (`bin/wand.ml:56`) for exactly the newest constructs. An AI-collaboration language wants `wand fmt` as the canonical-output normalizer (redundant structure via enforced formatting, gofmt-style); gaps in the newest syntax are where drift will happen.
- **`rename old_ new_`** — trailing-underscore parameter names in the stdlib suggest keyword collisions leaking into public docs; cosmetic but visible in `wand d`.
- **README stdlib list drift**: `Option`, `Test`, `Types` missing from the module list; `FS.temp_file` exists in source but not in the README's FS list; README mentions a `Process` module in REPL preloads that has no stdlib file.

---

## 4. New Features — Designs and Sequencing

Design DNA constraints apply to everything here: inferred not annotated; one construct per problem; `Result` + `!`; scripting-scale, not research-scale.

### 4.1 Effect rows in the type system (the load-bearing feature)

**Goal:** `:t deploy` shows `Unit -> Result Unit ! {Shell, FS.Write}`.

- **Lattice (fixed, coarse):** `Shell · FS.Read · FS.Write · Net · Env · Proc · Raise`. Six-ish, not extensible by users in v1.
- **Seeding:** effects live only on builtins. `$()` = `{Shell, Raise}`, `$?()` = `{Shell}`, `FS.read_file` = `{FS.Read}`, `write_file` = `{FS.Write}`, `Map.get!` = `{Raise}`, etc. Everything else inferred through the existing HM machinery — effect rows unify like type rows; row-polymorphism so `List.map : (a -> b ! e) -> List a -> List b ! e`.
- **Syntax:** effects appear after `!` in *displayed* types and optional annotations. Users never must write them.
- **`Raise` as an effect** closes §3.2's loop and makes `try : (Unit -> a ! {Raise | e}) -> Result a ! e` honest.
- **Handlers discharge effects:** a `handle` that intercepts `process_run` removes `Shell` from the handled expression's row. This falls out of typechecking `EffectArm` (already at `typechecker.ml:781`) once rows exist.
- **Implementation note:** retrofit while the stdlib is 641 lines. Every month of stdlib growth raises the cost. The typechecker already threads a tenv/env pair through `infer`; the row is a third piece of state unified at application nodes.

### 4.2 Script manifests

```
uses {FS.Read, Shell}
```

Top-of-file declaration, checked against the whole-script inferred row: inferred ⊄ manifest = type error. `wand script.wand` runs without one (don't tax casual use); `wand --strict` (and eventually a project setting) requires it. The manifest is the audit line for the human in the human-AI loop: read one line, know the blast radius. Explicitly *not* Deno-style path-granular permissions in v1.

### 4.3 Built-in interpreters: `--dry-run` and `--trace`

The headline demo. Three fixed runtime modes, implemented as internal `Effect.Deep` handlers wrapping the whole program (the mechanism already exists — this is plumbing plus presentation):

```
wand deploy.wand              # run
wand --dry-run deploy.wand    # Shell / FS.Write / Net / Env-set logged as "would ...", reads execute
wand --trace deploy.wand      # everything executes, every effect logged with arguments
```

Prerequisite: **audit builtin coverage** — every side-effecting builtin must `perform`, none may call the OS directly (verify `fs_mkdir`, `fs_copy`, `fs_rename`, `fs_cd`, `fs_create`, `env_set`, IO writes). Document the inherent honesty caveat: dry-run reads see pre-mutation state, so output can diverge from a real run; wand's version can't *drift* like hand-rolled `$DRY` flags, but it can't rehearse reads-of-writes.

### 4.4 `Test` + `handle` = hermetic script tests (near-free, high value)

Position the existing pieces as one workflow: a test wraps the function under test in `handle`, intercepts `process_run`/`write_file`, returns canned outputs, and asserts on both results and *which effects were attempted*. No other scripting language offers "unit-test your deploy script without a network." Needs: documentation with a worked example, a small `Test.with_shell [(pattern, output), ...]` convenience, and formatter support for `handle`.

### 4.5 Decoders — one abstraction for every untyped boundary

The `$()` boundary is wand's ORM problem: twelve domain types, and shell output lands as `String` (see `repo-status.wand` — four regex/`to_int` scrapes in ten lines). Unify JSON/TOML/CSV/shell-output parsing behind a single combinator type:

```
type Decoder a   -- abstract
Decode.int / string / bool / list / field / map2 / and_then / one_of
Decode.duration / path / url / size / version / date   -- domain literals decode as themselves
JSON.decode  : Decoder a -> JSON -> Result a
TOML.decode  : Decoder a -> TOML -> Result a
CSV.rows     : Decoder a -> String -> Result (List a)
Shell.lines  : Decoder a -> String -> Result (List a)   -- line/column-oriented
```

Plus **derivation from single-constructor named-field types**: `Decode.of Commit` mechanically reads fields by name — type definition as single source of truth, decoder generated. The existing `JSON.field`/`get_string` dynamic-poking API stays as the low-level layer. Deliberately no per-CLI typed wrappers (`Git.log : ...`) — unbounded, instantly stale surface.

### 4.6 Resource brackets

One construct, no `defer`, no `trap`:

```
with FS.temp_dir () as tmp ->
with FS.lock ./deploy.lock as _ ->
  ...
-- released innermost-first on success, raise, or Ctrl-C
```

Backed by a `Resource a` value (`acquire`/`release` pair) so users define their own in wand. Must interact correctly with `try` (release before the raise converts to `Error`), with handlers (release on continuation abandonment), and with `Par` cancellation (§4.7). Stdlib starters: `temp_dir`, `temp_file` (exists — wrap it), `lock`, `cd_scoped` (fixes the global-mutable `FS.cd`).

### 4.7 `Par` — fork-join only

```
Par.map  : Int -> (a -> b ! e) -> List a -> List (Result b) ! e
Par.each : Int -> (a -> Unit ! e) -> List a -> Unit ! e
```

Explicit max-concurrency first argument; children never outlive the call; failures collected in order; Ctrl-C cancels children and runs their brackets. No async/await, no futures, no channels — the moment wand has function coloring it has failed as a bash replacement. OCaml 5 domains/effects make the implementation tractable. Note the interpreter interaction: `--dry-run` under `Par` should serialize or clearly interleave its log.

**Placement:** a new `stdlib/Par.wand` following the existing pattern (thin wand wrappers + doc strings over OCaml builtins, as in `FS.wand`), but with all real work in the OCaml layer — a `par_map` builtin over OCaml 5 domains enforcing the guarantees above. This weight distribution is the design: parallelism enters wand *only* through this module's two functions, with no user-accessible spawn/thread/channel primitive to build unstructured concurrency from; the module boundary is the constraint. Implementation caution: workers perform effects on their own domains, so `--dry-run`/`--trace` handlers must be installed per-domain or effects escape the interpreter. Add `Par` to the reference module list and REPL preloads — and note the README's current preload list names a `Process` module that has no `stdlib/` file (one more §2.2-style drift item for the Phase 0 sync).

### 4.8 Distribution (not a language feature; adoption-gating)

- **Static binary:** small (~10MB target) musl-linked `wand`, one-line install, vendorable into repos and base images.
- **`wand compile script.wand -> self-contained executable`** — neutralizes "wand isn't on the target box," the historical moat that killed bash replacements. **Architecture — decided: appended payload, not transpile-and-link.** The output is a byte-copy of the prebuilt runtime with the script (plus the transitive closure of its *user* modules — imports are static, so this is exact) appended as a data section; at startup the runtime runs the payload if present. Zero toolchain on the user's machine — the alternative (transpile to OCaml, compile natively) would require an OCaml toolchain everywhere and torch the distribution story. **Tree-shaking the stdlib: rejected.** The wand-authored stdlib is ~20KB of a ~10MB binary (the size is the OCaml runtime + builtins, which can't be shaken without per-script recompilation); under the payload model the stdlib is baked into the runtime image by construction. The instincts behind shaking get better tools: startup speed → **lazy per-module deserialization** of precompiled stdlib ASTs, loading only the import closure (applies to plain `wand script.wand` too); blast-surface worry → the bound that matters is performable *effects*, not present *code* — `wand compile` typechecks the manifest and should **stamp the inferred effect row into the executable's metadata** (`./deploy --manifest` prints `{Shell, FS.Write}`), an auditable capability statement on the artifact itself. Minimizing authority beats minimizing bytes.
- **GitHub Action** (`setup-wand`) — CI is the beachhead: controlled environment, per-repo tooling already normal, individually adoptable.

**Stdlib embedding — decided: the stdlib stays in wand, embedded at build time.** The binary must contain the stdlib either way, and the embedding pipeline (dune rule / `ocaml-crunch` turning `.wand` sources into compiled-in string constants, loader checking the embedded table before the filesystem) is required by `wand compile` regardless — user scripts are wand and must be embedded, so the stdlib rides the same mechanism. Rewriting the stdlib in OCaml would therefore remove no work, and would forfeit the decisive property: **once effect rows land, a wand-authored stdlib gets its effect signatures inferred and checked from the builtins it calls** (`FS.glob` provably carries `{FS.Read}`; nothing hand-written, nothing to go stale), whereas an OCaml-authored stdlib turns ~150 functions into hand-assigned effect seeds that the typechecker cannot verify — the README/`FS.glob!` drift failure mode reintroduced at the layer where honesty matters most. Same for `Raise`: W-BANG1/2 can only check wand-implemented functions. Supporting reasons: the stdlib is the typechecker's best continuous test; doc strings live where `wand d` reads them; it's the surface an AI session can safely extend (reviewable wand vs. trusted-base OCaml). The boundary stays as-is: OCaml only for what wand cannot express (syscalls, regex engine, `Par` domains — keep the trusted base minimal). **Startup latency — findings from the source (startup must be as close to bash as possible; propose a measured budget of `wand e "1+2"` within 2–3× of `bash -c ':'`, benchmarked with hyperfine in the existing `bench/`):**

- *Script mode is already lazy* — `run_file` (`runner.ml:503`) loads only the script's imports. Good baseline.
- **One-shot commands eagerly load nine stdlib modules — including `wand t`.** `bin/wand.ml:80–157`: `e`/`t`/`d`/`env` run a `stdlib_prelude` (List, String, Path, FS, IO, Duration, Env, Map, Regex) before the user's expression — each import a disk read + lex + parse + full HM inference + eval. The AI loop's hottest command pays the largest fixed tax; plain scripts pay less. Fix in Phase 0: drop the eager prelude, resolve stdlib modules on first reference — `wand t "1 + 2"` should touch zero files.
- **`find_stdlib_dir` walks the directory tree upward once per stdlib import** (`module_types.ml:12–28` — `resolve_stdlib` recomputes the walk each call; nine imports = nine walks). Memoize per-process in Phase 0; the mechanism dies entirely when embedding lands (and it's a dev-repo assumption that breaks for installed binaries anyway).
- **No cross-invocation caching:** `load_module` (`runner.ml:432`) re-lexes/re-parses/re-infers every module from disk text on every run; the `cache` hashtable dedupes only within one invocation. Add a content-hash-keyed compile cache (`~/.cache/wand/`, Marshal-serialized post-typecheck ASTs + type envs — the `.pyc` move). Worth building even though stdlib embedding supersedes it there, because it covers **user modules**, which embedding never will.
- Endgame is the embedded precompiled stdlib above: startup = one deserialization (`Marshal` of ASTs + type envs, never closures), zero filesystem access, zero inference — and version skew between binary and stdlib becomes impossible by construction.
- Incidental drift found during the trace: README claims the REPL preloads "all stdlib modules"; the prelude lists nine — `Option`, `Test`, `CSV`, `JSON`, `TOML` are absent. Add to the Phase 0 doc sync.

**Performance model vs. bash and Python (current standing: between the two — faster than Python, slower than bash; the regimes have different ceilings):**

- *Startup:* bash wins and always will (~1–3ms is near the process-spawn floor), but wand's floor is low — OCaml native binaries start in ~1ms, and today's gap is almost entirely the interpreted-frontend work above. Post-fixes + embedded precompiled stdlib: plausibly 2–5ms — never beating bash, but imperceptible, and well ahead of Python's ~20–50ms (the incumbent for "bash script that grew up"). Hence the 2–3×-of-bash budget.
- *Shell-heavy scripts — wand should **win**, and this is the regime real scripts live in.* Idiomatic bash cannot work in-process: every `cut`/`sed`/`tr`/`wc` and every `grep`-in-a-loop is a fork+exec at ~1–5ms; bash text-processing is often mostly process-spawn overhead. Wand's `String.lines`/`List.filter`/`Regex.match?` do the work in-process in native OCaml — `examples/repo-status.wand`'s `| wc -l | tr -d ' '` spawns three processes to count lines where `String.lines |> List.length` spawns zero. Note the alignment: performance and type-safety point at the same behavior — the more of a script that is wand rather than embedded shell, the faster *and* safer it gets (the escape-hatch cliff, W-SHELL1, and the perf story are one story).
- *Pure computation:* wand crushes bash (bash loops are 10–100× slower than nearly anything); against Python the tree-walking evaluator is roughly CPython-class today with two known, non-architectural drags found in the trace: **environments are assoc lists** (`stdlib_eval_env @ imported.eval_env`, `List.filteri` counting in `runner.ml:456+`) making variable lookup O(scope size) — fix with array/index-based environments when measured to matter; and **process output is read one byte at a time** (`Buffer.add_channel buf ic 1` / `input_char` loops in `runner.ml:5–40`) — buffer the reads; noticeable when `$()` captures megabytes.
- *Structural wash:* each `$()` spawns via `sh -c` — same cost class as bash backticks, so per-command overhead is parity; the fork-elimination win accrues only as work moves out of `$()` into the stdlib.
- Scoreboard for the reference: startup — bash wins, wand within budget; orchestration — parity; text/data processing — wand wins via fork elimination; pure compute — wand ≫ bash, targets CPython-parity via the two interpreter fixes.

### 4.9 Doc infrastructure (fixes §2.2 permanently)

Every README code block should be an executed test (doctest extraction, or generate README sections from stdlib doc strings — they're already well-written). The README/impl split is a two-sources-of-truth problem; make one derive from, or be checked against, the other. Also: split the README into a leaner pitch + a `docs/reference.md` that `CLAUDE.md` points at, and add `handle`/`try`/contracts/holes/`Test`/`Option`/`Types`/`fmt`/`;`/shebang to the reference *now*, ahead of any new work — it's the cheapest capability unlock available (the features are built; only the AI's reference is missing them).

### 4.10 Lint: every checkable rule in this document gets programmatic enforcement

A documented-but-unchecked rule is a social convention, and social conventions drift — the `FS.glob!` naming violation happened *because* the `!` convention lived only in prose. For wand's audience the stakes double: the AI loop is generate → `wand t` → fix, and a rule not surfaced in that loop effectively does not exist for the model. Docs + checker is redundant structure in the good sense: prose states the rule, the linter enforces it, and disagreement between them becomes visible instead of silent.

**Architecture:**

- Lints run **inside `wand t`** as warnings — one tool, findings land directly in the loop where `t` already sits. No separate `wand lint` binary.
- `--strict` promotes warnings to errors (consistent with the §4.2 manifest flag).
- `--json` output for agent consumption: rule ID, span, message, autofix if available.
- **Rule IDs are the doc/linter bridge.** Every enforceable rule in the reference gets an ID (`W-OR1` = §5.9 rule 1, `W-BANG1`/`W-BANG2` = the `!` convention, `W-PRED1` = `?` returns `Bool`, ...). The ID appears in the reference *and* in the lint message. A CI check walks the reference's rule registry and fails if any lintable rule lacks an implementation or an explicit `judgment-only` tag — §4.9's doc-drift fix applied to the rules themselves.

**Rule classification (from this document's do's and don'ts):**

| Rule | ID | When checkable | Kind |
|---|---|---|---|
| `?` functions return `Bool` | W-PRED1 | Now (inferred type at definition) | Lint |
| `Result 'a Unit` banned — misfiled `Option` (§5.9 r1) | W-OR1 | Now | Lint |
| Trailing-underscore params in public signatures | W-NAME1 | Now | Lint |
| Raising function lacks `!` in name | W-BANG1 | Phase 1 (needs `Raise` in rows) | Lint |
| `!`-named function that cannot raise (stale name) | W-BANG2 | Phase 1 | Lint |
| Mixed Option/Result pipeline without visible `to_result` (§5.9 r5) | W-OR2 | Phase 1 | Lint |
| Large bash blob in `$()` (pipes/`&&`/redirection/loops past threshold) — suggest wand-level stages | W-SHELL1 | Now | **Heuristic — warn only, never error** (the escape-hatch cliff pushback; sometimes the opaque one-liner is right per §5.11) |
| Multi-equation contiguity/arity/order/reachability (§5.10) | — | Phase 0 | **Language error**, not lint |
| Manifest ⊇ inferred effects (§4.2) | — | Phase 2 | Type error, not lint |
| Option-vs-Result choice beyond the `Unit` tell; tuple/record/Map boundary; `handle` positioning; shell-vs-wand pipe placement | — | — | **Judgment-only** — tagged as such in the registry so they are never linted into noise |

The §5 removals need no lint machinery: with no external users, cut the forms outright — removed names fail as ordinary unknown-name/parse errors, and `git grep` migrates the stdlib and examples in the same commit. The heuristic row is the only lint allowed to be opinionated without being certain — everything else in the table is either mechanically decidable or explicitly out of the linter's jurisdiction. That boundary is itself a rule: **a lint that fires on correct code trains its audience — human or model — to ignore lints.**

---

## 5. Removals — Features That Contradict the Vision (Phase 0)

Each of these purchased convenience with implicitness — implicit state, implicit naming, implicit partiality, implicit ordering, implicit power. Wand's bet is that explicitness *is* the convenience, for both of its intended authors. At 0 stars, "before anyone depends on them" is now — the cheapest this decision will ever be. Ranked by confidence:

### 5.1 `FS.cd` — remove (the one outright mistake)

A global, mutable current-working-directory is imported bash state management. It makes every relative `Path` in the program context-dependent on an invisible mutation — exactly the action-at-a-distance wand exists to kill — and it poisons future features: two `Par` branches calling `FS.cd` is a data race on process state, and `--dry-run` can't rehearse honestly when path resolution depends on mutation order. Replace with a scoped bracket (`with FS.in_dir ./build as _ -> ...`, §4.6) or per-call directory arguments, which `FS.glob!` already demonstrates.

### 5.2 Bare `import ./utils` → auto-bound `Utils` — remove

The README's own "still supported" phrasing marks it as legacy. A binding materializes whose name is derived by capitalization convention from a *filename* — implicit magic, ungreppable provenance, and a third way to do something that has two good explicit ways (`let utils = import ./utils`, destructured imports). One blessed construct per problem; this is a second construct for a solved one.

### 5.3 Map dot-access (`m.x`) — remove; dot means checked field only

A genuine type-honesty violation: `p.x` on a `Point` is verified (the field provably exists); `m.x` on a `Map Int` is unverifiable (key presence is a runtime question) and presumably raises on a miss. Same syntax, opposite safety guarantees, nothing at the use site distinguishing them — a signature that lies. `Map.get` (Result) and `Map.get!` (raises, and says so) already exist and are honest. Map *patterns* (`[x = a] = m`) can stay: a non-matching arm is at least a visible control-flow event.

### 5.4 Positional construction / tuple-destructuring of named-field types — cut (the destructuring at minimum)

`Point (1, 2)` alongside `Point (x = 1, y = 2)` is two ways to do one thing, where the positional way silently — and *type-correctly*, when fields share a type — produces wrong programs on field reorder. The shorthand `let (x, y) = p` / `let (r) = c` is worse: tuple syntax destructuring a non-tuple, with `let (r) = c` giving parentheses load-bearing, invisible meaning. For an AI-writability language this is a documented trap: generating `let (w, h) = rect` in the wrong field order is precisely the plausible-but-wrong output the language exists to prevent. Keep named patterns; if terseness is wanted, field punning (`Point (x, y)` binding by *name*) is the safe form of the same convenience.

### 5.5 `Types` module — demote from user stdlib to internal test infrastructure

Runtime reflection over source strings (`Types.check "1 + 1"`, `Types.holes`) is typechecker self-testing infrastructure — good infrastructure, wrong shelf. No script typechecks code strings at runtime; the AI workflow it superficially serves is served better by `wand t` outside execution. It costs documentation surface, implies eval-like capability, and once effects land it forces awkward questions (the effect row of a function that runs the whole frontend). Move behind the test suite.

### 5.6 Consolidations — decided

**`FS.walk` — remove in favor of `FS.glob`.** `walk path` is `glob **` rooted at `path`; one traversal primitive, and the `Glob` domain type is the more wand-shaped interface (a *pattern* describing a file set, not an imperative walk). Migration is mechanical: `FS.walk ./src` → `FS.glob! **.* ./src` (or `**` semantics per the glob spec — pin down whether `**` matches files without extensions before migrating).

**`String`'s regex family (`match?`, `capture`, `replace_re`, `replace_all_re`, `split_re`) — remove in favor of `Regex`.** One home for regex operations. Note the argument order already matches (`Regex.match? re s`), so migration is a rename: `String.match? r/fix/i` → `Regex.match? r/fix/i`. The README's own examples use `String.match?` — update them in the same commit (they'll be caught by examples-as-CI regardless). `String` keeps the non-regex text operations only.

The two piping styles (shell pipes inside `$()` vs. wand-level `|>` stdin threading) are both genuinely needed; the reference entry in §5.11 states when to use which.

### 5.7 Explicit keeps (each has a case against it; the case loses)

Contracts (small, honest, runtime-enforced; compounds with effects — but the keep has a deadline: contracts justify their keyword only if surfaced in `wand d`/`:t` output as declarative, tool-visible metadata; if they remain invisible sugar for `if`+raise, cut them). `handle` (position per §3.4, don't cut). `;` separators (sequencing side effects needs them). All twelve domain literal types — the temptation will come to trim "unused" ones like `CIDR`; resist it. They are the identity of the language and cost roughly one lexer rule each.

### 5.8 Post-removal audit: near-duplicates that stay, and the rules that justify them

Principle: **redundant *structure* is good (brace + indent, name + inferred effect — disagreement surfaces errors); redundant *constructs* are bad (two ways to say one thing fragments the language).** Sugar passes only if it is a thin, documented layer over exactly one primitive. Post-removal findings:

- **`|>` is overloaded**: function application vs. stdin-threading into `$()` (a distinct evaluator path — see the `process_run_stdin` effects). **Decided: keep, documented as a special form** — canonical reference entry in §5.11; effect rows must display honestly through both meanings.
- **Multi-equation definitions** are sugar over `match` with implicitness hazards worse than they first appear — see §5.10 for the tightened rules and implementation plan.
- **`$()` = `$?()` + raise; `try` = fixed handler over the raise machinery** (already literally true for `try` in `evaluator.ml`). **Decided: keep both `$()` and `$?()`** — the abstraction earns its place — but make the layering real in the implementation: one process primitive (`$?()`'s path), with `$()` defined as sugar over it, so there is a single semantics for interpolation, effects, and dry-run interception. State the layering in the reference so the blessed constructs (`try` for error capture, `handle` for interception) are explicit.
- **Tuples / named-field types / Maps** survive as three types for three purposes now that dot-access removal drew the boundary: tuples = anonymous values crossing a function boundary; named-field types = nominal domain data, checked fields; Maps = dynamic key sets, presence is a runtime question. Write this rule into the reference so `[x = 1, y = 2]` is never used as a cheap record.
- **Stdlib micro-duplication — resolved as removals**: `FS.walk` and `String`'s regex family are cut per §5.6.

### 5.9 The Option/Result rule

`Option 'a` and `Result 'a 'e` are near-duplicates (`Option` ≅ `Result 'a Unit`, and `to_result` is the admission). They both stay — under this rule, which is their entire justification and must be enforced across the stdlib:

> **`Option` means absence is an expected answer. `Result` means an operation was attempted and may have failed.** The test: *if the empty outcome occurred, did anything go wrong?* No → `Option` (there is no error to report, hence nothing to put in an `Error`). Yes → `Result`, and the `Error` payload must state the reason.
>
> **One-line version:** "Nothing there" is `None`. "It broke" is `Error why`. If you can't fill in the *why*, it didn't break.

Consequences:

1. **`Result 'a Unit` is banned in the stdlib** — an informationless error is the signature of a misfiled `Option`.
2. **Every `Error` payload answers "why"** (`String` minimum; structured error types where callers branch on cause). A `Result` whose only error is "wasn't there" is misfiled.
3. **`!`/`?` apply uniformly:** `get!`/`parse!` raise instead of wrapping (either wrapper); `?` predicates return bare `Bool`.
4. **One bridge, one direction:** `Option.to_result e` marks the point where the *caller's context* turns absence into failure. No `Result.to_option` — discarding the reason should look like the pattern-match it is.
5. **Pipelines chain within one type;** a mixed pipeline must contain a visible `to_result` — that line documents the absence-becomes-failure decision.

Stdlib classification under the rule: `Option` — `Map.get` (**currently `Result`: misfiled, migrate in Phase 0**), `List.find`/`head`/`tail`, `Env.get`, `JSON.field`. `Result` — `String.to_int` (a parse failed for a stateable reason), `JSON.parse`/`TOML.parse`/`CSV.read_file`/`FS.read_file`, `Regex.compile`, `FS.mtime`/`FS.size` (OS said no; errno is the why). Note the connection to §4.5: **decoders are the systematized `to_result` boundary** — where "field may be absent" (Option-world) becomes "this input is invalid" (Result-world). The rule explains why the decoder layer exists.

### 5.10 Multi-equation definitions: tightened rules

Multi-equation syntax (`let fib 0 = 0 / let fib 1 = 1 / let fib n = ...`) is sugar over a single `match` and stays — it reads beautifully and pattern-matching-at-the-definition is half of wand's ML identity. But source inspection shows the current semantics are more implicit than the syntax admits, in two layers:

- **Parser layer** (`collapse_multi_equation`, `parser.ml:839`): consecutive same-name `let`s collapse into one function whose body matches on fresh variables (`_p0`, `_p1`, ...).
- **Runner layer** (`merge_clause`, `runner.ml:309`): a *later* same-name, same-arity `let` merges into the existing function **and reorders arms** — specific patterns are placed before catch-alls, and within each group the new clause takes precedence. Evaluation order therefore does not match source order. Meanwhile a same-name `let` with *different* arity shadows instead of merging, and a zero-parameter `let` shadows too — so one syntax has three behaviors (merge, merge-with-reorder, shadow) selected by arity and pattern shape, invisible at the definition site.

**The rules (scripts and modules):**

1. **Contiguity.** Equations for a function must be consecutive. A `let f ...` appearing after any intervening binding, when `f` already exists in scope, is a **redefinition error** — never a silent merge, never a silent shadow. (Value `let`s of *distinct* names shadow as normal; only same-name function clauses are governed here.)
2. **Same arity, stated once.** All equations in a group must share arity and (if annotated) annotation; the annotation may appear only on the first equation. Arity mismatch inside a contiguous group is an error at the offending equation, not a shadow.
3. **Source order is evaluation order.** No reordering, ever, in files. The desugared `match` lists arms exactly as written. The current specific-before-catchall rewrite must not apply to scripts — a function's behavior must be readable top-to-bottom.
4. **Joint exhaustiveness.** The equation group must cover its domain, checked by the existing exhaustiveness machinery (`typechecker.ml:402+`) against the collapsed match. *Verify first:* since collapse produces an ordinary `Ast.Match`, the checker may already fire on it — in which case this rule is mostly error-message work (rule 6).
5. **No unreachable equations.** An equation whose pattern is subsumed by an earlier one is an error (the dual of rule 4): `let f _ = 0` followed by `let f 1 = 1` must be rejected, since under rule 3 the second equation can never fire. This check catches exactly the mistakes the old reordering silently "fixed."
6. **Errors speak in equations, not desugaring.** Diagnostics must never leak `_p0`/synthetic tuples: "equations for `fib` do not cover: negative `Int`" / "equation 3 of `fib` is unreachable — equation 2 already matches all `Int`," using the equations' source locations (the AST is located; thread the spans through `collapse_multi_equation`).

**REPL divergence, made explicit.** Incremental redefinition is the REPL's job, so the REPL keeps `merge_clause`-style updating as a *documented interactive convenience* — with two changes: after a merge, print the resulting function (`fib : Int -> Int, 3 equations`) or the arm order, so the reordering is visible rather than silent; and `:load`/`wand fmt`/script execution use strict file semantics (rules 1–5). The rule of thumb for the reference: *the REPL edits definitions; files declare them.*

**Implementation plan:**

- `parser.ml`: rules 1–2 — the equation-continuation loop (`:858+`, `:1087–1109`) already detects same-name continuations; add the error paths (known-name redefinition after a gap; arity mismatch within a group) and thread source spans into `collapse_multi_equation` for rule 6.
- `typechecker.ml`: rules 4–5 — confirm the collapsed match flows through exhaustiveness; add arm-subsumption (unreachability) checking beside it; rephrase both diagnostics per rule 6.
- `runner.ml`: rule 3 + REPL split — gate `merge_clause` on interactive mode; file-mode top-level items go through the parser-collapsed form only.
- `formatter.ml`: keep equation groups intact and aligned (equations are one definition; the formatter must never separate or reorder them).
- Tests: contiguity error, arity error, unreachable equation, exhaustiveness message phrasing, REPL merge still works and announces itself.

### 5.11 The `|>` reference entry (canonical text)

The following is written to be lifted into the language reference verbatim:

---

**The pipeline operator `|>` has two meanings, chosen by the syntactic shape of its right operand.** This is the one place in wand where an operator's semantics are decided at parse time rather than by the value it is applied to — it is a *special form*, and knowing which meaning applies requires looking only at the right-hand side, never at runtime values.

**Form 1 — application.** When the right operand is any ordinary expression, `x |> f` is exactly `f x`:

```
[1, 2, 3] |> List.map double |> List.filter (fn x -> x > 2)
$(git log --oneline) |> String.lines |> List.length
```

**Form 2 — stdin threading.** When the right operand is *literally* a `$()` or `$?()` form, `|>` threads the left value (a `String`) into the command's standard input:

```
$(git log --oneline) |> $(grep "fix") |> $(wc -l)
report |> $?(mail -s "nightly" ops@example.com)
```

Each stage's stdout becomes the next stage's stdin; `|>` associates left, so a chain reads as a shell pipeline. A `$?()` stage yields a `ShellResult` and therefore ends the threading chain (pipe its `.stdout` onward explicitly if needed).

**The distinction is syntactic, and that is the point.** `$()` is not a function value — `let g = $(grep foo)` *runs* `grep` immediately and binds its output `String`; it does not create a pipeable stage. Stdin threading happens only when `$()`/`$?()` appears directly to the right of `|>`. Consequently, which meaning you are reading is always decidable locally, from the text, without type information: *right side starts with `$` → process; otherwise → application.*

**Effects.** Both forms are honest under effect rows: threading into `$()` carries `{Shell, Raise}`, into `$?()` carries `{Shell}`, and application carries whatever the applied function carries.

**Choosing between wand pipes and shell pipes.** Both of these are idiomatic:

```
$(git log --oneline | grep fix | wc -l)          -- one shell pipeline
$(git log --oneline) |> $(grep fix) |> $(wc -l)  -- three wand stages
```

Use a **shell-internal pipe** when transcribing an existing one-liner, when the pipeline is an indivisible idiom, or when only the final output matters — it is one opaque `Shell` operation, and `--trace`/`--dry-run` see it as one command. Use **wand-level stages** when you want wand in the middle (filter with a typed function between commands), per-stage error handling via `$?()`, or stage-by-stage visibility in traces and dry-runs. Rule of thumb: *the boundary between shell and wand should sit where you want types, errors, or auditability to begin.*

---

---

## 6. Demo Portfolio — Showing the Strengths

Demos are how a zero-star language earns its first look, and each one doubles as an acceptance test for the feature it showcases. Rule for inclusion: every demo must have a **moment** — one visible beat where the audience gets it in under ten seconds. Each demo ships as a script in `examples/` (run by CI per Phase 0), a short terminal recording, and a paragraph in the README. Ordered by when they become possible.

### Available at Phase 0 (current language)

**D1 — The bash footgun museum.** Side-by-side, same task: a cleanup script referencing `${STAGING_DIR}/` with the variable unset. The bash version expands to `/` and runs; the wand version doesn't get that far — `Env.get` returns `Option String`, so the unhandled-`None` path is a compile-time hole, and paths are `Path`-typed, not spliced strings. **Moment:** the bash pane executes the disaster; the wand pane shows a type error naming the exact line. Strength: errors are values, absence is typed, stringly-typed state doesn't exist.

**D2 — Literals that know what they are.** REPL session: `let timeout = 30` passed to a function expecting `Duration` — type error suggesting `30s`. Then `2024-01-15 + 5min` mixing `Date` and `Duration`, `FS.glob` refusing a `Path` where a `Glob` belongs. **Moment:** `:t 1h30m` printing `Duration`. Strength: the twelve domain types, wand's most distinctive shipped feature, demonstrated in five REPL lines.

**D3 — The hole-driven AI loop.** A script written with `?` where the author (human or model) is unsure: `let parse_line l = ?`. `wand t` reports the hole's inferred type — `String -> Option (String, Duration)` — which is then handed to the AI as the spec to fill. **Moment:** the type system *answering a question* instead of only complaining. Strength: the Human-AI collaboration pitch, using an already-implemented feature nobody can see today because it's undocumented (§2.2).

### At Phase 1–2 (effects, manifest, dry-run, hermetic tests — the wedge)

**D4 — The signature that can't lie.** `wand d deploy` prints `Unit -> Result Unit ! {Shell, FS.Write}`. Then a `$(curl ...)` is buried three helpers deep; re-run `wand d` — the signature now shows `Net`, inferred, with no annotation anywhere. Then the manifest version: `uses {FS.Read, Shell}` at the top, and the buried `curl` becomes a compile error naming the call site. **Moment:** the signature updating itself to rat out the hidden network call. Strength: inferred effect rows + manifests; the supply-chain answer, one screen.

**D5 — Rehearse the deploy.** A real deploy script — build, rsync, config write, cache purge — run as `wand --dry-run deploy.wand`, printing `would run: rsync -a ...`, `would write: /etc/app/config.toml (312B)`, `would delete: /var/cache/app/*`, with reads executing so control flow is realistic. Then run it for real; the trace matches the rehearsal. **Moment:** the "would" list. This is the conference talk. Strength: the language-level guarantee no hand-rolled `$DRY` flag can offer, built on the effect runtime that already exists in `evaluator.ml`.

**D6 — Unit-test a deploy with the network unplugged.** A `Test` block wraps the deploy in `handle`, intercepting `process_run` with canned outputs, then asserts on the result *and* on which commands were attempted (`git push` attempted exactly once, nothing touched `prod` before tests passed). Run the suite on a plane. **Moment:** a passing test suite for a script whose real execution would push to production. Strength: `handle` positioned exactly per §3.4 — interception at boundaries, mocking as the flagship.

### At Phase 3–4 (decoders, Par)

**D7 — jq, typed.** Left pane: the traditional `kubectl get pods -o json | jq -r '...' | awk ...` pipeline. Right pane: a `Pod` named-field type, `Decode.of Pod`, and a typed pipeline ending in `List.filter (fn p -> p.restarts > 3)`. Introduce a typo in a field name on both sides: jq silently emits nulls; wand fails at the decode boundary with the field name. **Moment:** the silent-null vs. named-error contrast. Strength: decoders as the systematized `to_result` boundary (§5.9), domain types surviving the process boundary.

**D8 — Fan out without fear.** `Par.map 8 check_host hosts` over twenty hosts, three of which fail: results come back in order as `Result`s, failures collected not fatal, and a Ctrl-C mid-run triggers the `with`-bracket cleanup on every in-flight worker. Bash equivalent shown for contrast: `xargs -P` + `trap` + a temp-file for results. **Moment:** Ctrl-C followed by a clean "released: 8 locks" instead of orphaned processes. Strength: structured concurrency + brackets composing, per §4.6–4.7.

**D9 — The fork-elimination benchmark.** The same log-cruncher (parse, filter, count, summarize a 100MB log) written three ways — idiomatic bash (`grep | cut | sort | uniq -c` per field, `wc -l` in loops), Python, and wand using in-process `String.lines`/`List.filter`/`Regex` — timed with hyperfine on screen. Bash loses to its own fork overhead; wand lands at or ahead of Python with bash-like brevity. **Moment:** the hyperfine table, plus the process-count comparison (`strace -c -f` showing hundreds of `clone`/`execve` for bash, near-zero for wand). Strength: the §4.8 performance model made visible — and the honest framing that safety and speed point the same direction here, since moving work out of `$()` improves both. (Buildable at Phase 0 with today's stdlib; gets better after the interpreter fixes.)

### Delivery notes

D1–D3 and D9 cost nothing but writing and belong in the repo now — they are also the regression tests for Phase 0's documentation work (and D9 doubles as the tracking benchmark for the §4.8 interpreter fixes). D4–D6 are the wedge demos and should gate the Phase 2 release: if a demo's moment doesn't land in a terminal recording, the feature isn't finished. D5 is the anchor for the positioning post in Phase 4 ("AI writes it, human audits the manifest, CI typechecks it, dry-run rehearses it"). The talk arc, when the portfolio is complete, is D1 → D4 → D5: *the script that couldn't lie.*

---

## 7. Sequencing

**Phase 0 — Credibility and cuts (days):** execute the §5 removals first — `FS.cd`, bare auto-bound imports, map dot-access, positional/tuple forms on named-field types, `Types` demotion, **`FS.walk` and `String`'s regex family (§5.6)** — as outright cuts (no deprecation cycle needed with no external users; migrate stdlib/examples by `git grep` in the same commits). Deprecation cost is at its lifetime minimum, and several directly block later phases (`FS.cd` vs. `Par` and `--dry-run`; map dot-access vs. honest signatures). Then: fix both broken examples; examples-as-CI; **document the eight implemented-but-invisible features (§2.2)**; stdlib `!`/`?` audit incl. `FS.glob!` rename; **Option/Result audit per §5.9 incl. `Map.get` → `Option` migration**; **multi-equation tightening per §5.10** (contiguity/arity errors, no file-mode reordering, REPL split — the exhaustiveness/unreachability message work can trail into Phase 1); **lift the §5.11 `|>` entry into the reference**; **stand up the lint scaffold in `wand t`** (rule-ID registry, `--json`, the now-checkable rules: W-PRED1, W-OR1, W-NAME1, W-SHELL1); **write demos D1–D3 and D9** (§6 — they cost only writing and double as regression tests for the documentation work and the startup/perf benchmarks); **startup quick wins per §4.8** (memoize `find_stdlib_dir`; make `e`/`t`/`d` lazy — no eager nine-module prelude; hyperfine startup benchmark in `bench/` with the 2–3×-of-bash budget); README stdlib list sync (updating the `String.match?` examples the §5.6 removal breaks, and the REPL-preload claim vs. the actual nine-module prelude).

**Phase 1 — Effect rows (the keystone):** §4.1 typing + `Raise`; builtin `perform` coverage audit; `:t`/`wand d` display; **effect-dependent lints land with the rows** (W-BANG1/W-BANG2, W-OR2 — the `!` convention becomes checked in both directions).

**Phase 2 — The wedge:** manifests (§4.2); `--dry-run`/`--trace` (§4.3); hermetic test story (§4.4); formatter catch-up for `handle`/`try`/contracts/`$()`; **demos D4–D6 gate the release** (§6 — if the moment doesn't land in a recording, the feature isn't finished).

**Phase 3 — Day-to-day quality:** decoders + derivation (§4.5); brackets (§4.6); `else ()` sugar; **demo D7** (§6).

**Phase 0.5 — Interpreter performance (pulled out of Phase 4; depends on nothing):** the throughput drags D9 measured — assoc-list environments making variable lookup O(scope size), and process output read one byte at a time — plus the cross-invocation compile cache (`~/.cache/wand`, content-hash keyed). Lazy per-module deserialization stays in Phase 4, since it needs the embedding pipeline that ships with `wand compile`.

**Phase 4 — Reach:** `Par` (§4.7) with **demo D8**; static binary + `wand compile` + GitHub Action + stdlib embedding (§4.8); the positioning post anchored on D5: "AI writes it, human audits the manifest, CI typechecks it, dry-run rehearses it."

---

## 8. Verdict

The language core is real: a working HM checker with exhaustiveness, a self-hosted stdlib, domain literals no competitor has, and — quietly — a native-effects runtime that most "future work" lists would envy. The vision's distinctive promise (*signatures that can't lie about blast radius, scripts that rehearse before they run*) is not aspirational; its hardest half is running in `evaluator.ml` today. The gaps are the *visible* halves: effect rows in signatures, a `--dry-run` flag, and documentation that admits what the language can already do. Fix the two broken examples and cut the five implicitness features (§5) first — then build the type-level effect system before the stdlib gets any bigger. Everything else follows from those moves.

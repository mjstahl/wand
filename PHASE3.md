# Phase 3 — Day-to-day quality

**Status:** planned · **Goal:** the two boundaries a script spends its life on — acquiring things that must be released, and reading data that arrives untyped — each get one construct, and neither can fail silently.

```
with FS.temp_dir () as tmp ->
with FS.lock ./deploy.lock as _ ->
  let pods = JSON.decode Pod.decoder (JSON.parse! $(kubectl get pods -o json)) in
  ...
-- released innermost-first, on success, on raise, or on Ctrl-C
```

Phase 1 made a signature state what a function does; Phase 2 made that statement checkable and rehearsable. Both were about *honesty at the boundary*. This phase is about the two places a script still has to be careful by hand: cleanup, which today means remembering, and parsing shell or JSON output, which today means four regex scrapes and a `to_int` (see `examples/repo-status.wand`, ten lines, four scrapes).

Ordering is by what unblocks what. Brackets come first because two items already recorded as outstanding wait on them — `Par` cancellation and demo D8 — and because they are the smaller, better-understood construct. Decoders are the larger surface and the one with a real open design question, so they get the room that buys.

## The gap, measured

| | |
|---|---|
| Cleanup today | `FS.temp_file` returns a path and nothing removes it. There is no `defer`, no `trap`, no bracket. A script that raises between creating a temp file and deleting it leaks it. |
| `FS.cd` | **Already gone** — removed outright in the earlier cuts, so `in_dir` is a new capability rather than a replacement. The roadmap's framing of it as a fix is stale. |
| Untyped boundaries | `JSON` exposes `parse`, `get_string`, `get_int`, `get_object` … — dynamic poking, one field at a time, each returning a `Result` that most call sites unwrap with `!`. `CSV` and `TOML` are the same shape. Shell output has nothing at all. |
| Derivation | wand has **no type-directed elaboration of any kind.** Type definitions live in the typechecker as `Variants (name, params, ctors)`; no expression today takes a type as an argument. `Decode.of Commit` as literally written in the roadmap would be the first, and that is the largest single piece of new machinery in this phase. |
| `else ()` | **One occurrence in the entire corpus**, out of 83 `if`s (`examples/repo-status.wand:29`). The roadmap calls one-armed conditionals "constant" in scripting; wand's own code does not bear that out. |

## Decisions

| Question | Decision |
|---|---|
| Bracket syntax | `with <expr> as <pat> -> <body>`. No lexer work: `with` is already a keyword, and it is unambiguous here because the existing use is always preceded by `match`. |
| What `with` takes | A `Resource a` value — an `acquire`/`release` pair, built by `Resource.make`, so a resource is a *description* that can be named, passed and used twice rather than a thing already open. Users define their own in wand; the stdlib just ships the common ones. |
| Release order | Innermost first, by nesting. One construct, no `defer` list to reason about. |
| Derivation | **Derive at the type definition, not at the use site.** A single-constructor named-field `type Pod = Pod { name : String, restarts : Int }` also binds `Pod.decoder`. No new expression form, no type-in-argument-position, no elaboration pass — the decoder is an ordinary value with an ordinary type that `wand d` can print and `git grep` can find. This is the "one way to do things" answer and it costs a fraction of `Decode.of T`. |
| Decoder failure | `Result String a`, where the message names the field that failed and the path to it (`.items[3].metadata.name: expected String, got Int`). The named field *is* D7's moment; a decoder that fails without naming the field is not worth building. |
| Decoder effects | Pure. Decoding is a function from already-read data; reading it is `JSON.read_file`'s job and already carries `{FS.Read}`. |
| `else ()` sugar | **Add it, but last, and as `if c then e` with a `Unit` branch** — not a `when` statement form, which would be a second conditional construct for a solved problem. Given one occurrence in the corpus, it is a papercut, not a phase item; if anything above runs long, this is what gets cut. |

## Open question — settle before P3.1 lands

**What happens to a bracket when a handler abandons its continuation?**

An effect arm receives `resume` and may simply never call it — `evaluator.ml:381` builds the continuation as a value and hands it to the arm body, so an arm that ignores it drops `k` on the floor. OCaml then collects that continuation without running anything, which means **a `with` inside the abandoned region never releases.** A mock that swallows an effect would leak every resource the mocked code had open, silently, and mocking is the flagship.

Three candidates:

1. **Discontinue on drop** — when an arm returns without resuming, discontinue `k` so the abandoned region unwinds and its brackets release. Correct, and it makes "the arm didn't resume" a normal unwinding path rather than a leak. Cost: the arm's return value and the discontinued unwinding have to be reconciled.
2. **Track open brackets out of band** and release them when the handler frame exits, independent of the continuation.
3. **Document it** as a known leak. Rejected in advance — this is the failure mode Phase 2 spent its whole budget arguing against, and it would land in the same construct that argument was made for.

`try` is the easy sibling and is expected to be nearly free: it catches via `exnc`, so a raise unwinding through a `with` frame implemented with `Fun.protect` runs release before `try` ever sees the exception. That ordering wants a test, not a design.

## Working rules

1. Each tranche lands green.
2. **A construct that can leak is not done.** Every interaction — `try`, handler abandonment, `Par` — gets a test that observes the release, not just the happy path.
3. Every new construct gets a formatter rule in the same tranche that adds it, not a catch-up pass later.

---

## P3.1 — Resource brackets

`With of expr * pat * expr` in the AST; `Resource a` as an opaque stdlib type over an acquire/release pair; `Resource.make`. Release runs on success, on raise, and on abandonment per the open question above.

Stdlib starters: `FS.temp_file` (exists — wrap it), `FS.temp_dir`, `FS.lock`, `FS.in_dir`.

*Accept:* a script that raises inside a bracket still releases, observably; a handler that never resumes still releases; nesting releases innermost-first; the formatter has a rule for `with`.

## P3.2 — `Par` cancellation and D8

Ctrl-C cancels in-flight workers and runs their brackets. Now genuinely harder than when the roadmap wrote it down: an unwatched worker runs on its own domain, so cancellation has to reach a domain the signal handler is not on, and a watched worker's effects are mid-flight on the calling domain.

**D8** — fan out over twenty hosts, three failing, Ctrl-C mid-run, and a clean "released: 8 locks" instead of orphaned processes.

*Accept:* Ctrl-C during `Par.each` releases every in-flight worker's brackets, in both the watched and unwatched cases; D8 runs offline.

## P3.3 — Decoders

`Decoder a` abstract, with `int`, `string`, `bool`, `list`, `field`, `map2`, `and_then`, `one_of`, plus the domain literals (`duration`, `path`, `url`, `size`, `version`, `date`) decoding as themselves. Backends: `JSON.decode`, `TOML.decode`, `CSV.rows`, `Shell.lines`.

The existing `JSON.field`/`get_string` layer stays as the low-level API. No per-CLI typed wrappers — unbounded surface, instantly stale.

*Accept:* `examples/repo-status.wand`'s four scrapes become one decoder; a wrong field name fails with the field named, not with a null.

## P3.4 — Derivation

Every single-constructor named-field type also binds `T.decoder`. The type definition becomes the single source of truth and nothing is hand-written to go stale.

Kept separate from P3.3 and after it on purpose: decoders are useful without derivation, so if this tranche is harder than it looks, the phase still ships something.

*Accept:* a field added to the type appears in the decoder with no other edit; a type that is not single-constructor named-field gets no `decoder` binding and a clear error if one is named.

## P3.5 — D7 and `else ()`

**D7 — jq, typed.** `kubectl get pods -o json | jq -r … | awk …` against a `Pod` type and a typed pipeline. Introduce the same field-name typo on both sides: jq emits silent nulls, wand names the field. Runs offline against a canned fixture, like every other demo.

Then `else ()`, if there is room.

*Accept:* D7's contrast lands in a terminal recording.

---

## Risks

- **Abandonment is the one that bites.** It is invisible in every happy-path test, it only shows up under a mock, and mocking is what Phase 2 sold. Settle it before P3.1 lands, not after.
- **Cancellation is harder than it was.** The observer split bought parallel I/O; it also means there are now two shapes of in-flight worker to cancel. Budget accordingly, and be willing to ship D8 watched-only if the unwatched case fights.
- **The decoder API wants to grow.** Every combinator is defensible on its own and the total is a surface nobody can hold in their head. The listed set is the budget; additions need a call site that cannot be written without them.
- **Derivation is a research-shaped task in a delivery-shaped phase.** Deriving at the definition keeps it small; if it still isn't, cut it — P3.3 stands alone.

## Exit criteria

1. `with` releases on success, raise, abandonment and cancellation, each observed by a test.
2. `Par` workers release their brackets on Ctrl-C.
3. One decoder replaces the four scrapes in `examples/repo-status.wand`.
4. A single-constructor named-field type gets its decoder for free.
5. D7 and D8 land as runnable, offline demos.

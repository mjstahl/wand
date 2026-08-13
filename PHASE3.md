# Phase 3 — Day-to-day quality

**Status:** P3.1 done, P3.2 done but for D8 · **Goal:** the two boundaries a script spends its life on — acquiring things that must be released, and reading data that arrives untyped — each get one construct, and neither can fail silently.

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
| What `with` takes | A `Resource 'e 'a` value — an `acquire`/`release` pair, built by `Resource.make`, so a resource is a *description* that can be named, passed and used twice rather than a thing already open. Abstract, and open: see below. |
| Release order | Innermost first, by nesting. One construct, no `defer` list to reason about. |
| Derivation | **Derive at the type definition, not at the use site.** A single-constructor named-field `type Pod = Pod { name : String, restarts : Int }` also binds `Pod.decoder`. No new expression form, no type-in-argument-position, no elaboration pass — the decoder is an ordinary value with an ordinary type that `wand d` can print and `git grep` can find. This is the "one way to do things" answer and it costs a fraction of `Decode.of T`. |
| Decoder failure | `Result String a`, where the message names the field that failed and the path to it (`.items[3].metadata.name: expected String, got Int`). The named field *is* D7's moment; a decoder that fails without naming the field is not worth building. |
| Decoder effects | Pure. Decoding is a function from already-read data; reading it is `JSON.read_file`'s job and already carries `{FS.Read}`. |
| `else ()` sugar | **Add it, but last, and as `if c then e` with a `Unit` branch** — not a `when` statement form, which would be a second conditional construct for a solved problem. Given one occurrence in the corpus, it is a papercut, not a phase item; if anything above runs long, this is what gets cut. |

## Settled — what happens when a handler case abandons its continuation

**Resolved: the runtime unwinds the abandoned region.** A case that answers
without resuming now discontinues its continuation with a private
`Abandoned`, catches it, and returns its own value. Cleanup runs; nobody can
see the exception.

The measurements that decided it, on OCaml's own behaviour:

| Arm does | Cleanup runs? | Arm's value survives? |
|---|---|---|
| resumes (all 20 cases in the corpus) | yes | yes |
| drops the continuation | **no — not even after a full GC** | yes |
| discontinues | yes | no — unwinds past the case |
| **discontinues, catches** | **yes** | **yes** |

The last row is why this was cheaper than it looked. `discontinue` *returns*
to the case rather than transferring control away from it, so there is no
reconciling to do: discard what the unwinding produced and answer normally.

Two properties had to hold and both do. **Cleanup can perform effects of its
own** — releasing a lock deletes a file, which is `FS!write_file` performed
from inside a continuation being torn down — and it reaches the handlers that
were in scope when the resource was taken, because the unwinding happens
inside the case rather than after the handler frame is gone. That is the same
property the parallelism work turned on. And **`try` cannot catch the
unwind**: it re-raises what it does not recognise, so an abandoned region
cannot be caught halfway and resumed.

Rejected: tracking open resources out of band and releasing them when the
handler frame exits. Cleanup would run in the wrong dynamic context, reaching
whatever handler happened to be installed later; it reimplements unwinding by
hand; and innermost-first becomes an ordering to maintain rather than one you
get. Also rejected: documenting the leak, which is the failure mode the
effect work exists to prevent, in the construct that argument was made for.

**What it costs.** A case that stores its continuation and calls it after the
case's body returns no longer works — the continuation is torn down when the case ends.
That is deferred and multi-shot resumption, the raw material for coroutines
and schedulers. Nothing in the corpus does it, and giving it up is consistent
with no async/await, no futures, no channels; but the door closes quietly,
and this is where that is written down.

**Follow-up papercut.** A case that does not resume must still name a
continuation it will not use: `| Shell!run _ _ -> ...` is a parse error,
because the continuation binder must be an identifier. Now that not resuming
is a normal thing to write, `_` should be allowed there. Small parser change,
belongs with P3.1.

## Settled — what a resource is

**A resource carries its effects.** `Resource 'e 'a`, two parameters, and
`with` passes the row through:

```
Resource.make : (Unit -> 'a ! 'e) -> ('a -> Unit ! 'e) -> Resource 'e 'a
with          : Resource 'e 'a -> ('a -> 'b ! 'e) -> 'b ! 'e
```

The one-parameter version is the trap. If a resource hides what its acquire
and release do, then `with FS.lock ./deploy.lock as _ -> ...` contributes no
`FS.Write` to the enclosing signature, and a file can take a lock, delete it
again, and report a row that mentions neither. That is a hole in the property
the last two phases were built for, opened by the construct meant to make
cleanup trustworthy. The row flows through `with` exactly as it flows through
`List.map`.

**The representation is hidden; the constructor is not.** `Resource` is an
abstract builtin type, as `JSON` and `Regex` already are: the typechecker
knows it, no wand code can see inside it, and `with` is its only eliminator.
`Resource.make` is a thin wand wrapper over a builtin, like every other line
in `FS.wand`.

Making the type abstract but the constructor public is not a compromise, it
is two different questions. Nothing needs to inspect a resource, so the
representation stays closed. But two things need to *build* one:

- the four stdlib resources are wand code, and hiding `make` would force
  them into OCaml -- four more signatures hand-assigned rather than inferred,
  in the layer where drift matters most;
- a database transaction, a paused service, a mounted volume, a remote
  session. A closed set would cover the filesystem and leave every other
  resource to manual cleanup around a `try`, which is the footgun `with`
  exists to remove.

The type name appears in inferred output (`wand t` printing
`Resource {FS.Write} Path`) but nobody has to write it, because wand infers.

Rejected: dropping `Resource` and having `with` take the two functions
directly, `with (fn () -> ...) (fn x -> ...) as x -> ...`. It adds no type at
all, and the surface really would be just `with`. But a resource stops being
a value: it cannot be named, returned from a function, or built once and used
in three scripts, and the acquire/release pair -- which has to stay matched --
is no longer one thing that can be reviewed as a unit.

## Working rules

1. Each tranche lands green.
2. **A construct that can leak is not done.** Every interaction — `try`, handler abandonment, `Par` — gets a test that observes the release, not just the happy path.
3. Every new construct gets a formatter rule in the same tranche that adds it, not a catch-up pass later.

---

## P3.1 — Resource brackets

`With of expr * pat * expr` in the AST; `Resource` as an abstract builtin type over an acquire/release pair; `Resource.make` in wand over a builtin. Release runs on success, on raise, and on abandonment, the last of these already settled above.

Stdlib resources: `FS.temp_file` and `FS.temp_dir`.

Two of the four the roadmap listed are cut:

- **`FS.in_dir` — dropped.** `chdir` is per-*process* state. A bracket scopes
  it in time but not in space: two `Par` workers each entering one race on
  the same process-wide directory and one silently wins. That is the hazard
  `FS.cd` was removed for, and a nicer wrapper does not fix it — it makes it
  easier to reach for. Explicit path arguments already cover the need, as
  `FS.glob_in` shows.
- **`FS.lock` — deferred, not wrapped.** A lock's value is what happens
  abnormally: a killed process leaves the file behind, so a usable lock needs
  staleness detection — pid, host, timestamp — and a policy for breaking one.
  That is a design, not a bracket. A lock that silently wedges a queue after
  one crash is worse than no lock, so it waits for a real deploy story to
  shape it.

**Done.** `with r as p -> body`, `Resource 'e 'a` carrying its row,
`Resource.make`, `FS.temp_file` and `FS.temp_dir`, a formatter rule, and `_`
as a continuation binder. Covered by `test/wand/test_resource.wand` (15
cases) and `test/test_abandonment.ml`.

The raw `FS.temp_file` is gone rather than kept alongside the resource: it
created a file, returned the path, and nothing removed it. There were 22
leftovers in one machine's temp directory from test runs; a full suite run
now leaves none. Release tolerates the file already being gone, so a body
may rename it into place -- the one use the raw version had.

## P3.2 — `Par` cancellation and D8

**Cancellation is done; D8 is not.**

The tranche grew a piece the plan did not have: nothing was released when a
script was *stopped* at all, `Par` or no `Par`. `exit`, Ctrl-C and `kill`
each skipped every release. The rule now is one sentence, and it is the one
the reference states:

> A `with` always releases, however the script ends.

Only a process destroyed rather than stopped -- `kill -9` -- skips it, and
there is a test asserting that limit rather than leaving it to be
discovered.

How it works, since three attempts got it wrong: a signal records a request
and the **evaluator** raises it between steps, on its own stack. Raising
inside a signal handler or inside an effect handler abandons the body
instead of unwinding it, so the `with` frames never run. The request stands
until the process ends and each domain takes it once, recorded per domain,
because a worker runs its own evaluation loop. `Par`'s calling domain defers
its own interrupt across answering and joining its workers, and a release
runs to the end deferred the same way -- otherwise the interrupt lands in
the middle of the cleanup it triggered.

wand also owns its children now: it spawns commands itself and keeps the
pids, so stopping wand stops them. That is what makes stopping prompt --
signalling wand alone while four workers sat in a command went from 23.0s to
0.0s.

**D8** — fan out over twenty hosts, three failing, Ctrl-C mid-run, and a
clean "released" instead of orphaned processes. Everything it demonstrates
exists and is tested; what is left is writing the demo, offline, with the
`demos/assert.sh` moment check every other demo now has.

*Accept:* ~~Ctrl-C during `Par.each` releases every in-flight worker's brackets, in both the watched and unwatched cases~~ done, `test/test_signals.ml`; D8 runs offline.

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

## Picking this up

**Where things stand.** P3.1 and P3.2's cancellation are done and committed;
the tree is clean, 538 wand tests and the OCaml suite pass, seven demos pass,
every `.wand` file is a fixed point of `wand fmt`. Next is D8, then P3.3.

**Run everything with a timeout.** A `Par` script that hangs will sit there:
one cost six minutes of a session. `dune build @runtest` for the OCaml suite,
`wand test` for the wand suite, `bash demos/*/run.sh` for the demos -- each
demo asserts its own moment through `demos/assert.sh` and exits non-zero when
it stops making its point. That check has caught a silently broken demo twice.

**The trap that caught this session three times.** An exception raised inside
an effect handler -- a signal handler, a `handle` case, the runtime's own
handler for a command -- *abandons* the body rather than unwinding it, so no
`with` on it releases and no `try` sees it. The fix is always the same: send
it back through the continuation with `Effect.Deep.discontinue`, or record it
and raise from the evaluator's own stack. If a resource leaks or a body
silently stops, look here first.

**Things learned that are not in the code.**

- `Fun.protect` finalizers do not run for a dropped continuation, even after
  a full GC. `discontinue` runs them and returns to the case, which is what
  lets a case answer without resuming and still release.
- OCaml runs a signal handler at the next safe point, so neither a first nor
  a second Ctrl-C is seen while the process sits in a syscall. Killing our
  own children is what ends the wait; a second Ctrl-C cannot be relied on to
  preempt one.
- A forked child must not `Domain.spawn`. The `Par` signal test starts the
  real binary for this reason; the others fork.

**Known, deliberate, not blocking.**

- The formatter measures width from the indent an expression would continue
  at, not the column it starts at. Two lines in the corpus exceed the margin
  because of it: an unbreakable string literal, and an `if` inside a lambda
  inside a constructor field. Fixing the class means threading a start column
  through every emitter.
- `FS.lock` is deferred (staleness detection is a design, not a wrapper) and
  `FS.in_dir` is dropped (per-process `chdir` races under `Par`). Both are
  argued above.
- `ROADMAP.md` still says "arm" where everything else now says "case". Left
  alone: it is the original review, and rewriting its prose would misreport
  what it said.

## Risks

- ~~Abandonment~~ — settled and implemented ahead of the tranche, with tests that fail without the change.
- **Cancellation is harder than it was.** The observer split bought parallel I/O; it also means there are now two shapes of in-flight worker to cancel. Budget accordingly, and be willing to ship D8 watched-only if the unwatched case fights.
- **The decoder API wants to grow.** Every combinator is defensible on its own and the total is a surface nobody can hold in their head. The listed set is the budget; additions need a call site that cannot be written without them.
- **Derivation is a research-shaped task in a delivery-shaped phase.** Deriving at the definition keeps it small; if it still isn't, cut it — P3.3 stands alone.

## Exit criteria

1. ~~`with` releases on success, raise, abandonment and cancellation~~ **done**, and on `exit`, `kill` and Ctrl-C besides.
2. ~~`Par` workers release their brackets on Ctrl-C~~ **done**.
3. One decoder replaces the four scrapes in `examples/repo-status.wand`.
4. A single-constructor named-field type gets its decoder for free.
5. D7 and D8 land as runnable, offline demos.

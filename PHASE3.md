# Phase 3 — Day-to-day quality

**Status:** P3.1–P3.6 done · **Goal:** the two boundaries a script spends its life on — acquiring things that must be released, and reading data that arrives untyped — each get one construct, and neither can fail silently.

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

**Done**, cancellation and D8 both.

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

**D8** runs offline against a probe script that stands in for a health check.
Twenty hosts, eight at a time, three failing, interrupted halfway; then the
same fan-out in bash for contrast.

The contrast moved while the demo was being written. Signalling only the top
process makes bash look better than it is by accident -- it defers a trap
until the command it is waiting on returns, so the run finishes first and
cleans up properly. The interrupt now goes to the process group, which is
what Ctrl-C at a terminal does, and the difference that survives is the one
worth showing: wand releases eight leases, bash leaves eight behind, because
the workers holding them are separate processes and the parent's trap does
not run there.

*Accept:* ~~Ctrl-C during `Par.each` releases every in-flight worker's brackets, in both the watched and unwatched cases~~ done, `test/test_signals.ml`; ~~D8 runs offline~~ done, `demos/d8-fan-out/`.

## P3.3 — Decoders

**Done.** `Decoder a` abstract, the combinators, the domain literals, and
the backends. The existing `JSON.field`/`get_string` layer stays as the
low-level API, and there are no per-CLI typed wrappers.

**One shape, four backends.** A decoder reads from JSON's shape, and every
backend presents what it read in it — TOML converts, a CSV row becomes an
object keyed by the header, a line of output is a string. That is what makes
one combinator set serve all four rather than one set per format.

**Text is read, never written.** The rule that made a single set possible:
`Decode.int` accepts `4` and `"4"`, reading text exactly as `String.to_int`
would, so the same decoder serves a document and a command's output.
`Decode.string` does *not* accept `4` and stringify it — a `string` that
accepts anything is the scrape it exists to replace. One direction, stated.

**Three additions to the budget, each with a call site that needs it.**
`succeed` and `fail`, because `and_then` has nothing to return without them
and is otherwise unusable; `float`, because JSON has one and `int` cannot
read it. `map` is defined in wand over `and_then` and `succeed` rather than
as a builtin. `Shell` got two functions rather than one: `lines` for a
record per line, `decode` for a capture that is one value -- which is what
three of `repo-status`'s four scrapes are.

**Settled for P3.4: what an `Option` field decodes as.** `Decode.optional
name inner` reads a field as an `Option`. Absent is `None`, and so is a null,
which is absence written down. A field that is *there* and will not decode is
still a failure.

The version that writes itself is the wrong one:

    one_of [map Some (field name inner), succeed None]

It turns a renamed or retyped field into `None` as readily as a missing one --
the silent null this whole layer exists to replace, reintroduced by the
combinator meant to handle absence. Elm shipped that as `maybe` and spent
years telling people not to use it. Absence is therefore decided in the field
lookup, where it can be told apart from failure, rather than by catching a
failure after the fact.

This is what P3.4 needs: a derived decoder maps a field of type `Option T` to
`optional`, and every other field type to `field`.

**All twelve domain types now decode**, not the six the budget named:
`time`, `datetime`, `ipv4` and `cidr` are the same one-line shape as the
others, and `port` reads both `8080` and `"8080"` because a script writes
`:8080` but a document holds the bare number. Derivation would otherwise
have hit a wall on any type with an `IPv4` field -- an odd thing to have to
explain.

**What `!` siblings would have cost.** None were added: wand has no raise
expression, so each would be another OCaml builtin, and no call site needed
one. `repo-status` wants a default on failure, not a raise.

*Accept:* ~~`examples/repo-status.wand`'s four scrapes become one decoder~~ —
partly. The two hand-rolled parsers are gone and the empty-capture trap that
`count_lines` existed for now lives in `Shell.lines`, which is the real win.
But the honest finding is that repo-status reads four unrelated scalars out
of git, so there is no record to decode and the field-naming payoff does not
show there. ~~a wrong field name fails with the field named, not with a
null~~ done, and it is D7 that shows it.

## P3.4 — Derivation

**Done.** `T.decoder` for every single-constructor named-field type, derived
from the definition.

**Resolved at the use, not bound at the definition.** `Pod.decoder` is a
`Field` node the typechecker and evaluator each answer from the type's own
definition. Nothing is added to any environment, so a type costs nothing
until its decoder is named -- and, the part that mattered, the decoders of
the types a field mentions are looked up **when that field is decoded**
rather than when the decoder is built. That is the whole answer to the
recursion risk this tranche was sized by: `type Node (label : String,
children : List Node)` works, and building eagerly it could not have.

**`Option` is the field that may be absent**, decided in P3.3 and used here
unchanged: an `Option` field maps to `optional`, every other field to
`field`. Nothing else distinguishes them, and the type already said which
was which.

**Two pre-existing bugs surfaced on the way**, both in the parser and both
fixed:

- a named field's type was parsed as an atom, so `children : List Node` did
  not parse and needed parentheses -- exactly the shape derivation is for.
  Named fields now take an application; positional ones stay atoms, since
  `Pair Int Int` is two fields rather than one applied to the other. The
  formatter follows, so the canonical form is the bare one.
- a constructor with no payload took the *next line's* type name as its
  payload, so `type Color = Red | Green` followed by a line starting with an
  uppercase name silently became `Green <that>`. The newline check existed
  for the second payload atom onward but not the first.

*Accept:* ~~a field added to the type appears in the decoder with no other
edit~~ done; ~~a type that is not single-constructor named-field gets no
`decoder` binding and a clear error if one is named~~ done -- five shapes,
each saying which one it is (`it has more than one constructor`, `its payload
has no field names`, `field 'm' cannot be read: ...`).

A note on the vocabulary, since two things sound alike: the language has no
positional *construction* of a named-field type -- `Point (1, 2)` where
`Point` declares `x` and `y` was cut in the roadmap's §5.4. A positional
*constructor* is a different thing and is alive and well: `type Shape =
Circle Float | Square Float` is ordinary. What derivation refuses is the
second -- a payload with no field names has nothing for a document to be
read by.

### What derivation does not do, and what each piece would cost

What shipped covers the flat record whose keys are its field names. Not
covered: **generics**, **encoders**, **renamed keys**, **nested paths**, and
**tagged unions** (`{"kind": "circle", ...}` into a multi-constructor type).

**Do not reach for the eager version.** Building the decoder as a value when
the type definition is processed is the obvious first move -- that is where
the fields are -- and it is the expensive one. It creates four problems in
order, none of which the lazy form has:

| | |
|---|---|
| Recursion | Building `Node.decoder` needs `Node.decoder`. Tie the knot with a `lazy` and force inside. An afternoon. |
| Mutual recursion | A per-type knot does not help `Dir`/`File`; it needs a fixpoint over the whole recursive group, so first the group has to be *found* -- a dependency graph over type definitions and its strongly-connected components. |
| Forward references | `type Dir (files : List File)` before `File` exists. Eagerly this needs topological ordering, or deferring construction -- and deferring construction *is* the lazy design, reached the expensive way. |
| Imports | An eagerly-built decoder is a value that has to cross the module boundary beside its type. Lazily the type crossing is enough: the far side derives from the definition that already travelled. |

So the shipped shape is not a cheap approximation of the eager one. It is the
one that does not manufacture its own work.

**Generics is done**, and it was additive as predicted: `derivable_typedef`
learned that a type variable is fine when the type declares it, the `Field`
case builds one arrow per parameter, and the lazy resolution was not in the
way. `Box.decoder : Decoder 'a -> Decoder (Box 'a)`, and
`Box.encoder : ('a -> JSON) -> Box 'a -> JSON`.

The encoder had to stop being purely value-directed to do it. A supplied
encoder has to be the one that runs -- accepting one and then ignoring it in
favour of a structural walk would answer with something other than what it
was asked for -- so encoding now walks the field types where a type variable
is involved and falls through to the value everywhere else.

Two pre-existing bugs came out of it, both about applied types being dropped:

- `Box(v = 3)` was typed `Box`, not `Box Int`. Named construction converted
  each field's type expression on its own, so every field got an unrelated
  variable and the result was never applied; positional construction
  (`Box 3`) had been right all along. It now builds from the constructor's
  own scheme.
- dot access then had to see through an applied type -- `p.v` on a `Box Int`
  is an `Int` -- which it could not, because it only matched a bare `TName`.
  Fixing the first without the second broke every test in the corpus at once,
  which is how the second was found.

**`Decode.of T` stays rejected**, for the reason P3.4 was scoped this way in
the first place: an expression taking a type as an argument is the language's
first type-in-argument-position, needing an AST node, parser support, a
typechecker rule for a type name in expression position, and answers for
`Decode.of (List Pod)` and `Decode.of` on a type variable. That is
elaboration -- a compile-time expansion pass or a runtime type
representation. `Pod.decoder` needs none of it and `git grep` finds it.

**Renaming, nested paths and tagged unions each want their own decision**,
not a ride inside this one. Renaming implies an annotation syntax on fields,
which the language does not have and should not grow casually. Tagged unions
imply a convention about which field is the tag. Both are worth doing only
against a call site that cannot be written with a hand-written decoder beside
the derived one -- which today it can, since the two mix freely.

**The two directions are not equally pleasant to write by hand.** Reading a
renamed or nested field composes; writing one back does not:

    -- reading
    Decode.map2 (fn n r -> Pod (name = n, restarts = r))
      (Decode.field "metadata" (Decode.field "podName" Decode.string))
      (Decode.field "status" (Decode.field "restartCount" Decode.int))

    -- writing
    JSON.of_map
      (Map.from_list
        [("podName", JSON.of_string n), ("restartCount", JSON.of_int r)])

This is not an argument for an `Encode` module: encoding cannot fail, so a
combinator set would be a second name for `JSON.of_int` and the rest, and
that is the trade P3.6 already refused. It is the same gap as the three
above, seen from the other side -- derivation covers the shape that matches
the type, and anything else is hand-written. It only bites where those three
bite, which is why nothing in the corpus has hit it yet.

**There was no ergonomic gap.** The clumsiness was a mistake of mine, and
the correction is worth keeping because the reasoning that produced it is
the kind that repeats.

`JSON.of_map` takes a `Map`, and the objection was that building one meant
`JSON.of_map (Map.from_list [("content-type", ...)])` -- a detour, because a
map literal seemed to allow only identifier keys. It does not: a key may be
written quoted, in literals and in patterns both.

    ["content-type" = JSON.of_string "json", "@type" = JSON.of_int 1]

So `of_map` was fine, and it is the inverse of `get_object`, which already
gives back a `Map`. It stays. `JSON.of_object`, briefly added and taking a
list of pairs, is gone: it was less pleasant to write and no more expressive.

**Why nobody had noticed the quoted form worked:** `wand fmt` printed every
map key bare, so `["content-type" = 1]` came back as `[content-type = 1]`,
which does not lex. Any file using one was destroyed by formatting it, and
every `.wand` file here is formatted. The formatter now quotes a key that is
not an identifier -- quoting is always correct, and bare is only an economy
for the keys that can afford it.

**One real bug survived the correction.** `of_map` wrote a repeated key
twice -- `{"a":1,"a":9}` -- which different parsers read differently. It now
writes the first, which is the one `Map.get` finds and the one wand would
read back. Note where the duplicate comes from, though: a `Map` itself holds
both. `[a = 1, a = 9]` has size 2 and an entry nothing can reach. That is a
`Map` question, not a JSON one, and it is still open.

## P3.5 — D7 and `else ()`

**D7 is done**; `else ()` is what remains of the phase.

The demo asks which pods are restarting too often, of a canned
`kubectl get pods -o json`, through jq and awk and through four types whose
decoders are derived. Both report the same three pods.

**The contrast grew a second half while it was being written.** Getting the
field name wrong turns out to have two distinct shapes, and wand answers them
differently:

- *typing it wrong* -- the field is named in a type, so the code that reads
  it stops compiling, and nothing runs;
- *the cluster renaming it* -- the code is consistent with itself and only
  the document disagrees, so it runs and fails at the boundary where the
  document is read: `.items[0].status.containerStatuses[0].restartCount: no
  such field`.

Only the second is the decode boundary the tranche was written for. The first
is the type system catching it earlier still, and showing both is what says
these are two guards rather than one.

**jq's answer to both is `0 pods reported, exit 0`.** Not an error, not an
empty result that looks wrong -- a clean bill of health, while `db-01` sits
in CrashLoopBackOff with twelve restarts in the document it just read. The
silence is counted rather than shown, because there is nothing to show.

*Accept:* ~~D7's contrast lands in a terminal recording~~ done,
`demos/d7-jq-typed/`, offline against a fixture and asserted through four
`moment` checks.

**`else ()` is done too**, as the decision said: `if c then e` with a `Unit`
branch, no `when` form, one conditional rather than two. The corpus had three
occurrences by the end rather than the one measured at the start -- the two
`FS` resource releases picked it up along the way -- and all three now read
without the empty branch.

Two small things came with it. A missing `else` is a bare `Unit` in the AST
where a written one carries a location, which is enough to tell them apart
and say *why* the branch must be `Unit`:

    an `if` with no `else` does nothing when the condition is false,
      so its branch must be Unit -- this one is Int

And `wand fmt` writes an empty `else` out of existence, so `if c then f ()
else ()` comes back one-armed. The formatter rule ships with the construct,
as the working rules require.

## P3.6 — Dictionaries, nulls, and the other direction (done)

Three gaps found by asking what a decoder still cannot read. The first two
are P3.3's combinator set being one short in each direction; the third is a
whole direction missing. All three have call sites that cannot be written
without them, which is the bar the budget sets.

**`Decode.dict : Decoder 'a -> Decoder (Map 'a)`.** A JSON object whose keys
are data rather than field names -- a label map, per-host counts, anything
keyed by a name the program does not know in advance -- cannot be decoded at
all today, by derivation or by hand. That is why a `Map` field is refused,
and the refusal is currently the truth about the whole layer rather than
about derivation. Keys become the `Map`'s keys and every value is read with
the same decoder; a failure names the key it was under, as a field would.
This also makes a `Map 'a` field derivable, which removes one of the five
rejection messages.

**`Decode.nullable : Decoder 'a -> Decoder (Option 'a)`.** `optional` is
field-level on purpose -- absence is a property of a lookup, and deciding it
there is what tells a missing field from a wrong one. But a *value* may be
null where no field lookup is involved: `[1, null, 3]` into
`List (Option Int)` cannot be expressed. `nullable` is the value-level
sibling, and the two are not redundant: `optional` answers "the field may not
be there", `nullable` answers "the value may be null". A field of type
`Option T` keeps mapping to `optional`, which already treats a null as
absence, so nothing about derivation changes.

**Encoders.** Nothing writes a value back out. A script that reads a config,
changes one thing and writes it again -- which is most of what a script does
with a config -- has a typed read and an untyped write, and the asymmetry is
the sharpest practical limit in the layer.

**Settled: an encoder is a function `'a -> JSON`.** No `Encoder` type, no
`Encode` module. Encoding cannot fail, so there is no error to thread and no
path to carry -- the two things that earn `Decoder` its abstraction. `JSON`
and its constructors already exist, so `Pod.encoder : Pod -> JSON` composes
with what is there (`JSON.stringify (Pod.encoder p)`,
`JSON.of_list (List.map Pod.encoder ps)`), and a second set of combinators
beside `Decode`'s would be a second name for `JSON.of_int`. So the only piece
worth building was derivation, and this was the afternoon rather than the
tranche.

It encodes from the *value* rather than from the type, since a value carries
its own tag and cannot disagree with itself. A field holding `None` is left
out rather than written as null: both read back as `None`, and a config is
tidier without the empty keys.

**Done**, all three. `Decode.dict` also made a `Map` field derivable, which
removed one of P3.4's five rejection messages -- the refusal was always a
statement about the combinator set rather than about derivation, and now
there is nothing to refuse.

*Accept:* ~~an object with dynamic keys decodes into a `Map`, naming the key
that failed~~ done; ~~`[1, null, 3]` decodes as `List (Option Int)`~~ done;
~~a config read, changed and written back comes out as the same document it
went in as, but for the change~~ done, and pinned as a test rather than a
demo.

---

## Picking this up

**Where things stand. The phase is done** -- P3.1 through P3.6, and all six
exit criteria. The tree is clean, 599 wand tests and the OCaml suite pass,
eight demos pass (D9 is excluded from CI for its own reasons), and every
`.wand` file is a fixed point of `wand fmt`.

What is left is not in this phase. Under P3.4: renaming keys, nested paths,
and tagged unions, each wanting its own decision rather than a ride inside
derivation. Everything else is the roadmap's later phases -- Phase 0.5's
interpreter performance and Phase 4's distribution.

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
- Derivation covers the flat record, including generic ones. What is missing,
  what the eager alternative would cost, and why generics is the piece to
  pick up first are recorded under P3.4. Three of those gaps -- dictionaries,
  null values, and encoders -- are now P3.6 rather than open questions.
  Eager construction buys no decoding power at all: it is the same feature
  built the expensive way, and that is worth remembering before someone
  reaches for it.
- `ROADMAP.md` still says "arm" where everything else now says "case". Left
  alone: it is the original review, and rewriting its prose would misreport
  what it said.

## Risks

- ~~Abandonment~~ — settled and implemented ahead of the tranche, with tests that fail without the change.
- ~~**Cancellation is harder than it was.**~~ Both shapes cancel; D8 shipped covering them, and the unwatched case did not fight.
- **The decoder API wants to grow.** Every combinator is defensible on its own and the total is a surface nobody can hold in their head. The listed set is the budget; additions need a call site that cannot be written without them.
- ~~**Derivation is a research-shaped task in a delivery-shaped phase.**~~ It stayed small, and for the reason predicted: deriving at the definition, and resolving when a field is read rather than when the decoder is built. Generics landed on top without disturbing it.

## Exit criteria

1. ~~`with` releases on success, raise, abandonment and cancellation~~ **done**, and on `exit`, `kill` and Ctrl-C besides.
2. ~~`Par` workers release their brackets on Ctrl-C~~ **done**, and D8 shows it.
3. ~~One decoder replaces the four scrapes in `examples/repo-status.wand`~~ **done**, with the caveat recorded under P3.3.
4. ~~A single-constructor named-field type gets its decoder for free~~ **done**.
5. ~~D7 and D8 land as runnable, offline demos~~ **done**.
6. ~~An object with dynamic keys, a null value, and the write direction all have an answer (P3.6)~~ **done**.

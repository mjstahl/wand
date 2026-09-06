# Running the examples on a tour site

A language tour is read in a browser, and a reader who cannot change an
example is reading a screenshot. This document is the design record for
making every example on the tour executable: what decides whether an example
runs or is rehearsed, what each answer looks like, and what has to move in
the tree to allow it. It is a record of decisions and their reasons, written
before the code. It is not a specification.

- [Every example is checked; not every example is run](#every-example-is-checked-not-every-example-is-run)
- [The mode is decided by the effects, not by the manifest](#the-mode-is-decided-by-the-effects-not-by-the-manifest)
- [Which labels rehearse](#which-labels-rehearse)
- [The four answers](#the-four-answers)
- [What the page calls](#what-the-page-calls)
- [The reader is told the mode before pressing Run](#the-reader-is-told-the-mode-before-pressing-run)
- [Where the code runs](#where-the-code-runs)
- [Keeping the page and the compiler in step](#keeping-the-page-and-the-compiler-in-step)
- [Left out on purpose](#left-out-on-purpose)
- [Order](#order)

## Every example is checked; not every example is run

The tour's subject is the check. wand's claim is that a script cannot do what
it did not declare, and the way to show that claim is to let the reader break
it: delete the `uses` line, add a call the manifest does not permit, press
Run, read the error. That interaction needs the typechecker and nothing else.
It touches no file and starts no process.

So the pipeline has two stages and the first one never runs code:

1. `Runner.typecheck_source` — lex, parse, infer, check the manifest, lint.
   A failure ends here and the diagnostic is the answer.
2. Evaluation, in one of two modes, decided by what stage 1 inferred.

Splitting it this way means the most valuable example on the site is also the
cheapest one to serve.

## The mode is decided by the effects, not by the manifest

The obvious rule is "an example with a `uses` line is effectful". It is
wrong, because the manifest is not required and its absence proves nothing.
Four files, and what `wand t` says about each today:

```ocaml
let x = 1 + 1                        -- no manifest, no effects.  Int
```
```ocaml
import IO                            -- no manifest, performs IO.
IO.println "hi"                      -- warning V-USES2: it could declare "uses {IO}"
```
```ocaml
uses {FS.Write, Shell(git)}          -- manifest wider than the code.
import FS                            -- warning A-USES1: it could be "uses {FS.Write}"
FS.write_file! /tmp/x.txt "hi"
```
```ocaml
uses {IO}                            -- manifest narrower than the code.
import FS                            -- error: performs FS.Write, which the
FS.write_file! /tmp/x.txt "hi"       -- manifest does not allow
```

Only the last one fails. A missing manifest is a warning, so a file that
writes to disk and says nothing about it typechecks and runs. A tour that
keyed on the `uses` line would run that file for real.

The classifier is therefore the inferred set, which the typechecker already
computes for the linter:

```ocaml
(* typechecker.ml *)
let last_file_effects : Effect_set.EffSet.t ref = ref Effect_set.EffSet.empty
```

`check_manifest` fills it on every file, manifest or not. Two properties of
it matter here, and both are the conservative direction:

- `Raise` is excluded. `manifest_relevant` removes it, because control flow
  is not a thing done to the machine. The tour does not want it either.
- It is the union over *every binding*, not over what running the file
  performs. An example that defines a function which shells out, and never
  calls it, counts as a shell example. It is rehearsed. This is right: the
  tour is teaching what the manifest measures, and the manifest measures the
  same thing.

`source_check` does not carry the set yet. Add `sc_effects : Effect_set.EffSet.t`
to it rather than reading the ref from outside — the page needs the check and
the classification in one answer, and a ref read at the wrong moment is a
mode chosen from the previous example.

## Which labels rehearse

Nine labels, split three ways.

| Labels | Mode | Why |
|---|---|---|
| none, `IO`, `FS.Read`, `Random` | run | The answer is the point, and nothing outside the page changes. |
| `Shell`, `FS.Write`, `Env`, `Clock` | rehearse | Each one changes something, or waits. |
| `Proc` | refuse | Ends the process. In a page, the process is the runtime. |

```ocaml
let rehearsed = Effect_set.EffSet.of_list
  Effect_set.[Shell; FsWrite; Env; Clock]

let mode_for eff =
  if Effect_set.EffSet.mem Effect_set.Proc eff then `Refuse
  else if Effect_set.EffSet.disjoint eff rehearsed then `Normal
  else `DryRun
```

The mode is per example and the label set is coarser than the operation set.
`Env` covers `Env.get` and `Env.set` alike, and `Clock` covers `Clock.now`
and `Clock.sleep`. So an example that only reads `HOME` is rehearsed.

That costs less than it looks like, because `DryRun` withholds per operation,
not per example:

```ocaml
(* runner.ml *)
let withhold = mode = DryRun && is_mutation name in
```

`is_mutation` names eighteen operations. Everything else in a rehearsed
example is carried out for real, so `Env.get` in a rehearsal answers with the
value and only `Env.set` prints `would set`. A reader loses nothing but the
word on the button.

`Random` runs, with the seed pinned, so an example answers the same on two
readings and the text under it stays true. `FS.Read` runs against the seeded
in-memory filesystem described below; `FS.read_file "config.toml"` returning
`Ok "..."` is how the tour teaches `Result`, and a rehearsal that withheld it
would teach nothing.

## The four answers

```ocaml
type outcome =
  | Rejected  of Diag.t
  | Refused   of string                    (* Proc: not on this page *)
  | Ran       of { output : string; value : string; typ : string }
  | Rehearsed of { output : string; plan : string list }
```

**Ran** shows what the script printed, then its final value and type. The
REPL's rule for the last line already handles the awkward case and is reused
rather than rewritten: a `Unit` from an expression that performed something
is shown as nothing, because `IO.println "hi"` has already put `hi` on the
screen and `() : Unit` under it is noise. `Typechecker.expr_item_effects`
answers that question.

**Rehearsed** shows the plan — the `would ...` lines, in order:

```
would write: /tmp/x.txt (2 bytes)
```

Show it beside the manifest, not below the code. The two are the same
statement: one is what the file promised, the other is what it turned out to
do. A tour reader who sees them together learns the language's argument in
one glance, and a reader who then edits the manifest to be narrower gets
`Rejected` on the next press.

**Rejected** shows the diagnostic with its `should be` line, which the
compiler already writes:

```
Error: type error: 1:1: performs FS.Write, which the manifest does not allow.
       The manifest should be:  "uses {FS.Write, IO}"
```

Warnings are not a fourth answer. `V-USES2` and `A-USES1` are shown alongside
whichever of the three came back, in the margin, the way an editor shows
them. A warning that stopped the example would misreport the language.

## What the page calls

One entry point, so the page cannot check with one set of rules and run with
another:

```ocaml
val Tour.run : path:string -> string -> outcome
```

`path` is a name, not a location. It decides how imports resolve and it is
what the diagnostic prints; it never reaches a disk.

## The reader is told the mode before pressing Run

The button says `Run` or `Rehearse`, and it decides which before the reader
presses it — the typecheck that classifies the example is cheap enough to run
on every keystroke, which the editor tier wants anyway for diagnostics. Next
to the button sit the inferred labels.

This is worth more than it costs. A reader who deletes `Shell.run` and
watches the button change from `Rehearse` to `Run` has learned what the
effect system does without reading a paragraph about it.

## Where the code runs

In the browser, compiled with js_of_ocaml. There is no execution server, so
there is nothing to sandbox, rate-limit or keep patched, and an example
answers with no round trip.

Three things in `lib/` do not compile that way, and each needs a decision
rather than a flag:

- `linenoise` — a terminal line editor, reached only by `repl.ml`. Split the
  browser build's module set so neither is in it.
- `ext/clock.c` — a C stub. Supply a JS implementation of the same primitive.
- `Unix` — 90 call sites in `runner.ml`, 17 in `evaluator.ml`, and a few in
  `compile_cache.ml` and `module_types.ml`.

Do not condition those on the target. Put the outside world behind a record
the evaluator holds, and pass a different one per target:

```ocaml
type backend = {
  read_file  : string -> (string, string) result;
  write_file : string -> string -> (unit, string) result;
  run        : string -> string list -> exit_status * string;
  now        : unit -> float;
  entropy    : int -> bytes;
}
```

Native passes the Unix one. The page passes an in-memory filesystem seeded
per example, a shell that answers from a table the example declares, a fixed
clock and a seeded PRNG. `random_tag ()` reads `/dev/urandom` for the
substitute names a rehearsal hands back, and is the reason `entropy` is on
the record.

The seam pays for itself twice: it also makes `evaluator.ml` testable without
a filesystem.

## Keeping the page and the compiler in step

A tour that has drifted from the compiler is worse than no tour, and drift is
silent — the page keeps serving the answer it was built with.

`tools/check_docs.wand` already gates that every stdlib function has a `>>`
example and that every example produces what it says. The tour gets the same
gate, in CI, using the **native** binary: for each example, run it in the
mode the classifier picked and compare against what the page ships. The
examples live as `.wand` files under the site's tree, so `check_fmt` covers
them too and the tour is formatted the way the formatter formats.

Every stage of the tour is then a file that the compiler has agreed with.

## Left out on purpose

- **Server-side execution.** It buys real network access and real
  subprocesses. Neither is worth an isolation boundary and an ops bill for a
  page whose subject is a static check.
- **State shared between examples.** Each example is a whole file with its
  own manifest, because the manifest is a property of a file, and a tour step
  that inherited bindings from the step above would be teaching a unit the
  language does not have.
- **`Proc`.** Refused, not rehearsed. A rehearsal of "ends the process" that
  continued would be a lie about the one label whose description says nothing
  catches it.
- **Network examples.** Blocked until `HTTP` and `Net` land; see
  `http-design.md`. Today they would read as `Shell(curl)` and rehearse,
  which teaches the wrong thing.

## Order

1. `sc_effects` on `source_check`, and `Tour.run` over it. Native only, no
   page. The classifier is testable at this point.
2. The `backend` record, and `runner.ml`/`evaluator.ml` moved onto it.
3. The js_of_ocaml build: module split, clock stub, browser backend.
4. The page: editor, badge, three answers.
5. The CI gate over the example files.

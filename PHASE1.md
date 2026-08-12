# Phase 1 — Effect rows

**Status:** planned · **Goal:** a signature states what a function does to the machine, inferred, with nothing written by hand.

```
$ wand d deploy
deploy : Unit -> Result String Unit ! {Shell, FS.Write}
```

This is the keystone: `--dry-run`, manifests, and the `!`-convention lints are all downstream of it, and the runtime half already exists — every shell execution and mutating FS builtin performs an interceptable effect. What is missing is the visible half.

## What the code actually looks like

Measured, not assumed:

| | |
|---|---|
| `TFun` sites in the builtin type tables | **161** — pure data, rewriting them *is* the seeding work |
| `TFun` sites in inference logic | **29** |
| match arms in `infer` | 49 |
| `infer`'s signature today | `tenv -> env -> expr -> typ` (`typechecker.ml:620`) |
| `try` typing today | `TResult (TString, infer tenv env e)` (`:890`) |
| `handle` typing today | `typechecker.ml:862` |

So the retrofit is one function plus a data table, not a rewrite. The stdlib is 15 modules and inference has no annotations to lean on, which is exactly why it should happen now.

## Decisions

| Question | Decision |
|---|---|
| Where does the effect live? | **On the arrow: `TFun of typ * typ * row`.** Attaching effects to result types breaks as soon as a type variable could unify with either a pure or an effectful result. Arrow-carried latent effects are what Koka and Frank do. |
| What does `infer` return? | **`typ * row`** — the effect of *evaluating* the expression, distinct from the arrow's row, which is the effect of *calling* it. A mutable accumulator would be smaller and far harder to keep correct across generalization. |
| Row polymorphism? | **Required, not optional.** `List.map` is written in wand, so its effect signature is inferred; without a row variable it collapses to one fixed set and poisons every caller. |
| Generalization | **Quantifies row variables too**, or the polymorphism above dies at the first `let`. |
| Lattice | Fixed and coarse: `Shell`, `FS.Read`, `FS.Write`, `Net`, `Env`, `Proc`, `Raise`. Not user-extensible in v1. |
| Annotations | Optional everywhere. Effects are displayed, never required. |

## Working rules

1. Each tranche lands green: `dune build && dune test` before the next starts.
2. **P1.2 is behavior-preserving by construction.** It threads rows through inference with every row inferred empty, so it can be reviewed as plumbing. Nothing observable changes until P1.3 seeds the builtins.
3. The stdlib is the acceptance test. 15 modules of unannotated wand: if `FS.read_file` does not come out `{FS.Read}`, inference is wrong and it will be obvious.

---

## P1.1 — Rows and their unification

New `lib/effect_row.ml`, depending on nothing:

- `eff` (the seven labels), `EffSet`
- `row = Row of EffSet.t * rowvar option` — closed when the tail is `None`, open otherwise
- `rowvar = { rid : int; mutable rdef : row option }`, mirroring the existing `tv`
- `repr_row`, `fresh_row`, `unify_row`, `string_of_row`, occurs check

Unification is the usual three cases: closed against closed requires equal sets; open against closed binds the variable to the difference; open against open binds both to a shared fresh tail.

*Accept:* `test_effect_row.ml` covers each case plus the occurs check. No other file changes.

## P1.2 — Thread rows through inference

`TFun` gains its third field; `infer` returns `typ * row`. Most of the 49 arms just propagate. The decisions are in:

- **`App`** — `eff(f) ∪ eff(x) ∪ latent(f)`; unify the callee's arrow row with a fresh row
- **`Fn`** — the body's row becomes the arrow's latent row; the lambda itself evaluates purely
- **`Let` / recursion** — the placeholder unified before a recursive body is inferred needs a fresh *row* variable too, or recursion over effectful functions is silently over- or under-approximated
- **`Match` / `If`** — union across branches
- **`Try`** (`:890`) and **`Handle`** (`:862`) — left as pass-through here, discharged in P1.4

*Accept:* the whole suite passes unchanged, with every inferred row empty. Purely mechanical from the outside.

## P1.3 — Seed the builtins

The 161 table entries. Effectful ones cluster: `process_*` → `{Shell}`, `fs_*` → `{FS.Read}` or `{FS.Write}`, `io_*` → `{Proc}`, `env_*` → `{Env}`, `read_file`/`write_file` → the FS pair, and every `*_exn` → `{Raise}`. Everything else is empty.

*Accept:* `$()` shows `{Shell, Raise}` and `$?()` shows `{Shell}`; the inferred row for each stdlib module's functions is recorded in the reference; nothing that only computes acquires an effect.

## P1.4 — `try` and `handle` discharge

The first place a row *shrinks*, and the real test of the design.

- `try` removes `Raise`: `(… ! {Raise | e}) -> Result String … ! e`
- a `handle` arm intercepting `process_run` removes `Shell` from the handled expression's row

*Accept:* the existing mocking tests in `fs_test.wand` show discharged rows; a `try` around a raising call is pure in `Raise` afterwards.

## P1.5 — Display

`string_of_typ` renders `! {…}`, **suppressed entirely when the row is empty** so pure signatures read exactly as they do today. Then `wand t`, `wand d`, `:t`, REPL binding output.

*Accept:* D4's first beat — bury a `$(curl …)` three helpers deep, re-run `wand d`, and watch `Net` appear with no annotation anywhere.

## P1.6 — The effect-dependent lints

These are why the roadmap put them here: undecidable without rows, trivial with them.

| Rule | Fires when |
|---|---|
| `M-BANG1` | a function whose inferred row contains `Raise` has no `!` in its name |
| `M-BANG2` | a `!`-named function whose row does not contain `Raise` |
| `M-OR2` | a pipeline mixing `Option` and `Result` with no visible `to_result` |

*Accept:* the stdlib-lints-clean test enforces the `!` convention in both directions — the thing §3.2 called social and unchecked.

---

## Risks

- **P1.2 cannot be half-landed.** It touches inference broadly; keeping it behavior-preserving is what makes it reviewable.
- **Recursion is the subtle case.** A fresh row variable must be unified the same way the placeholder type is.
- **Rows must not leak into error messages** as internal notation, the same rule multi-equation diagnostics follow.

## Exit criteria

1. `dune build && dune test` clean; examples and demos unaffected.
2. `wand d` on a shell-running stdlib function shows its effects; on a pure one shows none.
3. Every stdlib effect row is inferred — no hand-written effect annotations anywhere in `stdlib/`.
4. `try` and `handle` visibly discharge.
5. `M-BANG1` / `M-BANG2` pass clean on the stdlib.

# Design: a type annotation on a parameter

**Status: proposal — first in the queue, blocked.** Waiting on the
effect-annotation change already in flight (`! {Shell, IO}` on a written
type), which is rewriting the same functions. The doc retires once
`docs/reference.md` documents the syntax.

> **Before starting, re-read the line references below.** They were taken
> against commit `5695853`. The in-flight change gives `Ast.TEFun` a
> third argument for the effects an arrow performs, and reworks
> `parse_type_expr` — so the type an annotation parses will already carry
> effects by the time this is built, and `parse_type_expr` will return
> the new shape. That is a help rather than a complication: `let f (p:
> Pod) : String ! {IO} = …` falls out of the two changes composing, with
> nothing extra to design. But the anchors will have moved.

## The problem

A function parameter cannot be given a type, and so a function cannot
read a field off one:

```
type Pod(name: String, phase: String)

let describe p = p.name
-- type error: field access requires a named type, got 'a
```

Applying `describe` to a real `Pod` three lines later does not help. The
definition is generalized before any use site is seen, which is ordinary
Hindley-Milner, and field access needs a *named* type to look the field
up in — there is no row polymorphism to leave the record open. So the
type has to come from the definition, and there is nowhere to write it.

Two workarounds exist today. Re-bind through an annotated `let`, which
the grammar does allow:

```
let describe p = let pod : Pod = p in pod.name
```

Or destructure with `match`:

```
let describe p = match p with | Pod(name = n, phase = _) -> n
```

Both work. Both cost a line and a level of indentation per record, and
the cost compounds: a two-level record read three fields deep becomes a
pyramid of `match` arms that exist only to reach values. That case is
written out in [`shell-corpus.md`](shell-corpus.md), where porting four
ops scripts put this ahead of every library gap on the list — ops code is
records being handed to helpers, and every helper pays.

## The error is a wrong guess

The obvious syntax is already refused, and refused with a specific
misdiagnosis:

```
let describe (p: Pod) = p.name
-- parse error: a cons pattern is written in square brackets:
--   [x : xs], not '(x : xs)'
```

That message is hardcoded at `lib/parser.ml:279` and again at
`lib/parser.ml:358`, in `pat_` and `pat_atom_` respectively. Neither site
attempts to parse a type; on seeing a `Colon` after a pattern inside
parentheses, both fail immediately.

The message was written for a real mistake — someone typing OCaml's or
Haskell's cons — and it is a good message for that. But it has taken a
slot that is not otherwise spoken for, because **cons in a pattern is
written `[h : t]`, in square brackets, and always has been.** There is no
pattern in the language whose surface syntax is `(x : y)`. The
parenthesised form is unreachable, and the parser is refusing something
it could simply accept.

This matters because the equivalent slot at *expression* level genuinely
is taken. There, `:` is cons, and `(r : R)` parses as one — which the
typechecker confirms, since `(r : R).a` reports that `R` has named fields
and should be constructed as `R(a = ...)`. It read `R` as a constructor
in a cons expression, exactly as it should. So this proposal is for
pattern position only, and expression-level ascription stays unavailable.
That is a fair trade: the annotation is wanted where a name is bound, not
where a value is used.

## The syntax

```
let describe (p: Pod) = p.name

let f = fn (p: Pod) -> p.status.restartCount

List.filter (fn (p: Pod) -> p.status.restartCount > 5) pods
```

It composes with the return annotation the grammar already has:

```
let describe (p: Pod) : String = p.name
```

which is the argument for this shape over any other. `let f x : T = e`
already parses — `lib/parser.ml:780` and `:1380` both read an optional
`Colon` and call `parse_type_expr` before the `=`. wand can already be
told a definition's result type and cannot be told its argument types.
This closes an asymmetry rather than introducing a concept.

### Disambiguation is one token

No backtracking is needed. After a pattern inside parentheses, on seeing
`Colon`, look at the token after it:

| next token | reading |
|---|---|
| `Upper` (`Pod`), `TypeVar` (`'a`), `LParen` | type annotation |
| anything else | the cons mistake, with today's message |

That falls out of `parse_type_atom` (`lib/parser.ml:453`), which accepts
exactly `Upper`, `TypeVar` and `LParen` and rejects a lowercase `Ident`
with "expected type name". So `(x : xs)` — the actual mistake the message
exists for — still hits the cons message, and `(p: Pod)` does not. The
two cases are distinguished by a token class, not by parsing ahead and
recovering.

## Where the change goes

Small, and mostly in one place each.

**`lib/ast.ml`** — one constructor on `pat`:

```
| PAnnot of pat * type_expr
```

**`lib/parser.ml`** — the `LParen` branch of `pat_atom_` and of `pat_`.
Where each currently calls `fail_at` with the cons message, take the
branch above: on a type-starting token, `parse_type_expr`, `expect
RParen`, and return `PAnnot (p, te)`; otherwise fail as now.

All four places that read parameters funnel through `pat_atom_` —
`lib/parser.ml:774` (the `and` group), `:944` (`fn`), `:1047` (local
`let`), `:1378` (top-level `let`) — so `fn`, both `let` forms and mutual
recursion all gain it from the one edit.

**`lib/typechecker.ml`** — one case in `infer_pat`
(`lib/typechecker.ml:1081`): resolve the
`type_expr` the way `Annot` already does at `:1999`, unify it with the
type flowing in, and recurse into the inner pattern. The `Fn` case at
`:1534` already hands `infer_pat` a fresh type variable per parameter,
which is precisely what unification wants — the annotation pins the
variable and inference proceeds unchanged.

**`lib/formatter.ml`** — print it back. Since a pattern round-trips
through the formatter and `tools/check_fmt.wand` gates the corpus on
fixed-pointness, this is not optional.

## Reach: every pattern, or only parameters?

`pat_` and `pat_atom_` are both edited above, which means `match`,
`with … as`, and destructuring `let` accept the annotation too:

```
match r with | (p : Pod) -> p.name
with FS.temp_dir "b_" as (d : Path) -> ...
```

Nothing needs those, and the recommendation is still to allow them.
Refusing an annotation in one pattern position and allowing it in another
is a rule a reader has to learn and the parser has to enforce, and it
buys nothing. Allowing it everywhere is the smaller language.

## What this deliberately does not do

**It does not change inference.** An annotation is a constraint fed to
the existing algorithm, not a new one. `fn p -> p.name` with no
annotation stays a type error, and inference still does not flow from a
use site to a definition. Anyone reading this doc expecting the error to
go away by itself should read this paragraph as the answer to why it does
not: making it disappear needs row polymorphism on records, which is a
much larger change with consequences everywhere, and it is not what
scripts are short of.

**It is not a signature syntax.** A standalone

```
let describe : Pod -> String
let describe p = p.name
```

is still a parse error, and stays one. Whether wand should have separate
signature lines is a real question and a different doc.

**It does not touch expression-level ascription.** `(e : T)` remains
cons, per the section above.

## Verification

Beyond `dune build @runtest --force`:

- Parser tests for `(p: Pod)` in each of the four parameter positions,
  and for `[x : xs]` and `(x : xs)` still reporting the cons message —
  the second is the regression that matters, since this change edits the
  code path that produces it.
- A typechecker test that an annotation which contradicts the body is an
  error, and that an annotation which merely narrows an inferred type is
  accepted.
- Formatter fixed-point over the corpus, and the corpus still running,
  per the extra bar `CLAUDE.md` sets for formatter changes.
- Rewrite the four ported scripts from `shell-corpus.md` against the new
  syntax. They are the reason for the change and the honest measure of
  whether it landed: row 6's four-deep `match` pyramid should become one
  `fn (p: Pod) ->`.

## Sequencing

This is queued behind the effect-annotation work rather than merged into
it, because the two are independent in everything but the files they
touch: one says what an arrow *performs*, the other says what a parameter
*is*. Landing them separately keeps each diff readable and each set of
tests honest about what it covers. The order is forced by the overlap,
not by any dependency in the design — nothing here needs effects on
types, it just cannot be edited into the same functions at the same time.

## Cost

One AST constructor, two parser branches sharing a helper, one
typechecker case, one formatter case, and tests. No change to inference,
no change to the type representation, and no new keyword. The
disambiguation needs no lookahead beyond one token and no backtracking.

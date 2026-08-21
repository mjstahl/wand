# Design: the words an error message uses

**Status: proposal — not implemented.** Review before code. The doc retires
when the messages ship and `docs/reference.md` quotes the new text.

## The problem

Most wand errors read well. They name the mistake and the fix:

```
strings concatenate with '++', not '+'
there is no mutation; let binds a new name instead
this command runs 'whoami', which Shell(echo) does not allow.
       The manifest could be:  "uses {IO, Shell(echo, whoami)}"
```

A small set does not. It names the algorithm instead of the mistake:

```
cannot unify Glob with Path
cannot unify Int with Bool
cannot unify effects {Shell} with {Raise, Shell | ..}
infinite type
```

"Unify" is a word from the type checker, not from the script. The reader has
a `Path` where a `Glob` belongs. `expected Glob, got Path` says that. Nobody
has to know what unification is.

The README used to paraphrase the error as `expected Glob, got Path`. The
real text says otherwise, so the README was wrong. It now quotes the real
text. That is the wrong way round: the message should be the readable one.

## What this covers

Seven sites, in two files. Line numbers are from `eb28ae5`.

| where | text |
|---|---|
| `typechecker.ml:552` | `cannot unify %s with %s` |
| `typechecker.ml:523` | `cannot unify Num with %s -- Num is Int or Float` |
| `typechecker.ml:530` | `cannot unify Float with Int -- ... convert explicitly` |
| `effect_set.ml:177` | `cannot unify effects %s with %s` |
| `effect_set.ml:181` | the same text, one side open |
| `effect_set.ml:186` | the same text, other side open |
| `typechecker.ml:518` | `infinite type` |

The last one is rare and needs its own words. A reader meets it when a value
would have to contain itself.

The two hint messages that mention `Status` and `Unit` are comments in the
source, not messages. They quote the generic text and change with it.

## The obstacle: `unify` has no fixed argument order

`expected X, got Y` is directional. `unify a b` is not. Both orders appear:

```ocaml
unify t (infer tenv env e)        (* annotation first: expected, got   *)
unify (infer tenv env cond) TBool (* condition first: got, expected    *)
unify (infer tenv env e) TString  (* got, expected                     *)
unify t (TTuple ts)               (* expected, got                     *)
```

So this is not a text edit. Something has to decide which side the reader
expected.

## Three ways to do it

**1. Symmetric wording.** Change the text and keep the order out of it:

```
these two types do not match: Glob and Path
```

Cheap, and safe. It is still worse than `expected Glob, got Path`, because
the reader must work out which side is the code they wrote.

**2. Audit the call sites.** Fix an order — expected first — and correct
each `unify` call that has it the other way. About 60 call sites in
`typechecker.ml`. The compiler cannot check this; a wrong site gives a
backwards message, and only a test catches it.

**3. Label the arguments.** Give `unify` two optional labels:

```ocaml
val unify : ?expected:typ -> ?got:typ -> typ -> typ -> unit
```

The default stays symmetric (option 1). Then label the sites where a reader
has a clear expectation: an annotation, an `if` condition, a function
argument, the arms of a `match`, a `$()` payload. Roughly ten sites carry
most of the errors a script meets.

**Recommendation: option 3.** It gives the readable message where it counts,
it does not need a 60-site audit to be correct, and each labelled site is a
deliberate statement about what the reader expected.

## The effect messages

`cannot unify effects {Shell} with {Raise, Shell | ..}` has the same fault
and one more: the reader does not know what `| ..` means without the
reference. The likely readable form names the difference:

```
this function performs Raise, and the type it is given does not allow it
```

That needs the same direction as above, so it follows the same decision.

## What it costs

19 places quote the current text: 12 in tests, 7 in `docs/reference.md`.
Each has to change with the message. The reference is the point of the work,
so its examples must be re-run, not edited by hand.

## What decides it is done

- A script that puts a `Path` where a `Glob` belongs reads `expected Glob,
  got Path`.
- No message a script can reach uses the word "unify".
- `docs/reference.md` quotes the new text, and the text comes from a run.

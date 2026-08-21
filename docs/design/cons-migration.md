# Moving cons from `:` to `::`

`:` means two things today. It joins a head to a list, and it gives a name
a type. This plan gives cons its own spelling and leaves `:` to types.

## Why

**The overload already costs a rule.** A cons pattern must be written in
brackets — `[h : t]` — because `(h : t)` cannot be told from a parameter
carrying a type. `lib/parser.ml` refuses `(x : xs)` in three places, each
with a message written for the mistake. A parameter annotation is read
only when a type token follows the `:`, which is a lookahead that exists
for this reason alone.

**wand already fights `::`.** `lib/lexer.ml` raises on `::` with a
correction, `lib/diag.ml` carries the pair, and `test/test_drift.ml` locks
the message in. A rule exists because people keep writing `::`. That
evidence points at the spelling wand should have.

**`:` for a type is the stronger convention.** OCaml, TypeScript, Rust and
Python all read `x : T` as a type. Haskell reads `x : xs` as cons; OCaml,
Elm and F# — the languages wand's syntax otherwise tracks — write `::`.

**Reading is where it shows.** `examples/ports/http-retry.wand` holds
`type Health(status: String, …)`, `let report (h: Health) = …` and
`(p, size) : acc` within a screen of each other.

Counts across `stdlib`, `examples`, `test/wand`, `demos` and `tools`, from
grep and approximate: cons in expressions ~60, cons in patterns ~37, type
definition fields ~55, parameter annotations ~19. Volume does not decide
it; the three reasons above do.

## What changes

`h :: t` in an expression. `[h :: t]` in a pattern. `:` is a type, a port
literal, and nothing else.

The bracket rule around a cons pattern is no longer forced. `(h :: t)` is
unambiguous once cons has its own token. Keeping brackets or allowing both
is a decision inside this work, not a reason for it.

## The steps

1. **Lex `::`.** `Token.DoubleColon`, printed `::`. `lib/lexer.ml:706`
   raises today; it returns the token instead. The port literal reads `:`
   followed by a digit, and the `::` branch already runs first, so `::80`
   is a cons of `80` rather than a port.

2. **Parse it.** `bin_prec` moves from `Token.Colon` (`parser.ml:237`) to
   `DoubleColon`; the operator in `parser.ml:648` follows. The AST's
   `BinOp ":"` becomes `BinOp "::"`, which is three call sites:
   `typechecker.ml:2426`, `evaluator.ml:1247`, `formatter.ml:275,281`.

3. **Accept `:` as cons for one release.** In expression position and
   inside a list pattern, a `:` still parses as cons. A type never appears
   in either place, so nothing is ambiguous while both are read. `wand f`
   writes `::`, so migrating a file is running the formatter. `wand t`
   reports it as a violation with a `--fix`.

4. **Turn the drift rules around.** `lib/diag.ml` and the lexer stop
   correcting `::`. The new correction fires where a `:` in expression
   position can no longer be a type: "cons is `::`". The `(x : xs)`
   messages in `parser.ml` become the answer for `(x :: xs)` — which is
   now legal — or are deleted with the bracket rule.

5. **Migrate the corpus.** `wand f` over `stdlib/`, `examples/`,
   `test/wand/`, `demos/` and `tools/`, then the whole battery.
   `tools/check_fmt.wand` is the gate that proves it landed.

6. **Documentation.** The syntax card in `CLAUDE.md`, the reference's
   syntax table, its Lists and Pattern-matching sections, and the drift
   tests.

7. **Remove the transitional `:`** in the release after. Until then a
   script written for 0.29.0 keeps running.

## Cost and risk

Breaking, so it wants its own release — 0.30.0 — and the transitional
parse means nothing breaks on the day it lands.

The risk worth naming is step 3. Two spellings of one operator is the
state this plan exists to end, and a transitional window that is not
closed becomes permanent. Step 7 is scheduled in the same breath for that
reason.

The second risk is smaller: `::` is two characters where `:` was one, in
an operator that appears in every fold written by hand. That is the price
of the reading it buys.

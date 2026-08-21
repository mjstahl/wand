# Moving cons from `:` to `::`

`:` means two things today. It joins a head to a list, and it gives a name
a type. This plan gives cons its own spelling and leaves `:` to types.

Line and file anchors were true at `1b1522f`. Check each before trusting
it.

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

The brackets stay. `[h :: t]` says what `[a, b, c]` says: this is a list.
A bare `h :: t` is what OCaml writes, and it is read — then `wand f` writes
the brackets back. Parentheses are grouping and are read the same way.

The old spelling is read too, for one release, and `wand f` writes `::`.

Both are aliases rather than spellings wand offers, which is the treatment
`fun` already gets for `fn`.

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
   writes `::`, so migrating a file is running the formatter.

   No lint rule. A lint would need the AST to carry which spelling was
   written, because both parse to one node, and it would duplicate what
   the formatter already does. `fun` is read as `fn` and written back with
   no rule either.

4. **Turn the drift rules around.** `lib/diag.ml` and the lexer stop
   correcting `::`. The new correction fires where a `:` in expression
   position can no longer be a type: "cons is `::`".

5. **Read the bare pattern, and write the brackets back.** `| h :: t ->`
   without brackets answers "expected ->, got :" today, which names
   nothing, and it is the likelier mistake. It has to be completely
   fixable, and that ruled out leaving it a parse error: `lib/fix.ml` will
   not apply a correction to a file it cannot read, because rewriting
   guesswork is guesswork.

   The first plan made it a lint with a `ReplaceLine` fix. That needs the
   AST to record which spelling was written, since `[h :: t]` and `h :: t`
   are one node — and `fun`/`fn` shows the cheaper answer. So `pat_` reads
   a trailing `:: pat`, and `wand f` writes `[h :: t]`.

   Reading it means choosing what `Some h :: t` means. A constructor takes
   its payload by juxtaposition, through `pat_base_`, which stops before
   the `::`. So it is `(Some h) :: t`, the OCaml reading, and the brackets
   the formatter adds say so.

   A `:` in a pattern where no type follows it is still refused, in the
   three places it could be written, with the correction naming
   `[x :: xs]`.

6. **Migrate the corpus.** `wand f` over `stdlib/`, `examples/`,
   `test/wand/`, `demos/` and `tools/`, then the whole battery.
   `tools/check_fmt.wand` is the gate that proves it landed.

7. **Documentation.** The syntax card in `CLAUDE.md`, the reference's
   syntax table, its Lists and Pattern-matching sections, and the drift
   tests.

8. **Remove the transitional `:`** in the release after. Until then a
   script written for 0.29.0 keeps running.

## Cost and risk

Breaking, so it wants its own release — 0.30.0 — and the transitional
parse means nothing breaks on the day it lands.

The risk worth naming is step 3. Two spellings of one operator is the
state this plan exists to end, and a transitional window that is not
closed becomes permanent. Step 8 is scheduled in the same breath for that
reason.

The second risk is smaller: `::` is two characters where `:` was one, in
an operator that appears in every fold written by hand. That is the price
of the reading it buys.

## Open

**Whether step 3 happens at all.** The transitional read of `:` costs a
release of two spellings and buys a migration that is `wand f` and
nothing else. Breaking it in one go is simpler, and at wand's user count
it is defensible: a script written for 0.29.0 stops running until someone
edits it, and the error names the edit.

**Nothing.** The rule codes are gone — `fun`/`fn` answered both. Step 3
was kept: without a transitional read, migrating the corpus is hand-editing
~97 colons with no mechanical check that the right ones moved.

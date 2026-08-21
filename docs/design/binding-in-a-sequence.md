# Design: a binding that lives for the rest of the sequence

**Status: proposal — not implemented.** It is step 2 of the order of work
in [`shell-corpus.md`](shell-corpus.md), which found it by porting four
scripts. The doc retires when `let p = e;` binds for the rest of its
block, the formatter writes that form back, and `docs/reference.md` says
so. Line references are from `78f6909`.

## The problem

Inside parentheses, `;` separates statements and `let ... in` names a
value. The two do not compose. `let ... in` scopes over the next
expression only, and `;` ends that expression:

```
$ wand e '(let x = 1 in x + 1; x + 2)'
Error: type error: 1:22: unbound variable 'x'
```

So a body that names two intermediates and uses them across four
statements nests twice. Every ported script that names anything drifts
rightward:

```
let stage = Path.join work (Path.of_string "pkg") in (
  let archive = Path.of_string "./dist/%{release}.tar.gz" in (
    FS.mkdir! stage;
    FS.copy! archive stage;
    ...
  )
)
```

The indent carries no meaning. Both bindings belong to the same block.
The reader has to hold two levels of bracket to see one level of code.

## The second face, which is worse

The form a person reaches for is `let` with no `in`, the way the top
level of a file works. It parses today. It binds nothing:

```
$ wand e '(let x = 1; x + 2)'
Error: type error: 1:13: unbound variable 'x'
```

`let_` (`parser.ml:911`) calls `consume_rest`. That function takes the
`in` branch, or the `parse_body` branch when an expression follows, or
returns `Unit`. A `;` is neither, so the binding gets a body of `Unit`
and dies where it stands. Nothing reports it. The error names the use
site, and the use site is not the mistake.

The binding is also invisible to a reader who knows the top-level rule,
because at the top level the same three words work. wand should not have
one spelling that means two things.

## The terminator is the whole story

At the top level a newline ends the right-hand side. Inside brackets a
newline is formatting, so it cannot. Juxtaposition is application, and
the right-hand side keeps eating:

```
$ wand e '(let x = 1 x + 2)'
Error: type error: 1:10: unbound variable 'x'
```

That reads as `let x = (1 x) + 2`. The same happens across a newline
inside the parentheses, for the same reason.

So the block form needs a terminator, and `;` is the one the language
already has. This is why the fix is a change to the sequence and not to
`let`: `;` is what makes a binding's right-hand side end, exactly as a
newline does at depth 0.

## The proposal

A `let` at a statement position binds for the rest of its block.

```
let deploy! release = (
  let stage = Path.join work (Path.of_string "pkg");
  let archive = Path.of_string "./dist/%{release}.tar.gz";
  FS.mkdir! stage;
  FS.copy! archive stage;
  "deployed"
)
```

`;` keeps one meaning: next statement. `let ... in` keeps one meaning:
name a value for this expression. A block reads like the top level of a
file, with `;` where the file has a newline.

## What is not proposed

Re-associating `let ... in` across `;`, so that `(let x = 1 in a; b)`
scopes `x` over `b` as well. Two reasons.

`in` would then mean two different things, chosen by what follows the
body. Written at the end of a block it scopes over one expression.
Written before a `;` it scopes over everything after. That is a rule a
reader must know before reading, and the block form makes it
unnecessary.

It also carries the same behaviour change as the block form, below, with
nothing extra bought.

`(let x = 1 in a; b)` keeps its current meaning under this proposal: `x`
names `a` and nothing more.

## The one behaviour change

A dead binding that shadows a live one becomes live:

```
$ wand e 'let x = 0 in (let x = 1; x)'
0 : Int          -- today
                 -- under this proposal: 1
```

No error, no warning, a different answer. Every other program the
proposal touches is one that fails to typecheck today, so this is the
only case where working code changes meaning.

It is also the reason the work is a release gate rather than an
improvement to schedule. After 1.0 this change is not available, because
1.0 says a script that runs today runs tomorrow.

## Decided edges

**A `let` cannot end a sequence.** `(f (); let x = 1)` binds a name that
nothing reads and values `Unit`. Today it is silent. It becomes a parse
error that says the binding has no body.

**Annotations, functions and `and` groups fall out.** `let x : Int = 1;`,
`let helper y = y + 1;` and a mutually-recursive `and` group all reach
`consume_rest` by the same path, so all three work with no extra code.

**A refutable pattern behaves as it does elsewhere.** `let Ok v = r;`
records `Raise` and raises where it stands, as `083b2cb` decided for
every other binding position.

**`let () = e1 in e2` still works.** It is documented, it guarantees `e1`
is `Unit`, and nothing here touches it.

## The formatter has to choose a form

Two source forms now reach the same node. `(let x = 1; a)` and
`(let x = 1 in a)` both parse to `Let (x, 1, a)`. The formatter has to
write one of them back, and `tools/check_fmt.wand` requires that the
answer is a fixed point.

The shapes differ as soon as the block has more than one statement.
`(let x = 1; a; b)` is `Let (x, 1, Seq (a, b))`; `(let x = 1 in a; b)` is
`Seq (Let (x, 1, a), b)`. So a rule on the shape decides almost every
case:

- a `Let` whose body is a `Seq` is written in the block form,
- a `Let` whose body is a single expression is written with `in`.

That leaves `(let x = 1; a)` — a block of one statement after the
binding — rewritten to `(let x = 1 in a)` on the first pass, and stable
after it. That is a real edit to a person's source, and it is the
right one: with one statement following, the two forms say the same
thing, and `in` is the older spelling.

The alternative is to record which form was written, either as a flag on
`Ast.Let` or as a separate block node, and write each back as it was.
That is more faithful and more code, and it spreads a new field across
every consumer of `Let`. Take it only if the normalizing rule turns out
to bother anyone.

## What is touched

- `parser.ml:702`, the sequence branch: on `Token.Let` at a statement
  position, parse the binding, and when a `;` follows, parse the rest of
  the sequence as its body. About twenty lines.
- `parser.ml:911`, `consume_rest`: the sequence path owns the "no `in`"
  decision, so the two cannot disagree. A `let` that ends a sequence
  fails here with its own message.
- `formatter.ml:424` `emit_let` and `formatter.ml:453` the `Seq` case:
  the flattening walk descends through a block-scoped `Let`, and the
  shape rule above decides which form is written.
- `complete.ml` and `lsp.ml`: a binding in a block is a local the editor
  should offer for the statements after it.
- `docs/reference.md:464`, Sequencing: the block form, with the rule that
  a binding lives for the rest of its block.
- `docs/reference.md:3256`, the style entry that reads "use `let ... in`
  to name a value, not to sequence". The advice was written around this
  gap and stops being true.

Nothing in the typechecker. The node is the `Let` the top level already
produces, so scoping falls out. Nothing in the lint rules either:
`lint.ml:136` walks `Let` generically, and a binding discards nothing, so
`V-DROP1` keeps reading a `Seq`'s own first child as it does now.

## Verification

- Scope: `(let x = 1; let y = 2; x + y)` is `3`.
- The old form is unchanged: `(let x = 1 in x + 1; 9)` is `9`, and the
  `x` in a third statement is still unbound.
- Shadowing: `let x = 0 in (let x = 1; x)` is `1`, pinned as a test so
  the change is recorded rather than discovered.
- A `let` that ends a sequence is a parse error with its own message.
- A refutable binding in a block records `Raise`: a file whose only
  raise is `let Ok v = r;` needs `Raise` in its manifest.
- Formatter: each form above is a fixed point, and the one-statement
  block normalizes once and then holds.
- `tools/check_fmt.wand` passes over `stdlib/`, `test/wand/` and
  `examples/`, and the corpus still runs. `wand f` writes in place, so
  run it on a copy first.

## Cost

A day or two. The parser change is small. The formatter is most of the
work, and the docs are the rest.

The value is not the saved indentation. It is that a block and a file
read the same way, and that the three words a person types first mean
what they look like.

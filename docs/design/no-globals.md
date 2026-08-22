# Printing comes from a module

`print` and `println` are the only functions a file can call without an
import. This plan removes them, so that every function a script calls comes
from a module it imported.

Counts and line anchors were true at `ddf615d`. Check each before trusting
it.

## Why

**The corpus is split, and the split says nothing.** 70 calls are bare and
48 are `IO.print*`. No rule separates them: the same file prints both ways
depending on when the line was written.

**Most files already import the module.** Of the files that print bare, 17
already carry `import IO` and change for free. Six gain an import line.

**The exception costs a sentence in every explanation.** The reference has
to say which names need no import, `CLAUDE.md` repeats it, and a reader has
to hold "everything comes from a module, except two things" instead of the
rule.

**The module's own definition is circular.** `stdlib/IO.wand:4` reads `let
print = print` and line 7 reads `let println = println`. That only works
because the global exists; every other line in the file binds a primitive
(`let print_err s = io_print_err s`).

## What changes

`print` and `println` stop being in scope. `IO.print` and `IO.println` are
how a script prints, and a file that prints writes `import IO`.

`Ok` and `Error` stay global. They are constructors of a built-in type with
no module to import them from, so they are not the same case.

The old spelling gets an error that teaches the new one. `println "hi"`
answers `unbound variable 'println' -- printing is IO.println (import IO)`,
which is the mechanism `printf`, `puts`, `print_endline` and `echo` already
use.

## The steps

1. **Rename the primitives.** `io_print` and `io_println`, in the
   typechecker's stdlib env (`lib/typechecker.ml:2509-2510`) and the
   evaluator's (`lib/evaluator.ml:2115-2116`). `stdlib/IO.wand` binds them
   the way `print_err` already binds `io_print_err`.

2. **Empty the globals.** `builtin_type_env` (`lib/typechecker.ml:2881`)
   holds only these two and becomes empty. `base_eval_env`
   (`lib/evaluator.ml:3612`) keeps `Ok` and `Error`.

3. **Name one performer.** `op_performers` for `IO!print` and `IO!println`
   (`lib/typechecker.ml:292-295`) list both spellings; they list the
   module's.

4. **Point the hints at the module.** `foreign_name_hint`
   (`lib/typechecker.ml:717-723`) answers `printf`, `puts`,
   `print_endline`, `print_string`, `print_newline`, `print_int`,
   `print_float`, `console` and `echo` with "printing is println (or
   IO.println)". Each says `IO.println (import IO)`, and `print` and
   `println` join them.

5. **Convert the corpus.** 70 call sites across `stdlib/`, `examples/`,
   `demos/`, `test/` and `tools/`, and six files that gain `import IO`.
   `lib/complete.ml:17` lists `print` and `println` as completions, and
   `test/test_complete.ml:25` checks for one.

6. **Fix the documentation.** Twelve examples in `docs/reference.md`, one
   line in `CLAUDE.md`, and the sentence in each that says printing needs
   no import. The README does not print.

## Cost and risk

The smallest useful program names the module three times:

```ocaml
uses {IO}
import IO
IO.println "hi"
```

bash writes `echo hi`. That is the price, and every snippet a newcomer
reads pays it.

The risk is low. An unbound name is an error rather than a wrong answer, so
nothing breaks silently, and the hint names the fix at the point of the
mistake.

## Rejected

**Auto-importing `IO`.** It would remove the import line and keep the
qualified call. It makes one module special, and then `import IO` is a line
that does nothing, which the dead-import lint would have to be taught to
ignore. A module is imported to be used.

## Open

- **Whether `wand t --fix` should add the missing import.** The fix
  machinery already inserts a manifest line and deletes a dead import, so
  the shape exists. It is worth doing only if the conversion turns out to
  be tedious by hand.

## 0.55.5 - 2026-09-01

Two `wand f` fixes, both found by the daily fuzzer. `wand f` writes in place,
so each one changed a file it was asked to tidy.

### A command literal is not a bracket

A constructor takes the bracket written after it, so `wand f` brackets one
whose argument does not already bracket the whole of itself. It answered that
by scanning the rendered characters, and the scan knew `"` and nothing else.

A command holds quotes and brackets that mean neither. A `"` inside one
opened a string that never closed, and a `)` closed the argument's bracket
early -- so a bracket that does hold everything came back as one that does
not, and the constructor took a bracket it did not need. Behind a module's
name that bracket does not parse at all:

```
$ cat log.wand
let found = Log.Hit (Shell.run `grep -c ')' build.log`)

$ wand f log.wand
$ cat log.wand
let found = Log.(Hit) (Shell.run `grep -c ')' build.log`)

$ wand f log.wand
Error: log.wand: parse error: 1:17: expected identifier, got (
```

The question is asked of the tokens now, where the knowledge of these forms
already lives, so every literal form counts for free. The brackets a
constructor does need are unchanged: `O ()` is still the empty field list
rather than unit in brackets, and `O (d).n` still comes back as `(O d).n`.

### A nested pipeline keeps its brackets

A `|>` chain too wide for one line breaks into a stage per line, which reads
back as one left-associative chain. So a stage that is an operator of its own
needs the brackets it would get on the right of a `|>` -- and got none. The
program changed on the first pass, and the reprint of the changed program
differed again:

```
$ cat sum.wand
let summary = rows |> (List.filter interesting_enough_to_report |> List.map render_one_summary_row_of_the_table)

$ wand f sum.wand
$ cat sum.wand
let summary =
  rows
    |> List.filter interesting_enough_to_report |> List.map render_one_summary_row_of_the_table

$ wand f sum.wand
$ cat sum.wand
let summary =
  rows
    |> List.filter interesting_enough_to_report
    |> List.map render_one_summary_row_of_the_table
```

`rows |> (f |> g)` had become `(rows |> f) |> g`. The stages carry the
brackets now, and a stage whose operator binds tighter than `|>` still gains
none:

```
$ wand f sum.wand
$ cat sum.wand
let summary =
  rows
    |> (List.filter interesting_enough_to_report |> List.map render_one_summary_row_of_the_table)
```

Both bugs needed a line wide enough to wrap, or a constructor argument
holding a command. Both were present in 0.55.4 and earlier. The formatted
tree is unmoved at 103 files -- each guard only adds a bracket where one was
already owed. Nothing else changed: the command line, the type checker and
the lint rules are exactly 0.55.4's.

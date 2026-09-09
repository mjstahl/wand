## 0.69.0 - 2026-09-09

Seventeen tasks written three ways — wand, Python, and bash — run
interleaved against each other on the same seeded data, with every loss
decomposed until one function could be named. Five causes came out of it,
and all five are fixed.

Against 0.68.0, on the same machine:

| task | before | after | |
|---|---|---|---|
| dedupe, 20k lines | 6094 ms | **32 ms** | 188× |
| top-5 by key, 200k lines | 2639 ms | **348 ms** | 7.6× |
| count matching lines, 200k | 479 ms | **161 ms** | 3.0× |
| string replace per line, 200k | 646 ms | **236 ms** | 2.7× |
| sort 200k rows | 1944 ms | **866 ms** | 2.2× |
| CSV group-and-sum, 100k | 680 ms | **328 ms** | 2.1× |
| date arithmetic, 200k | 1652 ms | **873 ms** | 1.9× |
| sum a field · JSON · regex | | | 1.4×–1.6× |

wand now beats both Python and bash on four of the seventeen: spawning
processes, parallel map, reading many small files, and dedupe.

### There was no hash table

`Map` was an association list. A lookup read every key before the one it
wanted and a write walked the whole map, so cost grew with the number of
keys: 200,000 counts over 400 keys spent two seconds inside `Map`.
`Stream.unique` was the same shape by another name — it kept everything it
had seen in a list and searched it for every item, which is the square of
what it reads. 20,000 distinct lines took six seconds. 200,000 would have
taken about ten minutes.

Both are backed properly now. The same file takes about 320 ms.

A map still holds its entries in the order their keys were first added, a
key already present still keeps its place, and a document read in, edited
and written back still keeps its shape. That behaviour is documented, so it
is kept by a counter rather than by the list's own order, and there are
tests over fifty keys and across a delete-then-re-add.

### Counting a thing is one line

```
-- before
match Map.get who counts with
| Some n -> Map.set who (n + 1) counts
| None -> Map.set who 1 counts

-- after
Map.update who 0 (fn n -> n + 1) counts
```

`Map.update` gives `f` what is there, or the value you name where the key is
new, and reads and writes in one pass. `Map.set` is unchanged: it ignores
what is there, so it applies no function, and it is still the way to write a
value that does not depend on the old one.

### A `;` outside parentheses was quietly a different program

```
let go () =
  IO.println "one";
  IO.println "two"
```

printed `two` and then `one`. The `;` ended the definition, and the indented
line below it became a top-level statement — and top-level statements run in
file order, before `go ()` is ever called. Nothing reported it. The one
diagnostic that did fire was the `!`-naming lint saying `go` cannot raise,
which was true of what had been parsed and the opposite of what was written.

It is a parse error now, and the message names the fix. A `;` separating
top-level items on one line is unaffected.

### A message you could not copy

```
$ wand t -e 'fn xs -> match xs with | [] -> 0 | [a :: [b :: _]] -> a + b'
Error: type error: non-exhaustive match: missing case, e.g. _ : []
```

Paste that case in and you got `cons is '::' -- a single ':' gives a name a
type`: one error telling you to write what the other refuses. `_ : []` used
the cons spelling removed in 0.31.0, and left off the brackets a list
pattern is written with. It reads `[_ :: []]`.

### Two string builtins allocated at every position

`String.contains?` asked "is the needle here?" by allocating a fresh
substring at each position, and then ran to the end of the string after it
already had its answer. `String.replace` allocated the same way. Both
compare in place now, and `contains?` stops at the first match.

`List.sort_by` computed its key inside the comparator, so ordering n
elements applied it about 2n log n times instead of n — seven million
interpreted calls to sort 200,000 rows.

### Naming a standard library function cost more than calling it

`String.length` was a walk of every member of `String`, and the members run
backwards, so the function declared first in a file was the last one found:
584 ns to resolve, against 74 ns for the one declared last. A namespace
carries an index now and both are 92 ns.

Underneath that, half the standard library is written `let trim s =
str_trim s` — handing its arguments to a builtin unchanged. Such a
definition *is* that builtin, and the closure around it existed only to pass
values along. 289 of the 530 definitions have that shape and are bound
directly now.

### Also

- A glob matches a *name*; `FS.glob` answers with *files*. Those are
  different questions, and on a directory whose name fits the pattern they
  give different answers:

      FS.glob_in ./*.txt dir                      -- [real.txt]
      Glob.matches? ./*.txt ./looks.txt           -- true, and it is a directory

  The reference said the walk and the predicate could not disagree. They
  can, and it now says which case and why — `matches?` performs nothing, so
  it cannot look at the disk. `FS.dir?` tells them apart and `FS.list_dir`
  reads a directory's entries. The test that covered this used a tree of
  files alone, so it could not have caught it
- Reading an instant built the date with `Printf.sprintf` and tested the
  characters after it by rebuilding a five-element list for each one
- `docs/reference.md` named the effect `FsRead`; it is `FS.Read`

One task is 4% slower: the pure arithmetic loop, 243 ms to 260 ms.
Bisecting the builds puts it on the change to the instant scanner, which
cannot run during that loop — the program is five lines and never lexes at
run time. It is a code-layout effect, reproducible and not attributable to
anything the change does.

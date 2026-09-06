# Admitting `Path` to the ordered set

`Path` is outside the ordered set, so `<` and `>` refuse it and `==`
compares the stored text. Two spellings of one file are therefore unequal.
This document is the design record for closing that: what the comparison
form is, why it is weaker than `Path.normalize`, and which end to do it at.
It is a record of decisions and their reasons, written before the code. It
is not a specification.

- [Path is not ordered, and could be](#path-is-not-ordered-and-could-be)
- [Admitting Path to the ordered set](#admitting-path-to-the-ordered-set)

## `Path` is not ordered, and could be

`Path`, `Glob`, `URL` and `Regex` are outside the ordered set. A path can
obviously be alphabetized, so this looks like an omission. It is not one,
and the reason is stated in the compiler:

> Ordering compares normalized values, never the stored string. A `DateTime`
> carries an offset, so two spellings of one instant must compare equal.

A path has several spellings for one file — `/a/b`, `/a//b`, `/a/./b`,
`/a/c/../b` — and `Path.normalize` exists but is not applied on the way in.
Ordering the stored text would therefore sort two names of one file apart,
which is the thing the rule above exists to prevent.

Two honest qualifications belong with that.

**Sorting paths already works.** `<` is not the only route:

```console
$ wand t -e 'List.sort [/b, /a]'
List Path
```

`List.sort` takes a list of any type, so alphabetizing paths is available
today. It is the operator that is withheld, not the capability.

**The inconsistency the rule prevents already exists at `==`.**

```console
$ wand -e 'import IO
IO.println (/a/b == /a//b)'
false
```

Equality compares the stored text too, so two spellings of one file are
already unequal. Withholding `<` is a decision not to *extend* text
comparison, rather than a guarantee that text comparison never happens.

**And the set is designed to grow.** The compiler says so where it builds
the error:

> The ordered set grows as types gain a normalizer, so the message names the
> type that is not in it rather than listing the set.

So `Path` is a candidate rather than a refusal. The next section is what
admitting it takes.

## Admitting Path to the ordered set

The work is not "apply `Path.normalize`". It is smaller than that in one
place and larger in another.

### The comparison form is weaker than `Path.normalize`

```console
$ wand d Path.normalize
Path.normalize : Path -> Path
Resolve . and .. components in a path.

Text only: nothing is asked of the file system, so a `..` is dropped
whether or not the directory above it exists.
```

That function resolves `..`, and `..` cannot be resolved without the file
system:

```
/a/c/../b       -- /a/b, unless c is a symlink to /x/y, in which case /x/b
```

Every lexical normalizer has this bug, and wand's is honest that it is text
only. But a comparison must not have it: saying two paths are equal when
they may be different files is worse than saying nothing. So the form used
for `==` and `<` applies only the rewrites that hold whatever the disk
contains:

| rewrite | example | safe |
|---|---|---|
| collapse repeated separators | `/a//b` → `/a/b` | yes |
| drop `.` segments | `/a/./b` → `/a/b` | yes |
| strip a trailing separator | `/a/b/` → `/a/b` | yes |
| resolve `..` | `/a/c/../b` → `/a/b` | **no** — symlinks |
| fold case | `/A/b` → `/a/b` | **no** — per filesystem |
| make relative absolute | `./b` → `/cwd/b` | **no** — needs an effect |

The last row is worth its own sentence. Resolving a relative path needs the
working directory, so it would make comparing two paths perform `FS.Read`
or `Env`. A comparison operator that carries an effect is not one wand
should have, so `./b` and `/cwd/b` stay unequal and that is correct.

`Path.normalize` keeps its behaviour and its name. It answers a different
question — *what is this path with the dots taken out* — and a caller who
wants `..` resolved against the real disk wants something else again, which
wand does not have and which would carry `FS.Read` when it arrives.

### Normalize at the comparison, not at construction

`DateTime` is the precedent, and it says which end to do this at. It stores
an offset and compares instants, so two spellings of one moment are equal
while the source keeps whichever spelling was written.

Paths follow. `Path.to_string` returns the text the script wrote, and the
comparison operators compute the form above. Nothing is lost, no literal is
rewritten behind the author's back, and the compiler's own rule is
satisfied literally: *ordering compares normalized values, never the stored
string.* It never said values are stored normalized.

### What this breaks

One thing, and it is a fix:

```console
$ wand -e 'import IO
IO.println (/a/b == /a//b)'
false                              -- today
true                               -- after
```

Two names for one file stop being unequal. Every script that compares a path
it built against a path it read back — from `FS.list_dir`, from a glob, from
a command's output — is a script that can be wrong about this today.

The reference lists **ten** ordered types. It becomes eleven, and the
`Comparison and Ord` table needs `Path` added.

### Glob, URL and Regex stay out

They are not the same problem wearing different names.

A `Glob` has no normal form worth the word: `*.wand` and `./*.wand` mean
different things by wand's own rule that a relative glob with a directory
part needs the `./` prefix, and `a*b*` against `a*b*c*` is a question about
languages rather than strings.

A `URL` has a normal form and it is a specification of its own — default
ports, percent-encoding case, trailing slash on an empty path, host case
against path case. `URL` already carries accessors for every part, so a
script that wants to compare origins can compare origins.

A `Regex` orders on nothing. Two patterns that match the same strings can be
written a dozen ways, and text order across them means nothing at all.

### Whether it is worth doing

The honest accounting: the valuable half is `==`, not `<`.

Sorting paths already works through `List.sort`, so admitting `Path` to the
ordered set buys the operators and little else — a path range check is not a
thing anyone wants. What it really buys is equality that answers about files
instead of about text.

That suggests a cheaper option worth naming before the breaking one is
taken: `Path.same?`, comparing the two paths in the form above, added
without touching `==` or the ordered set. It is honest, it is not a breaking
change, and it leaves `==` quietly wrong for anyone who does not know to
reach for it.

**Recommend the breaking change rather than `Path.same?`.** A predicate that
exists because the operator is wrong is a worse outcome than fixing the
operator, and wand has no outside users, so `==` changing its answer costs
nothing now and costs everything later.


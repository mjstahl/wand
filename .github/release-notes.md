## 0.63.0 - 2026-09-06

`Path` joins the ordered set. Two spellings of one file are now equal, and
`<`, `>`, `<=` and `>=` take a path.

### Equality answers about files, not about text

```ocaml
/a/b == /a//b          -- was false, is true
/a/b == /a/./b         -- was false, is true
/a/b == /a/b/          -- was false, is true
```

A path has several spellings for one file. Equality compared the stored
text, so two names of one file were unequal. Any script that compares a path
it built against one it read back -- from `FS.list_dir`, from a glob, from a
command's output -- could be wrong about this before.

Repeated separators, `.` segments and a trailing separator do not change
which file a path names. `./b` and `b` are one path for the same reason.

### The operators take a path

```ocaml
/a < /b                          -- true
List.sort [/a/c, /a//a]          -- [/a/a, /a/c]
Ord.max /a /b                    -- /b
```

The ordered set is eleven types now. `Ord.max`, `Ord.min`, `Ord.clamp` and
`Ord.between?` serve the new one without a new definition. `List.sort`
already took a list of anything, so sorting paths worked before; it now
sorts them by the same form the operators use.

### Three things a comparison will not do

- **It does not resolve `..`.** `/a/c/../b` is `/a/b` only while `c` is not
  a symlink. If `c` points at `/x/y`, the path is `/x/b`. Saying two paths
  are equal when they may be different files is worse than saying nothing.
- **It does not fold case.** Whether `/A/b` and `/a/b` are one file is a
  property of the filesystem, not of the text.
- **It does not make a relative path absolute.** That needs the working
  directory, and a comparison that performs an effect to answer is not one
  wand should have.

So `/a/c/../b`, `/A/b` and `./b` are each unequal to `/a/b`.

`Path.normalize` still resolves `..`, and still says in its own doc that it
is text only. It answers a different question.

### A path keeps its spelling

```ocaml
Path.to_string /a//b             -- "/a//b"
```

Nothing rewrites a literal. The comparison computes the form and the value
keeps the text that was written, which is how `DateTime` already works: one
instant has many spellings and the source keeps the one it used.

`Glob`, `URL` and `Regex` stay outside the ordered set. A glob has no normal
form worth the word. A URL's normal form is a specification of its own, and
`URL` already has an accessor for every part. Two regexes that match the
same strings can be written a dozen ways.

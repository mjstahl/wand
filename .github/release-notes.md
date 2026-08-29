## 0.55.1 - 2026-08-29

One fix, in two halves. `wand f` dropped the quotes on a map key that needs
them, and wrote source that does not parse.

### A map key keeps the quotes it needs

A quoted key was written bare whenever it was spelled like an identifier.
Two kinds of key are spelled that way and are not read that way.

**A keyword.**

```
$ cat m.wand
let a = {"type" = 1}

$ wand f m.wand
$ cat m.wand
let a = {type = 1}

$ wand t m.wand
Error: parse error: expected map key, got type
```

`type` lexes as a keyword wherever it stands, so the map ends at the key.
The formatter asks the lexer now, instead of keeping a keyword list of its
own — a list that has to be updated with the language is a list that will
not be.

**An uppercase name, in a map literal.** `{"Pod" = 1}` came back as
`{Pod = 1}`, which the expression parser refuses.

That one was allowed on purpose. The same function prints an import pattern,
and `let {TestOutcome, Pass} = import Test` names types and constructors,
which the *pattern* parser does read bare. Two parsers, opposite rules, one
function. The caller now says which parser will read the key.

`wand f` writes in place, so either shape turned a working file into one
that does not parse. Present in 0.55.0 and earlier.

### How it was found

The nightly fuzz run reported the keyword half. The uppercase half was
standing behind it and turned up while the first was being fixed.

This is the first finding the nightly filed on its own. The schedule had
never fired before — three separate crons and a probe workflow produced no
scheduled run at all — and it started working on 2026-08-28 without
intervention.

Nothing else changed. The command line, the type checker and the lint rules
are exactly 0.55.0's.

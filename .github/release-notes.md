## 0.56.0 - 2026-09-02

Every built-in type now has a module. Seven types had a literal, an order and
a place in the type checker, and nothing to read them with: `URL`, `Version`,
`Glob`, `IPv4` and `CIDR` had no module at all, and the two constructors that
did exist could not build every value of their own type.

This release closes both halves. It also changes what some literals mean, so
read the last section before upgrading.

### The types that could not be read

`URL` is the clearest case. A URL was a value you could write, interpolate,
compare and match on, and there was no way to reach its host. The module
follows the web platform's split, so `hostname` is the domain and `host` is
the domain with the port:

```
$ wand -e 'URL.hostname https://api.example.com:8080/v2/users'
"api.example.com" : String

$ wand -e 'URL.query https://example.com/s?q=two+words'
{q = "two words"} : Map String

$ wand -e 'URL.join "../v2/users" https://example.com/api/v1/orders'
Ok(https://example.com/api/v2/users) : Result String URL
```

`Version` is held to [Semantic Versioning 2.0.0][semver] -- its grammar, its
precedence rules and its FAQ. The language already ordered versions
correctly, so the module has no `compare`; it has the parts, and the step to
the next one.

`Glob` gained the question it was missing. `FS.glob` says which files a
pattern selects and needs `FsRead` to say it; whether a path is one the
pattern would select needs nothing, and could not be asked at all:

```
$ wand -e 'Glob.matches? **.wand ./src/deep/main.wand'
true : Bool
```

`CIDR` is the same shape. The one question anyone asks of a network could
only be answered by taking the text apart:

```
$ wand -e 'CIDR.contains? 10.0.0.0/8 10.1.2.3'
true : Bool
```

[semver]: https://semver.org/spec/v2.0.0.html

### The constructors that could not build every value

`String.to_url` and `String.to_version` decided whether text was a URL or a
version by handing it back to the lexer and asking whether it came out as a
single token. That made a rule about *writing a literal* into a rule about
the values themselves.

A URL literal ends at a `,` or a `;`, because they are the punctuation of the
expression around it. Both are legal in a URL. So a perfectly good URL had no
way to exist:

```
$ wand -e 'String.to_url "https://example.com/s?tags=a,b"'
Error("cannot parse ... as URL")        # 0.55.5
Ok(https://example.com/s?tags=a,b)      # 0.56.0
```

The same held for an IPv6 host, whose brackets end a literal too, and for
build metadata on a version, since `+` is the addition operator and
`1.2.3+1` cannot be told from arithmetic. `Decode.url` and `Decode.version`
had it as well, where it matters more: a decoder reads a document the program
did not write, and a `,` in a query string or a `v` on a git tag is ordinary
there.

Each grammar now lives in one place, checked by the literal, the constructor
and the decoder alike -- the arrangement the port range has always had, so
three readers of one rule cannot disagree. The errors improved as a side
effect. `String.to_url "ftp://x"` used to answer `"a comment is '-- ...' to
the end of the line, not '//'"`, which is true of the scanner and says
nothing about the URL.

### One crash, and one that was waiting

Comparing versions split the text on `-` to find the prerelease, so build
metadata put a `+` in front of `int_of_string` and `1.2.3+b` raised instead
of comparing. Nothing had reached it, because no constructor could build such
a value. Adding the constructor would have made it reachable, so it is fixed:
build metadata is ignored for precedence, which is what rule 10 requires.

`FS.glob` compiled its pattern with an engine that raises on an unclosed
character class. A literal cannot hold one, so nothing had reached that
either. `Glob.of_string` refuses it now, and reports rather than raising.

### The `?` convention, in both directions

A name ending in `!` says the function can raise, and that has been checked
both ways for some time: a function that raises without the `!`, and an `!`
that promises a raise which cannot happen. A name ending in `?` says the
function answers a question, and only one direction was checked -- a `?` name
had to return `Bool`, and a `Bool` could go unmarked.

`V-PRED3` closes it. It found two functions in the standard library, out of
354 exported signatures:

```
List.all  ->  List.all?
List.any  ->  List.any?
```

It fires on functions only. A `Bool` that is not one is a value rather than a
question: `let ready = 1 > 0` is a fact the program holds, and `ready?` would
promise a caller something to call.

### What this breaks

Five things, and the first two are the ones that will reach a working script.

**`List.all` and `List.any` are `List.all?` and `List.any?`.** Rename the
call sites; nothing else about them changed.

**`--strict` fails on an unmarked predicate.** A function of yours that
returns `Bool` and is not named with a `?` is now a `V-PRED3` violation.
Without `--strict` it is a warning, as every `V-` rule is.

**Two version literals stopped lexing.** `01.2.3` has a leading zero on a
numeric identifier and `1.2.3-alpha_1` has an `_`; semantic versioning admits
neither, and the literal is checked against the same grammar as
`Version.of_string`. `1.2.3-0a` is still a version -- only a *numeric*
identifier is barred from a leading zero.

**One URL literal shape stopped lexing.** A character that cannot appear in a
URL at all, such as `|` or `^`, is a lex error naming the rule. It has to be
percent-encoded, which is what it always had to be.

**`URL.host` means something else** -- the domain with the port. The domain
alone is `URL.hostname`. `URL` shipped in this release, so this can only
reach a script written against a build from `main`.

The tightening in both literals is the same decision: a literal must not be
able to write a value the checked constructor would refuse.

### Also

The CI workflows run their actions on Node 24. The repository is OCaml and
sets up no Node of its own, so this is the runtime GitHub's bundled actions
run on, nothing more.

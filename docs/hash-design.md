# Hash, and Base64

wand's own release pipeline cannot be written in wand. The `Makefile` writes
a checksum by running `shasum`, and `install.sh` carries a branch for the
machine where neither `shasum` nor `sha256sum` exists. This document is the
design record for `Hash` and `Base64`: what they hold, what they refuse, and
which choices were close. It is a record of decisions and their reasons,
written before the code. It is not a specification.

- [The case is already in the repository](#the-case-is-already-in-the-repository)
- [A String is a byte string](#a-string-is-a-byte-string)
- [Two modules, not one](#two-modules-not-one)
- [The algorithm is an argument](#the-algorithm-is-an-argument)
- [Digest is a type](#digest-is-a-type)
- [Comparison, and what the type cannot do](#comparison-and-what-the-type-cannot-do)
- [Which algorithms](#which-algorithms)
- [Base64](#base64)
- [Effects](#effects)
- [Where the implementation comes from](#where-the-implementation-comes-from)
- [What the tests get for free](#what-the-tests-get-for-free)
- [Left out on purpose](#left-out-on-purpose)

## The case is already in the repository

```makefile
cd dist && shasum -a 256 $(NAME).tar.gz > $(NAME).tar.gz.sha256
```

```sh
fail "neither shasum nor sha256sum is available to verify the download"
```

Two properties of that are worth naming, because they are the argument for
this module rather than a general wish for cryptography.

A script that checksums a file today declares `Shell(shasum)`, which tells a
reviewer that a binary ran and nothing about what was verified. And it does
not run everywhere: `install.sh` needs a fallback because the tool is not the
same tool on macOS and Linux. A digest is arithmetic. It should not depend on
which machine the script woke up on.

The other users are close behind. A deploy verifies an artifact. A webhook
receiver checks an HMAC signature. A basic-auth header is base64, and so is
every kubeconfig secret.

## A String is a byte string

This decides more of the module than anything else, so it is recorded first.

```ocaml
("str_length", VBuiltin (function | VString s -> VInt (String.length s) ...
```

A wand `String` is an OCaml `string`. There is no UTF-8 layer anywhere in
`lib/`. So a `String` already holds arbitrary bytes: `Base64.decode` can
return one without lying, and `Hash.string` can take one.

What a byte string does not give is a safe *description*. `String.length`
counts bytes rather than characters. `String.slice` cuts a multi-byte
character in half. Printing binary writes rubbish.

Two consequences run through the rest of this document. Hashing an
in-memory value needs no new type. And hashing a file gets a function of its
own — not because a `String` could not hold the bytes, but because a 2GB
archive should never become a value.

## Two modules, not one

`Hash` holds digests. `Base64` holds base64. They are not the same subject,
and the temptation to file base64 under `Hash` is only that both are
"encoding-ish".

The precedent is `URL.encode` and `URL.decode`, where an encoding lives with
the domain it belongs to. Base64's domain is itself, so it gets a module,
spelled in caps beside `CSV`, `JSON` and `TOML` — which are also formats
rather than subjects.

There is no `Encode` module. The name is one letter of intent away from
`Decode`, which is about reading structured values out of documents, and two
modules whose names are opposites but whose jobs are unrelated is a trap for
a reader skimming an import list.

## The algorithm is an argument

```ocaml
type Algorithm = Sha256 | Sha512 | Sha1 | Md5

Hash.string : Algorithm -> String -> Digest
Hash.file   : Algorithm -> Path -> Result String Digest   ! {FS.Read}
Hash.file!  : Algorithm -> Path -> Digest                 ! {FS.Read, Raise}
Hash.hmac   : Algorithm -> String -> String -> Digest     -- key, then message
```

The alternative is a function per algorithm per input — `Hash.sha256`,
`Hash.file_sha256`, `Hash.hmac_sha256`, then the same three again for each
of the other three algorithms. Sixteen names that differ by a substring is
sixteen chances to reach for the wrong one, and it makes adding an algorithm
a change in four places.

Four functions and a sum type says the same thing. It also puts the
algorithm somewhere a type can see it, which the next two sections need.

`hmac` takes the key first and the message second, because a key is usually
a value a script binds once and a message is what varies. Partial
application then reads as the thing being built:

```ocaml
let sign = Hash.hmac Sha256 secret
let a = sign body
```

## Digest is a type

`Hash.string Sha256 s` answers a `Digest`, not a hex `String`.

```ocaml
Digest.hex    : Digest -> String
Digest.base64 : Digest -> String
Digest.of_hex : Algorithm -> String -> Result String Digest
Digest.algorithm : Digest -> Algorithm
```

Two things follow that a `String` return would not give.

**A digest carries which algorithm made it.** Comparing a sha256 against a
sha512 is then a question the checker can answer, rather than a `false` that
looks like a failed verification. `Digest.of_hex` takes the algorithm for
the same reason: a 64-character hex string is a sha256 or half a sha512, and
which one it is comes from the caller who read it out of a file.

**One value, two renderings.** Checksum files are hex. S3 ETags and
subresource integrity are base64. A `String` return would need two families
of function to say the same thing twice; a type needs two accessors.

This is the same argument `Port` and `Version` already won. A digest is a
value with a shape and a meaning, and wand's answer to that is a type.

## Comparison, and what the type cannot do

Structural equality already works on any record:

```console
$ wand t -e 'type P(a: Int)
let x = P(a = 1) == P(a = 1)'
x : Bool
```

So `d1 == d2` will compile for digests too, and it will not be
constant-time. `Hash.equal?` is, and its doc says to use it when verifying a
signature someone else supplied.

**The limit is recorded rather than closed.** Making `==` an error on one
built-in type is a large carve-out in a language whose equality is uniform,
and the threat it answers is narrow: a timing attack on an HMAC comparison,
which needs an attacker who can send many requests and measure replies.
A deploy script comparing a published checksum is not that.

So `Hash.equal?` exists, the doc explains when it matters, and `==` is left
alone. Someone who needs the guarantee gets it by name. Someone who does not
is not stopped from writing the obvious thing.

## Which algorithms

`Sha256` and `Sha512` are for new work. `Sha1` and `Md5` are for interop and
the doc says so: git names objects with sha1, S3 ETags are md5, and older
checksum files are both.

Leaving the weak two out does not stop anybody using them. It sends them to
`Shell(md5sum)`, where the manifest goes back to naming a binary instead of
an operation, and where the macOS and Linux tools differ again. That is
worse on every axis this module exists to improve.

So they are included, named plainly, and documented for what they are.
`Hash` does not editorialise beyond a sentence, because a script reaching
for md5 to match an ETag is not making a mistake.

## Base64

```ocaml
Base64.encode     : String -> String
Base64.decode     : String -> Result String String
Base64.encode_url : String -> String
Base64.decode_url : String -> Result String String
```

Two alphabets, because both are load-bearing. The standard alphabet is
RFC 4648 §4 and is what a basic-auth header and a kubeconfig secret use. The
URL-safe alphabet is §5, with `-` and `_` in place of `+` and `/`, and is
what a JWT and a query parameter use. A single function with a flag would
put the choice in an argument that reads as a detail; it is not one, because
the two are not interchangeable.

**`encode` pads. `decode` accepts padded and unpadded input.** Padding is
required by the standard and omitted by most JWT producers, so a decoder
that insisted on it would reject the input people actually have. Being
strict on the way out and lenient on the way in is the only combination that
round-trips against the rest of the world.

**`decode` returns a `Result`.** Invalid base64 is a value-level failure with
a reason, like every other parse in the standard library. The `!` sibling
raises, as the naming rule requires.

## Effects

`Hash.string`, `Hash.hmac` and every `Base64` function are **pure**. They
touch nothing outside the program and answer the same twice, so they fit
none of the three justifications a label needs and carry none. A script that
hashes a string in memory declares nothing.

`Hash.file` carries `{FS.Read}`, and `Hash.file!` adds `Raise`. It streams
the file rather than reading it into a value, which is what makes a checksum
of a release archive possible at all.

That split is the whole effect story, and it is worth noticing that it falls
out of the existing rules rather than needing new ones.

## Where the implementation comes from

Two ways, and this is the choice to settle before writing code.

**`digestif`** is pure OCaml and covers all four algorithms plus HMAC. It
needs its transitive closure checked against the static musl build first —
that build already compiles dune from source and is retried three times on
the runners, so every added package is a package that can fail there.

**Writing them** is roughly four hundred lines. That is more code than
anyone wants to volunteer for, with two properties that make it unusually
defensible here: the algorithms are frozen and will never need a change, and
every one of them has official test vectors, so the code is either right
against a published list or it is not.

The recommendation is to price `digestif` first and treat writing them as
the fallback rather than the ambition. wand's whole distribution story is
one file that carries its own standard library, and a dependency that
breaks the musl build costs more than four hundred lines that never move.

## What the tests get for free

Every algorithm here has published vectors: NIST for the digests, RFC 2202
for HMAC, RFC 4648 for base64. So the Alcotest suite and the `>>` doc
examples both have exact expected values rather than judgement calls, and
`tools/check_docs.wand` gates them like everything else.

This is the cheapest item on the standard library list to get provably
right, and it is a reason to do it early rather than late.

## Left out on purpose

**Encryption, signing, key exchange.** A digest is arithmetic over bytes.
A cipher is a promise about secrecy, with modes, nonces and key handling
behind it, and getting one detail wrong fails silently. Nothing on wand's
list of jobs — deploys, CI glue, cron, log processing — needs one.

**A `Bytes` type.** A `String` already holds bytes. What is missing is a
type that stops `String.length` from describing them as characters, and that
is a language-wide question about text, not a question this module should
answer on its own.

**bcrypt, scrypt, argon2.** Password hashing is a different problem with
different parameters, and a scripting language for deploys is not where a
password database should be built.

**`Hash.equal?` on anything but a `Digest`.** A constant-time comparison of
two arbitrary strings is a reasonable thing to want and a hard thing to
name safely. It can be added when something asks.

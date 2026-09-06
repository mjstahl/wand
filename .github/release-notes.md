## 0.61.0 - 2026-09-05

`Hash`, `Digest` and `Base64` are new, so a script can checksum a file
without a subprocess. `Int` and `Ord` close a gap `Float` did not have.
`List` and `Stream` gain their aggregates. `String.chars` becomes
`String.bytes`, and the reference now says what a `String` is.

### `Hash`, `Digest` and `Base64`

```ocaml
uses {FS.Read}
import Digest
import Hash
let {Sha256} = import Digest

Hash.file! Sha256 ./dist/wand.tar.gz |> Digest.hex
```

A checksum written by `Shell(shasum)` tells a reviewer that a binary ran
and nothing about what was verified, and it does not run everywhere: the
tool is `shasum` on macOS and `sha256sum` on most Linux images. A digest is
arithmetic. It should not depend on which machine the script woke up on.

```ocaml
Hash.string : Algorithm -> String -> Digest
Hash.file   : Algorithm -> Path -> Result String Digest  ! {FS.Read}
Hash.file!  : Algorithm -> Path -> Digest                ! {FS.Read, Raise}
Hash.hmac   : Algorithm -> String -> String -> Digest
Hash.equal? : Digest -> Digest -> Bool
```

`Sha256`, `Sha512`, `Sha1` and `Md5`. The weak two are here for interop and
named as such: git names objects with sha1 and S3 ETags are md5. Leaving
them out would not stop anyone using them, it would send them to
`Shell(md5sum)`.

**Hashing performs nothing.** `string`, `hmac` and every `Base64` function
reach nothing outside the program and answer the same twice, so they carry
no label and a script that uses them declares nothing. Only `file` reaches
outside, and what it carries is `FS.Read` for the read. It goes through an
`FS!hash_file` operation, so `--dry-run`, `--trace` and a test's mock see
it the way they see `FS!read_file`, and it reads the file in blocks rather
than turning a release archive into a `String`.

**A digest is a type.** It carries the algorithm that made it, so comparing
a sha256 against a sha512 is a question the checker answers rather than a
`false` that reads like a failed verification. And one value renders two
ways:

```ocaml
Hash.string Sha256 "abc" |> Digest.hex
-- "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
Hash.string Sha256 "abc" |> Digest.base64
-- "ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0="
```

`Hash.equal?` compares in constant time. `==` compares digests too and does
not. Use `equal?` when the digest on one side came from somebody else -- a
webhook signature, a token. A deploy script checking a published checksum
is not that case.

`Base64` has both alphabets, because both are load-bearing: RFC 4648
section 4 for a basic-auth header and a kubeconfig secret, section 5 for a
JWT and a query parameter. `encode` pads and `decode` takes input either
way, which is the only pairing that round-trips against the rest of the
world.

wand's own release pipeline uses this now. `tools/checksum.wand` writes the
`.sha256` beside each archive, in `shasum -a 256` format byte for byte.

### A `String` is bytes

A new section of the reference says so, and says which functions are safe
on any input and which are not. There is no encoding layer, and that is the
right model for a language that reads log files, shell output, filenames
and configuration: a `String` that validated UTF-8 would refuse to open a
file with one badly-encoded line in it.

`String.chars` returned one string per *byte* and called them characters.
It is `String.bytes` now.

`String.truncate` is new, and is the one function in `String` that knows
about UTF-8. It takes at most n bytes and never ends inside a character,
which is what cutting text down for display needs:

```ocaml
String.slice 0 4 "café"       -- four bytes, the last one half of the é
String.truncate 4 "café"      -- "caf"
```

`String.length` keeps its name and keeps counting bytes. The question
people reach for it with is a width check, and a character count does not
answer that either: a CJK character occupies two terminal columns and a
combining mark occupies none.

### `Ord` and `Int`

```ocaml
Ord.max      : Ord -> Ord -> Ord
Ord.min      : Ord -> Ord -> Ord
Ord.clamp    : Ord -> Ord -> Ord -> Ord
Ord.between? : Ord -> Ord -> Ord -> Bool
```

The four functions people write out of `<` and `>`. One definition serves
all ten ordered types, so `Ord.max 30s 2min` and `Ord.max 1.9.0 1.10.0` are
the same function rather than nine copies of it.

`Int.abs`, `Int.pow`, `Int.divmod`, `Int.max_value` and `Int.min_value` end
an asymmetry: a script wanting the absolute value of a `Float` had
`Float.abs`, and one wanting it for an `Int` wrote the conditional.

### `List` and `Stream` aggregates

```ocaml
List.sum : List Add -> Option Add
List.max : List Ord -> Option Ord
List.min : List Ord -> Option Ord
```

Each starts from the first element rather than from a literal zero, which
is what keeps them polymorphic -- a `0` would be an `Int` and would pin the
list to `Int`. So `List.sum [1KB, 500B]` is `Some(1500B)`. Supply the unit
where it is known: `List.sum sizes |> Option.default 0B`.

Two of the shipped examples stop folding a total by hand:
`examples/ports/dir-budget.wand` summed file sizes with
`List.fold_left (fn total size -> total + size) 0B`, and
`examples/ports/pod-restarts.wand` summed restart counts the same way.

`Stream` gains nine terminals: `count`, `last`, `empty?`, `any?`, `all?`,
`find`, `sum`, `max` and `min`. Four of them stop reading as soon as the
answer is settled, so a match near the head of a 10GB log costs the head of
that log:

```ocaml
FS.stream_lines /var/log/app.log
|> Stream.any? (fn l -> String.contains? "PANIC" l)
```

It is `count` rather than `length`, because `List.length` sounds free and
this is not: counting reads the whole source, and counting twice reads it
twice.

### Also

- A constructor that takes no payload hands the bracket back to the call.
  `Hash.string Sha256 (body ++ "\n")` used to be an error, because a
  bracket after a constructor is its payload. Nothing that compiled before
  changes meaning. 0.50.0 answered this by telling you to write `(Sha256)`
  and offering that through `wand t --fix` and the editor's code action;
  both are gone, because there is nothing left to correct. Where there is
  no call to take the argument -- `let r = Red (1)` -- it is still an
  error, and says to write `Red` with nothing after it
- Every stdlib module that declares a type is usable from the REPL and from
  `-e`. A session dropped the types an import brought in, so
  `Digest.Sha256` and `Test.Pass` failed unless the same step wrote the
  import
- The reference listed `CIDR` as unordered while also listing it among the
  ten ordered types. `10.0.0.0/8 < 192.168.0.0/16` typechecks and always
  has; only the sentence was wrong

### Renamed

`String.chars` is now `String.bytes`. Same behaviour, and the name is what
was wrong: it returned one string per byte.

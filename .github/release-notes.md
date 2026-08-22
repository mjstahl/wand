## 0.40.0 - 2026-08-22

A type can have another name.

    type Point = (Int, Int)
    type Ids   = List Int
    type F     = Int -> Int
    type This  = That

`type X = <a type>` is an alias: another name for a type that already
exists, rather than a new one. It is transparent — the two are one type,
interchangeable in both directions — so it buys a name to read and write,
not a distinct type. Nothing stops a `(width, height)` where a `Point` is
meant; a record, `type Point (x : Int, y : Int)`, is what the checker keeps
apart.

A type shows with the alias it was written as, so the name in the source is
the name in the message:

    let p : Point = (1, 2)        -- p : Point (= (Int, Int))

`type Point = (Int, Int)` and `type F = Int -> Int` did not parse at all
before this.

### A name declares one thing

Two `type` declarations of one name, or two constructors sharing one, were
taken silently — and which of them won differed between a file and the
REPL, so one text had two meanings. The loser did not merely lose: it
stayed constructible and stopped being matchable, so a declared type could
no longer be taken apart and nothing had said why.

A file refuses it now, naming which declaration to rename. The REPL still
replaces, which is what a REPL is for.

A built-in's name is taken too. `type Size(a: Int)` was accepted, and then
field access on the result answered "field access requires a named type,
got Size" — the name resolved to the built-in while the constructor came
from the declaration. Ten names did this.

And a name that is a type rather than a constructor now says so, instead of
being called unknown and sending you after a declaration that is right
there.

### `Url` is `URL`

An acronym is written in capitals, which `IPv4`, `CIDR`, `JSON`, `TOML` and
`CSV` already were. The old spelling is an unknown type whose hint names the
new one — which meant teaching that hint about built-in type names at all,
so `Strig` now suggests `String`.

---

One line installs it — platform detection, checksum verification, and a
smoke test included:

    curl -fsSL https://raw.githubusercontent.com/mjstahl/wand/main/install.sh | sh

Or download the archive for your platform, unpack it, and put `wand` on
your `PATH`. The binary carries its own standard library, so it runs from
any directory with nothing else installed.

| | |
|---|---|
| `linux-x86_64`, `linux-aarch64` | static musl builds; no libc on the machine is needed |
| `macos-aarch64`, `macos-x86_64` | not notarised, so a download is quarantined until you clear it |

On macOS:

    xattr -d com.apple.quarantine wand

Checksums are the `.sha256` files beside each archive. Verify one next to
the download with `shasum -c wand-<version>-<platform>.tar.gz.sha256`.

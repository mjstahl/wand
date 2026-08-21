## 0.30.0 - 2026-08-21

Cons is `::`.

    1 :: [2, 3]

    match xs with
    | [h :: t] -> h
    | []       -> 0

`:` used to mean two things: it joined a head to a list, and it gave a name
a type. It now means the type, and a port literal, and nothing else.

The overload cost a rule. A cons pattern had to be bracketed because
`(h : t)` could not be told from a parameter carrying a type, and a
parameter annotation was read only when a type token followed the `:`.
That lookahead is gone with the ambiguity that needed it.

### Migrating

`:` as cons is still read, and `wand f` writes `::`. So the migration is:

    wand f script.wand

It becomes a parse error in the next release. This one breaks nothing.

### Also

A bare `h :: t` pattern is read, and `wand f` writes `[h :: t]` — the
brackets say list, the way `[a, b, c]` does. `Some h :: t` is
`(Some h) :: t`.

A pattern carries a type inside a constructor's payload now:

    match JSON.decode Pod.decoder doc with
    | Ok (p: Pod) -> p.status.restarts
    | Error why   -> 0

That is where a decoder's result lands, and it was the one place a pattern
could not be annotated.

`V-IMP1` warns on any two imports that bind one name. It used to stop at
the first item of anything else, on the reasoning that a later rebinding
might follow a genuine use of the first. It cannot: imports bind before a
file's own bindings wherever they are written, so a use between two imports
already reads the second.

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

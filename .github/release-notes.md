## 0.24.0 - 2026-08-21

A parameter can carry its type.

    let describe (p: Pod) = p.name

    let f = fn (p: Pod) -> p.status.restarts

    List.filter (fn (p: Pod) -> p.status.restarts > 5) pods

This is what lets a function read a field off a parameter. Dot access needs
a named type. wand generalizes a definition before it sees any call, so the
type has to come from the definition, and there was nowhere to write it:

    let describe p = p.name
    -- type error: field access requires a named type, got 'a

Two ways round it worked before: re-bind through an annotated `let`, or
destructure with `match`. Each costs a line and an indent for every record,
and the cost grows with the depth of the record.

The annotation works in each place a pattern does: a `let`, a `fn`, an arm
of a `match`, and a `with ... as`. It composes with the return annotation:

    let describe (p: Pod) : String = p.name

The parentheses are part of the syntax. A `:` between expressions is cons.

`(x : xs)` still reports the cons message. Cons in a pattern is `[h : t]`,
in brackets, so the parenthesised form was never a pattern at all. One token
tells the two apart: a type starts with `Upper`, `'a` or `(`.

A type variable in a parameter is a type error:

    let f (x: 'a) = x
    -- type error: a type variable in a pattern is not shared with the other
    --   patterns ... Write the type of the whole definition instead

Each annotation resolves its own names, so `'a` in two parameters would be
two variables, and you would have been promised one.

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

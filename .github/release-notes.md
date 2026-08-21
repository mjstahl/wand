## 0.31.0 - 2026-08-21

`:` is no longer cons.

    1 : [2, 3]
    -- parse error: cons is '::' -- a single ':' gives a name a type

0.30.0 read both spellings so that a script written before it would run
long enough to be formatted. This removes the old one. `:` is a type
annotation or a port literal, and nothing else.

The `:` still binds where cons bound, so the error lands on it rather than
appearing as "expected ->, got :" from wherever the expression happened to
end.

### Migrating

    wand f script.wand

Then fix whatever still fails to parse. `wand f` is most of a migration
and not all of it: it does not rewrite a construct holding an interior
comment, because the construct is pinned and written back as it stands so
the comment does not move. Five cons patterns in wand's own standard
library were pinned that way and survived a 90-file sweep. They surfaced
when `:` stopped parsing, which is what this release does.

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

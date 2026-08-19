## 0.18.1 - 2026-08-19

Running commands got faster. A `$()` in which the shell would find
nothing to do — no operators, expansions, quotes, or builtins — is
exec'd directly, skipping `/bin/sh`'s startup on every spawn: 200 spawns
of a trivial command drop from 1.6s to 0.5s, ahead of the same loop
written in bash. Anything the shell might act on runs through `/bin/sh`
exactly as before, and the two are indistinguishable in meaning.

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

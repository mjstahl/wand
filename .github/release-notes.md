## 0.34.0 - 2026-08-22

A comment is `--` to the end of the line, and that is the whole form. It
reads no brackets, so pasted text survives whatever it holds.

### Documentation is a run of comment lines

    -- Whether a command succeeded: its exit code is zero.
    --
    -- `$?(cmd)` gives a `ShellResult`, and the first thing a script asks
    -- of one is whether it worked.
    let ok? (r: ShellResult) = r.code == 0

`wand d` prints it, and so does an editor on hover. Each line stands alone,
the lines are consecutive, and the last one sits on the line above the
definition. A comment after code documents nothing, and a blank line ends
the run.

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

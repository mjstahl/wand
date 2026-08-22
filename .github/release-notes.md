## 0.35.0 - 2026-08-22

A race inside a handler is refused. Move the handler inside each thunk,
where it stands for that branch and the race still runs:

    Par.race [
      fn () -> Test.with_shell mocks (fn () -> probe a),
      fn () -> Test.with_shell mocks (fn () -> probe b)
    ]

An effect cannot reach a handler on another domain, so the branches cannot
run where they were written. The race answered with its first thunk and
said nothing, so a test of racing code tested one branch and passed.

`--dry-run` and `--trace` still run a race, left-biased. Each reports what
the work would do, and the collapse costs the report nothing.

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

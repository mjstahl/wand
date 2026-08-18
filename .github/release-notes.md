## 0.17.0 - 2026-08-18

Maps move to braces — the form your hands already know:

    let pod = {name = "web-01", restarts = 4}
    let {name, restarts = n} = pod        -- punning, and a rename
    let {test} = import Test

`{}` is the empty map (`Map.empty` stays), map values print in braces,
and brackets now mean lists and nothing else. The old `[x = 1]` forms
still parse this release: `wand fmt` migrates whole files, `wand t --fix`
applies the `A-MAP1` finding's carried fix line by line, and the brackets
are removed in the next release.

Also in 0.17.0: a single-constructor type whose constructor repeats the
type's name formats as the shorthand — `type Container(name: String,
ready: Bool)`.

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

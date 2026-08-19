## 0.18.0 - 2026-08-19

Brackets mean lists and nothing else. The pre-0.17 map forms — `[x = 1]`
literals, `[x = a]` patterns, and `let [test] = import Test` — no longer
parse.

    a map is written in braces -- {k = v}, not [k = v]

The `A-MAP1` finding retires with the syntax.

`<=` and `>=` order strings, as `<` and `>` always did.

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

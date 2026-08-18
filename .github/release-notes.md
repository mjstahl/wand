## 0.14.0 - 2026-08-18

### Added

- Add `--json` to `wand d`: one object on stdout — `name`, `type`, `doc` — with a fact the session lacks reported as `null` rather than omitted, so "no doc" reads as an answer and not a schema difference (`6f12546`)
- Add `--json` to `wand v`: an array over the scope, bindings as `{"name","type"}` and modules as `{"name","module":true}`; `wand v --json <module>` lists the members with qualified names, so an entry feeds straight into a follow-up `wand d` or `wand t` (`6f12546`)
- Add `--json` to `wand s`: one object for the whole run — per-test entries under `tests` (a pass carries its `label`, a fail its `message`; a test that raised reports `"error"`, and both count as failed), files that would not load under `errors`, and the `passed`/`failed` counts. While the tests run their own prints go to stderr, so stdout holds nothing but the JSON; exit codes are unchanged (`6f12546`)

With these, every command whose output a tool might read — `t`, `d`, `v`, `s` — has a `--json` form. Each shape is documented in the reference's `--json` section.

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

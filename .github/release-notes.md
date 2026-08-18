## 0.15.0 - 2026-08-18

The editor answers more, more readably. Hover now types local names —
parameters, `let ... in` names, pattern variables — at the binder and at
every use, and renders every answer as the name over its type, so effect
rows stay whole. Completion items carry the same block plus the doc string
in the expandable panel. The VS Code extension (0.2.0) installs with one
`make install`, finds the wand binary even when a Dock-launched VS Code
has no shell `PATH`, and puts the Rehearse lens on every file without
blocking on stdin.

### Added

- Hover for locals: `tally` in a reducer answers `tally` / `: Map Int`,
  wherever it appears (`65319f5`)
- Completion documentation: signature as name-over-type, doc string
  beneath, one chevron away (`65319f5`)
- `make install` in `editors/vscode/` builds, packages, and side-loads the
  extension in one step (`cacba1e`)

### Changed

- Hover renders name over type; long effect rows no longer wrap mid-row (`65319f5`)
- The extension resolves the wand binary via `~/.local/bin` and Homebrew's
  prefixes when `PATH` has none (`cacba1e`)
- The Rehearse lens appears on every file — first line when there is no
  manifest — and rehearses against `/dev/null` instead of blocking on
  stdin (`cacba1e`)

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

## 0.16.0 - 2026-08-18

Two formatter changes, both about writing what you meant more plainly.

### Changed

- A match nested inside another match's arm now formats as an indented
  block: the opening paren ends the arrow's line, the nested match sits
  two spaces deeper than the outer arm, and the closing paren returns to
  the outer arm's column:

      | Some l -> (
        match Map.get l tally with
        | None -> Map.set l 1 tally
        | Some n -> Map.set l (n + 1) tally
      )

  Handler arms with a match body format the same way (`44e66fe`)
- A string escaping its quotes moves between backticks, where a quote is a
  quote: `"say \"hi\""` becomes `` `say "hi"` ``, splices intact. The
  quoted form stays when backticks could not reproduce the value exactly
  and visibly — a backtick in the text, a literal `%{`, or control
  characters (`9624144`)
- The demos and decode examples are reformatted accordingly — inline JSON
  in the examples loses its backslashes (`44e66fe`, `9624144`)

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

## 0.38.0 - 2026-08-22

`wand f` now formats the inside of a definition that has a comment in it.

One comment anywhere inside a top-level definition used to make the whole
definition a verbatim copy of the source. None of its code was formatted,
and `tools/check_fmt.wand` could not see in either — so a definition was
exempt in proportion to how well it was commented. Ten files in this
repository held definitions the formatter had never once formatted.

    let f xs =
      match xs with
      | [] -> 0
      -- why the next arm is what it is
      | [h :: t] ->    h+1        -- this line was never formatted

A comment on its own line is now written above the match arm, block
statement or list element it sits on, and the rest is printed as usual.

### What is left alone

A comment that follows code on its line is about that code. Lifting it onto
a line of its own would point it at the line below, so its definition is
left exactly as written.

Every comment is counted in the formatted definition, and anything but
exactly once puts the definition back to a verbatim copy. A comment cannot
be dropped, duplicated or moved.

### Also fixed

A `let ... in` arm body too wide for the arrow's line put its continuation
at the arm's own indent, level with the `|` above it, where it read as the
next arm rather than the rest of this one. It now takes the block shape a
nested match takes. This was a separate fault that the old behaviour had
been hiding.

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

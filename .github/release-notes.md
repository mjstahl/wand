## 0.27.0 - 2026-08-21

A binding in a block lives for the rest of the block.

    let deploy! release work = (
      let stage = Path.join work (Path.of_string "pkg");
      let archive = Path.of_string "./dist/%{release}.tar.gz";
      FS.mkdir! stage;
      FS.copy! archive stage;
      "deployed"
    )

`;` ends the binding's right-hand side, exactly as a newline does at the top
level of a file. So a block and a file read the same way, and naming two
values costs no indentation. Before this, a body that named two
intermediates nested twice:

    let stage = Path.join work (Path.of_string "pkg") in (
      let archive = Path.of_string "./dist/%{release}.tar.gz" in (
        FS.mkdir! stage;
        ...
      )
    )

The same three words parsed before and bound nothing. The binding took
`Unit` for a body and died where it stood, and the error named the use site,
which is not the mistake.

`let ... in` keeps its own meaning: it names a value for one expression. In
`(let x = 1 in x + 1; 9)` the `x` belongs to `x + 1` and to nothing else.

`wand f` writes the block form when more than one statement follows a
binding, and `let ... in` when one expression follows it — there the two say
the same thing, and `in` is the older spelling.

### Two things to know before upgrading

A block cannot end with a binding. Nothing would read the name:

    (f (); let x = 1)
    -- parse error: this binding has no body

A binding that bound nothing now binds, so one program answers differently:

    let x = 0 in (let x = 1; x)     -- was 0, is 1

Every other program this touches is one that does not typecheck today.

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

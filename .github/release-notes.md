## 0.20.0 - 2026-08-19

Reading a file is `FS.Read`, whichever module parses it. `JSON.read_file`,
`CSV.read_file` and `TOML.read_file` reached the disk through builtins of
their own and declared no effects at all, so this typechecked, asked for
nothing, and read the file:

    import JSON

    match JSON.read_file (Path.of_string "/etc/passwd") with ...

That is the manifest's whole promise broken. It also meant a handler
mocking the filesystem did not stand in for them, and `--dry-run` could
not see them. All six now read through the same operation every other
reader performs, so the effect is real rather than declared.

**This is breaking.** The three modules gain `! {FS.Read}`, and their `!`
siblings `! {FS.Read, Raise}`. A script that reads a config through any
of them needs `FS.Read` in its manifest, and `wand t --fix` writes the
line.

An editor can now say what an effect operation is. Typing `FS!` lists all
twenty, with what a case binds and resumes with, and the sentence a
handler author actually wants:

    FS!write_file
    : (Path, String) -> Unit

    Handles the FS.Write effect of FS.write_file and FS.write_file!.

Nothing was offered before, so whatever appeared came from the editor's
own guess at the words in your buffer — which is why an operation arrived
with no type and no text, and why it took the first letter to find one.

The claim about what performs an operation is the one part no analysis
can supply, so it is checked rather than trusted: a test runs every
performer under a handler for its operation. Writing it is what found the
hole above.

`wand f` closes a bracket that ran onto more lines on a line of its own
rather than wherever the last line ended, and stands a manifest and the
import block off from what follows them. It also no longer emits source
that does not parse — three ways it could, all of them waiting for a line
long enough to wrap. The format gate now covers the tests and examples as
well as the standard library, 69 files against 22, which is how the last
of those was found.

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

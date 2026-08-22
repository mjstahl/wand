## 0.37.0 - 2026-08-22

Printing comes from a module.

    uses {IO}
    import IO
    IO.println "hi"

`print` and `println` were the only functions a file could call without an
import. They are gone. Printing is `IO.print` and `IO.println`, and a file
that prints writes `import IO`.

One rule is now true with no exceptions: every function a file calls comes
from a module it imported. `Ok` and `Error` stay — constructors of a
built-in type have no module to come from.

### Updating a script

The old spelling names the new one where the mistake is:

    unbound variable 'println' -- printing is IO.println (import IO)

That is the same answer `printf`, `puts` and `echo` already gave. Add
`import IO`, and write the calls qualified.

### Also fixed

Comparing two functions raises, whichever functions they are. `==` and
`List.sort` waited for the runtime to reach the function inside, so two
wand-defined functions whose bodies already differ compared as ordinary
values and sorted into an order that meant nothing.

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

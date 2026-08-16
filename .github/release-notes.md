## What's new in 0.10.0

- **Manifests can name binaries: `uses {Shell(git, curl)}`.** Literal
  command words — the first word of each `$()`/`$?()` and of every
  top-level `|`/`&&`/`||`/`;` stage — are checked by `wand t`, which also
  suggests the narrowed line when it can read every word. A word decided
  at run time is checked at the moment of spawn, catchably, and never
  under a test mock or `--dry-run`. Names are written as they are inside
  `$()` — `Shell(git, docker-compose, ./probe.sh)` — and bare `Shell`
  still means any binary. The demos and examples now narrow their own
  manifests.
- **`;` sequences statements inside parentheses.** A function body chains
  as `let deploy! t = ( FS.mkdir! ...; "deployed" )` — no more
  `let () = ... in`. A `Result` discarded by `;` is flagged like any
  other. The examples and demos are rewritten in this style, named in the
  reference as "Style for scripts".
- **Foreign syntax gets a correction, not a syntax error.** `h :: t`,
  `let rec`, `Circle of Int`, `try ... with`, `\x ->`, `(x:xs)`,
  `and`/`or`/`not`, `//` and `#` comments, `#{x}`, `:=` — each names the
  wand spelling; unbound `ref`, `raise`, `puts`, `lambda`, `len`, ... do
  the same.
- **`wand t --json` grew a full diagnostic schema**: severity, stable
  codes (including `E-TYPE`/`E-PARSE`/`E-LEX` for errors), typed-hole
  shapes, and machine-applicable `fix` payloads — the exact manifest line
  to insert, or `{from, to}` for drift corrections.

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

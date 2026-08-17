## What's new in 0.11.0

- **Arithmetic is polymorphic over `Int` and `Float`.** One spelling —
  `3.14 * r * r` just works — with one numeric type per expression,
  never mixed implicitly. `Num` in a signature means "`Int` or `Float`,
  decided at use", and an unpinned `let double x = x + x` serves both.
  The new `Float` module carries the crossings (`of_int`, `round`,
  `floor`, `ceil`, `abs`); `%` stays `Int`-only.
- **`Stream`: fold a 10GB log in bounded memory.** A stream is an inert
  recipe — `FS.stream_lines log |> Stream.filter p |> Stream.fold_left
  f init` opens, streams, and closes inside the fold, and `take n`
  stops the reading. Sources for files and stdin, `Test.with_lines`
  for mocking, failures caught with `try` at the fold. Folding twice
  re-runs the recipe.
- **Error messages, round two** — grown from a measured cold-model run
  (55 attempts and five failures under v0.9.2's errors; 24 and none
  with the full v0.10.0+ toolchain): `^` names `++`, the OCaml float
  operators name themselves instead of lexing into glob gibberish,
  char literals and `begin/end` name their corrections, `List.iter`
  says `use List.each` instead of a misleading edit-distance guess,
  and unbound names with no better answer hand over the discovery
  loop: `'wand env' lists the modules, 'wand env List' one module's
  members`. All messages now name the construct, not a language —
  `cons is a single ':', not '::'`.

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

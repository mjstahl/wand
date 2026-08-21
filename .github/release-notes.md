## 0.26.0 - 2026-08-21

Four more types compare, and sorting them answers differently than before.

### Size, Version, Port and IPv4

Each was a type error under `<`, `>`, `<=` and `>=`:

    100MB < 1GB              -- was a type error, is true
    1.10.0 > 1.9.0           -- true; the numbers are numbers
    10.0.0.9 < 10.0.0.10     -- true; the address is its 32 bits
    :80 < :443               -- true

A `KB` is 1000 bytes. The spelling is the SI one, and the lexer has no
`KiB`, so reading it as 1024 would misname the unit you wrote.

`Version` follows semver precedence, prerelease rules included:
`1.2.3-alpha.1 < 1.2.3-alpha.2 < 1.2.3-beta < 1.2.3`.

### Sorting answers differently

`List.sort` used to compare the text of these values. It reads the value
now:

    List.sort [10.0.0.10, 10.0.0.9, 10.0.0.2]
      was [10.0.0.10, 10.0.0.2, 10.0.0.9]
      is  [10.0.0.2, 10.0.0.9, 10.0.0.10]

    List.sort [1.10.0, 1.9.0, 1.2.3]
      was [1.10.0, 1.2.3, 1.9.0]
      is  [1.2.3, 1.9.0, 1.10.0]

    List.sort [1GB, 999MB, 100B]
      was [100B, 1GB, 999MB]
      is  [100B, 999MB, 1GB]

A script that sorted addresses, versions or sizes was getting the wrong
order and had no way to say so.

### Equality reads them too

    1000B == 1KB                   -- true
    01.2.3 == 1.2.3                -- true
    192.168.001.1 == 192.168.1.1   -- true

So the three relations agree: a value written two ways is equal, and it is
neither below nor above.

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

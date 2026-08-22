## 0.36.0 - 2026-08-22

wand can read the clock.

    Clock.now () - FS.mtime! log > 30d     -- older than thirty days
    Clock.now () + 1h                      -- an hour from now

`Clock.now` answers the current instant in UTC. A `Duration` moves an
instant, and two instants subtract to the length between them. Two instants
do not add, and a `Duration` does not subtract an instant.

### Measuring how long work took

    let (took, report) = Clock.timed (fn () -> build ())

`Clock.timed` is the only way wand measures a length of time. It reads a
clock that no correction can move, so it stays right across an NTP step.
Time while the machine is suspended counts. `V-CLOCK1` names it when a
length comes from subtracting two readings of `Clock.now`.

### Testing it

    Test.at 2026-03-01T00:00:00Z (fn () -> stale? log)

Reading the clock is an effect, so a handler answers it. `Test.at` pins the
instant, and a test of an age needs neither a real file nor a wait.

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

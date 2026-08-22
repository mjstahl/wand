## 0.39.0 - 2026-08-22

There is one type for a point in time, and a module that opens it.

    DateTime.day_start (Clock.now ())              -- today at midnight
    DateTime.on! 2026 8 22 + 14h + 30min           -- 2026-08-22T14:30:00Z
    "backup-%{DateTime.date_string (Clock.now ())}.tar.gz"

`Date` and `DateTime` both meant a point in time. Both compared, both
subtracted to a `Duration`, and a `Date` was already read as midnight UTC —
the language stated the equivalence and kept two types anyway. Now
`2026-08-22` is a spelling of `2026-08-22T00:00:00Z`.

### Taking one apart

`DateTime` answers `year`, `month`, `day`, `hour`, `minute`, `second`,
`weekday` and `day_start`. Nothing in it reads a clock; `Clock.now` does
that, and this module takes what it answers apart. `weekday` is ISO 8601,
Monday 1 through Sunday 7.

`on` is the only builder, and answers a `Result` because `2026 2 30` is not
a day. A time of day goes on top as a `Duration`, which means there is no
rule about what an hour of 25 would mean: adding 25 hours to a midnight is
the next day at one.

### What changes in a script

`2026-08-22 + 5h` now moves five hours instead of standing still. The rule
that kept two resolutions apart existed for that pair of types alone.

An instant prints in full and in UTC, whichever spelling was written, so
`"%{2026-08-22}"` is `2026-08-22T00:00:00Z`. `DateTime.date_string` is the
short form. Source keeps what you wrote: `wand f` leaves `2026-08-22` alone,
as it already left an offset form alone.

`14:30:00` is no longer a value. `Time` had no module, no arithmetic and no
use anywhere; a time of day belongs to a day. The lexer still reads the
shape and names the instant form.

`Decode.date`, `Decode.time`, `String.to_date` and `String.to_time` are
gone. `Decode.datetime` and `String.to_datetime` read both spellings.

### The shell corpus is finished

`rotate-backups` and `provision-host` are the last two ports, so all twelve
of the jobs the corpus set out to cover are in `examples/ports/` — eighteen
files, each naming the bash it replaces. Permissions, symlinks, ownership
and a process surface stay out of the standard library on purpose, recorded
in `docs/gaps.md` as decisions rather than omissions.

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

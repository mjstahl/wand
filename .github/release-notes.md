## 0.25.0 - 2026-08-21

wand can wait.

    Clock.sleep 30s

    Shell.timeout 30s (fn () -> $(curl %{url}))

    Par.race [fn () -> $(curl %{a}), fn () -> $(curl %{b})]

    Par.timeout 30s (fn () -> poll_until_ready ())

`Duration` had literals and arithmetic, and nothing anywhere consumed one as
a wait. So a retry with backoff could not be written, polling could not be
written, and a command that hangs hung forever. `Clock` is an eighth effect
label, and a file that waits declares it:

    uses {Clock, Shell(curl)}

One label, not `Clock.Read` and `Clock.Wait`. `FS` splits because a handler
can grant one half and not the other. A clock cannot: a virtual clock that
answers a read while sleep really sleeps gives a program whose clock says
five seconds and whose wall says thirty.

No manifest in the tree changes. Nothing performed `Clock` before this.

### The deadline that kills for real

Most script hangs are not wand code, they are a subprocess.

    match Shell.timeout 30s (fn () -> $(curl %{url})) with
    | Ok body   -> body
    | Error why -> "gave up: %{why}"

Expiry is a sequence — SIGTERM, a fixed five-second grace, SIGKILL. A
command that tidies up on TERM gets to, and one that ignores it does not get
to keep running. Only a deadline produces an `Error`, and the message names
the command and the duration, because that string ends up in a log. Every
other failure passes through: a command that exits non-zero has failed, not
run late.

The deadline is per command, and it is counted in slices of the select the
pipes are already read with. Nothing reads a clock, so a machine that steps
its clock mid-command cannot shorten or extend the wait.

### First to finish wins

    match Par.race [fn () -> $(curl %{a}), fn () -> $(curl %{b})] with
    | Ok body   -> body
    | Error why -> "both mirrors failed: %{why}"

First to finish, not first to succeed. A loser that raises is discarded; a
winner that raises comes back as `Error`. Cancellation is cooperative: a
loser doing wand work stops at its next step and gives back what it holds,
and every worker is joined before `race` returns. A loser waiting on a
command waits for that command — put `Shell.timeout` in the thunk to bound
it.

`Par.timeout` is written in wand over `race` and `Clock.sleep`: the work and
a sleeper race, and whichever finishes first answers. That is what makes it
a wait of a length rather than a wait until an instant, which is what keeps
it right on a machine whose clock steps.

### A test of an hour of backoff runs in microseconds

    Test.with_clock (fn () -> retry_with_backoff ())

The handler answers the effect with a clock that costs no time and reports
the total asked for. `--dry-run` reports `would wait: 45s` and does not
wait, because nobody waits an hour to be told what a script would do.
`--trace` is a real run and sleeps.

Two waits a virtual clock does not shorten: `Shell.timeout`, because that
wait belongs to the operating system, and `Par.timeout`, which answers `Ok`
because a watched race is left-biased and the work wins. Test a deadline
against real time.

### Comparison is on the value

A backoff loop doubles a delay and stops at a ceiling, and that could not be
written, because durations did not compare.

    90s > 1min          -- true
    60s == 1min         -- true

`<`, `>`, `<=` and `>=` were `'a -> 'a -> Bool`, dispatched during the run.
They now take an `Ord`, a type wand orders, and seven are ordered: Int,
Float, String, Duration, Date, Time and DateTime. Comparing anything else is
a type error where it is written, not a failure mid-run. `Ord` composes as
`Num` does, so `let later a b = if a < b then b else a` stays polymorphic.

A comparison is on the value, not on the text. A `Duration` is a sum of
units and a `DateTime` carries an offset, so one value has several
spellings. A `DateTime` with no offset is read as UTC, because reading it as
local time would make one script answer differently on two machines.

**Breaking.** `60s == 1min` was false, while `60s < 1min` and `60s > 1min`
were both false as well — three answers no reader can hold at once. It is
now true. `100MB < 1GB` typechecked before and failed during the run; it is
now a type error, because Size, Version, Port and IPv4 are not ordered yet.

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

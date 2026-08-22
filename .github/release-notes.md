## 0.32.0 - 2026-08-21

`wand f` keeps a value that ends in a bracket on the line that opens it:

    let hosts = [
      "web-01",
      "web-02"
    ]

    report [
      stage "build" $?(dune build),
      stage "test" $?(dune test)
    ]

A value that *is* a bracket already did this. A call whose last argument is
one broke under its head instead, which spent a line on the bracket, pushed
the items two columns further in, and closed the call's first line — so the
definition ended there and needed parentheses to survive.

Run `wand f` over a formatted repository once. Files laid out by 0.31.0
will change.

### A deadline inside a handler is refused

`Par.timeout` is a race between the work and a sleeper, and a race runs
only its first thunk while a handler is installed. So the sleeper never
ran, the deadline never fired, and work that only the deadline would have
stopped ran forever — a test suite hanging with no message.

Put the handler inside the thunk:

    Par.timeout 200ms (fn () -> Test.with_shell mocks (fn () -> work ()))

The mock stands and the deadline fires. A rehearsal and a trace are not
refused.

### A port crosses to its number

`Port` could be written, ordered, compared, decoded and interpolated, and
nothing took `8080` out of `:8080` — so a script could not hand a port to a
command that wanted the number as an argument of its own.

    Port.to_int :8080                     -- 8080
    "host%{:8080}"                        -- "host:8080", unchanged
    $?(nc -z %{host} %{Port.to_int port})

`Port.of_int` goes back, and refuses a number outside 0–65535.

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

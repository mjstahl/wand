## 0.33.0 - 2026-08-21

### A test can stand in for `$?(cmd)`

`Test.with_shell` stood in for `$(cmd)` and nothing else. `$?(cmd)` — the
form that reports an exit code instead of raising on one — ran for real, so
a mock written for a script that inspects an exit code did nothing, and the
test passed for the wrong reason.

`Test.with_shell` and `Test.shell_calls` now stand in for both forms. A
`$?(cmd)` they answer exits zero and carries the output written for that
command.

### And give it the exit code it turns on

No output expresses a failure, so `Test.with_shell_results` supplies whole
results:

    let red = ShellResult(stdout = "", stderr = "", code = 1)

    test "a red build stops the gate" (fn t ->
      t.eq
        [("test", false)]
        (Test.with_shell_results [("dune test", red)] (fn () -> gate ())))

A command the test does not name exits zero with no output. `$(cmd)` is not
answered there, because a failure in that form is a raise and not a value.
A script that uses both forms nests `with_shell` around it.

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

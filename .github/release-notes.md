## 0.20.1 - 2026-08-20

A repair release for `wand f`. Three bugs had shipped where it emitted
source that would not parse, and each of them waited for someone to write
a line long enough to wrap before it showed. Rather than wait for the
next one, the formatter's tests now format all 69 corpus files at 20, 30,
40, 60 and 92 columns and ask only that the result is still a program.
Layout at twenty columns is nobody's idea of readable; it still has to
parse, and formatting it again still has to change nothing.

That found seven more. Each is a place where an expression that wrapped
was written without the brackets that hold it together — the `in` tail of
a `let` and its value, a lambda's body, an operand, a branch of an `if`,
a `match` scrutinee, a `with` resource, a pipeline stage.

Two of them did something worse than fail: they changed what the code
meant. A value could be reformatted into a different program. And a
splice that wrapped inside `%{...}` dropped its argument, because a
newline there ends the string as far as the lexer is concerned:

    "%{show_opt None}, %{show_opt
      (Some 42)}"     -- reformatted to %{show_opt}, the argument gone

Splices now come back on one line however long they are.

The new brackets are conservative: they go in wherever a wrapped
application could be misread, and inside a bracket it could not, so some
files gain parentheses they do not strictly need. Nothing you have
written changes meaning, and `wand f` will add them the next time it runs
over your files.

Also fixed: a handler that declines to resume an operation performed
inside a `with`'s release reached the top level as a fatal error instead
of unwinding the bracket.

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

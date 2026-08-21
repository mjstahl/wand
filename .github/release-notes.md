## 0.23.0 - 2026-08-21

This release changes the words wand uses. The type checker reports what it
expected and what it got. The README and the reference are rewritten in
Simplified Technical English.

Nothing about the language changes. If a script or a CI step greps for the
text of an error, it needs an update.

### An error names both sides

    before: cannot unify Glob with Path
    after:  expected Glob, got Path

"Unify" is a word from the type checker. A reader of a script has a `Path`
where a `Glob` belongs, and the message says that now.

`unify a b` has no fixed direction. Both orders appear in the compiler. So
37 call sites now state which side the reader wrote: an annotation, an
application, an `if` and its branches, an arm of a `match` and its guard, a
pattern, an element of a list or a map, a `$()` payload, a `|>` stage, a
contract clause, a `with` resource, and an operand. A site that cannot know
says `Glob and Path are not the same type`.

An effect error names the difference instead of two sets:

    before: cannot unify effects {Shell} with {Raise, Shell | ..}
    after:  the type allows {Shell}, but the body performs Raise

At an argument it says which side is which:

    the parameter allows {}, but the function given performs Raise, Shell

Three more messages drop the word:

    expected a number, got Bool -- arithmetic works on Int and Float
    Int and Float do not mix -- Float.of_int and Float.round convert between them
    this value would have to contain itself: 'a appears inside its own type

### The documents are shorter

`README.md` and `docs/reference.md` now use short sentences, active voice,
and one idea in each sentence.

The reference also said that a newline always ends a statement. That is not
true: a line that starts with an operator continues the line above, which is
what a pipeline that leads with `|>` needs. So these two lines are one
statement, and `a` is `-1`:

    let a = 1
    -2

Three claims in the README were wrong and are corrected against a run: the
by-hand install named v0.10.0, the example error text did not match, and
startup said 1.6 times `bash -c :` where three runs give about 2 times.

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

## 0.19.0 - 2026-08-19

Tests can have children. `Test.group` runs child tests that share its
label and whatever its body binds:

    group "the report" (fn () ->
      let lines = String.lines (build_report ()) in [
        test "has a header" (fn t -> t.eq "# Report" (List.head! lines)),
        test "is short" (fn t -> t.ok (List.length lines < 40))
      ])

    ok   the report / has a header
    ok   the report / is short

Groups nest to any depth, and each test prints under the path of labels
that led to it. There is no before/after machinery to learn, because the
body is ordinary code: setup is the bindings above the child list,
teardown is a `with` bracket around it, and a handler mocks every child
at once. A raise in the body itself is the group's one failure, and the
children it prevented are not invented.

A test whose body raises now fails under its own label — `label: raised:
division by zero` — where it used to surface as an error with no label,
and a raising child no longer takes its siblings down with it.

`wand f` reads better in two ways. An `if`, `match`, or `handle` that
starts mid-line steps its `else` and its cases in, rather than landing
them flush with the line that introduced them, and an else-if chain
stays one flat ladder. And a list, map, or tuple opens its bracket on
the line that introduces it instead of spending a line on a bracket
sitting alone.

Every command is now written the way its usage line heads it — `wand f`,
`wand s`, `wand v` — in the documentation and in the hint an unbound
name hands back. Both spellings still dispatch, so nothing you have
typed before stops working.

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

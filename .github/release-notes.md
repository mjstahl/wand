## 0.29.0 - 2026-08-21

A record with one field changed.

    let count_into (tally: Tally) line =
      match status line with
      | None -> tally
      | Some code ->
        if code >= 500 then Tally(tally, failed = tally.failed + 1)
        else Tally(tally, ok = tally.ok + 1)

The record comes first, then the fields that change. Before this, changing
one field meant naming them all. A field you do not name keeps what the
record holds, and naming one twice is a type error.

The type is named, as it is in a construction, and braces stay a map. So
`{tally with failed = 1}` is a parse error, and it answers with this form
carrying your own names:

    a record update names its type: `T(tally, failed = ...)`. Braces are a map

`rm -rf build/` and `cp -r` have a spelling now. `FS.delete_tree` and
`FS.copy_tree` take a whole tree, each with a raising sibling. Neither
follows a symlink out of the tree: a delete unlinks it, a copy recreates
it. A copied file keeps the mode it had.

`Shell.ok? r` is `r.code == 0`, the first question a script asks of a
`$?()`. `Decode.map3` builds a decoder from three fields. `Float.format 1
0.3333` is `"0.3"`.

A nullary constructor now names itself. `t.eq None (usage row)` is
`t.eq (None (usage row))`, because parentheses after a constructor are its
payload. The error said `expected Option 'a, got Option (String, Int) ->
'a`. It now says `'None' takes no arguments` and to write `(None)`.

### One thing to know before upgrading

Six `Env` operations now say what they carry and what resumes them. A
handler case that resumed one with the wrong type used to typecheck:

    handle Env.get "SOME_NAME" with
    | Env!get name k -> k 42

`Env.get` answered `Some(42)`, an `Option Int` from a function whose
signature says `Option String`. That is a type error now.

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

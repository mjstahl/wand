## 0.28.0 - 2026-08-21

A file's size is a `Size`.

    FS.glob_in **.wand ./stdlib
      |> List.filter_map (fn p -> match FS.size p with
        | Ok size -> Some (p, size)
        | Error _ -> None)
      |> List.filter (fn (_, size) -> size > 4KB)

`FS.size` answered an `Int` of bytes, so the one place wand produced a size
it produced a number, and `4KB` could not be written against a file. Three
things closed that.

`Size` crosses to a number and back. `Size.to_bytes 4KB` is `4000`.
`Size.of_bytes` goes the other way and stays exact, so 6466 bytes is
`6466B`; `Size.format` is the spelling for a reader, `"6.5KB"`.

`+` and `-` add two sizes, and two durations. They take a new constraint,
`Add`, which sits between `Num` and `Ord`: `Int`, `Float`, `Size`,
`Duration`. `*` and `/` stay on `Num`, because a size times a size is not a
size. A sum of sizes is written in bytes, and a subtraction that would go
below zero floors there — the answer `Duration.sub` already gave.

`List.filter_map` applies a function to every element, keeps each `Some`
value and drops each `None`. Two of the shipped ports were writing that out
as a fold.

`wand f` writes back the binding spelling you wrote. `(let x = 1; x + 2)`
used to come back as `let x = 1 in x + 2`, which turned the block form into
the one the style guide keeps for naming.

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

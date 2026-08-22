## 0.41.0 - 2026-08-22

A value can be written out without being converted first.

    JSON.of! [1, 2, 3]                        -- [1,2,3]
    JSON.of! Pod(name = "web", port = 8080)   -- {"name":"web","port":8080}
    TOML.of! {port = 8080}                    -- port = 8080
    CSV.stringify [[1, 2], [3, 4]]            -- the two rows, 1,2 and 3,4

`JSON.of_list` and `JSON.of_map` take values already converted, so writing a
structure meant converting it a piece at a time —
`JSON.of_list (List.map JSON.of_int xs)`. `JSON.of` writes the whole thing:
numbers, text, every domain type, lists, maps, options and records, and any
nesting of them. What it cannot write is a value holding code — a function,
a resource, a stream — and that is the `Error`. `JSON.of!` raises instead.
The `of_*` builders stay, precise and total.

### TOML can be written

`TOML` had no constructors at all. A document could be parsed and
re-printed, and never built from a script's own data. `TOML.of` and `of!`
build one.

A TOML document is a table, so the value is a map or a record; a bare number
says so rather than producing something no parser reads back. A field that
is `None` is left out, because TOML has no null and writing one would not
read back the same.

### CSV takes any cell

`CSV.stringify` already wrote a non-text cell, and only its signature
refused one. It takes `List (List 'a)` now and stays total — a cell is text,
and every value has a text form.

A list and a map each hold one type, so a structure whose parts differ is a
record. That is what `of` walks best.

### Also

`of` is an ordinary word now. It was reserved so `Circle of Int` could be
corrected, and that correction fires where the mistake is written instead.

`:reset` in the REPL opens what a session opens with. It built its own list
of modules and had been missing eighteen of them since they were added, so a
reset session could not reach `Map`, `JSON` or `Test` while a fresh one
could.

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

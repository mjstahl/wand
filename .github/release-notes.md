## 0.22.0 - 2026-08-21

This release corrects five answers and adds one check.

Two changes alter what a running script sees. No script needs a rewrite.

### A glob stays under its directory

`FS.glob_in pat dir` answers with the files under `dir`. It walked through a
symlink before. A link to `/etc` put the files of `/etc` in the answer:

    ./data/link/hidden.conf     -- in fact /etc/hidden.conf

A link to a parent directory made the walk repeat until the path was too
long for the system.

wand does not walk through a symlink now. A symlink that matches is still an
answer, as itself. wand still follows the base directory, because you named
it. bash, `find` and Python do the same.

**Effect:** a glob over a tree with a symlinked directory answers with fewer
files.

### A file gets a mode

`FS.write_file` used the channel default of 0666. `FS.create_file` and
`FS.append` used 0644. Under `umask 0` the first one wrote a file that all
users can write. All three use 0644 now.

`FS.copy` used the same default and lost the mode of the source file. A
copied script lost its executable bit. A copy of a 0600 file was readable by
all users. A new destination gets the mode of the source now. A destination
that exists keeps its own mode.

`--dry-run` answered with the path `/tmp/wand-dry-run-dir` each time. All
users can write `/tmp`, so another user can make that directory or a symlink
first. Each answer is a new random path now.

**Effect:** files get different permissions than before.

### Three functions gave wrong values

    String.join "," ["", "b"]            -- was "b", is ",b"
    String.words "  a  b  "              -- was 7 elements, is ["a", "b"]
    String.words "a\tb"                  -- was 1 element, is ["a", "b"]
    Path.with_extension "md" /a/b.txt    -- was /a/bmd, is /a/b.md

`String.join` read an empty first element as an empty accumulator.
`String.words` split on one space, so extra spaces became empty words.
`Path.with_extension` accepts the extension with or without the dot now.
`""` removes the extension.

### wand checks the type variables in an annotation

A type variable is a promise: the function accepts any type. wand did not
check that promise. This code typechecked, and the signature told each
caller that a `String` is correct:

    let f : 'a -> 'a = fn x -> x + 1

Each variable in an annotation must stay a variable after wand infers the
body. Two variables must stay different. So wand refuses this too:

    let g : 'a -> 'b = fn x -> x

An annotation with no type variable does not change. `Int -> Int` over the
identity function makes no promise.

**Effect:** an annotation that claims more than the body gives is a type
error.

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

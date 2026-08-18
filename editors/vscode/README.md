# wand for VS Code

Language support for [wand](https://github.com/mjstahl/wand). The language
server is `wand lsp`, a subcommand on the wand binary itself — the extension
spawns it and stays out of the way, so the editor can never disagree with
the compiler.

## What you get

- **Diagnostics** as you type: the same errors and `V-*`/`A-*` findings
  `wand t` reports, with real ranges.
- **Hover**: the inferred signature *with its effect row* — hovering
  `deploy!` shows `String -> String ! {FS.Write, Shell(git, rsync)}` — plus
  the doc string.
- **Auto-import**: typing `FS.write_file!` in a file that has not imported
  `FS` inserts `import FS` (sorted into the import block) and adds
  `FS.Write` to the manifest, as you type. `Shell` is never touched
  automatically — those changes stay one visible click away as quick fixes.
- **Completion**, including members of modules you have not imported yet;
  accepting one carries the import with it.
- **Quick fixes** from every finding that knows its correction — manifest
  updates, dead imports, drift spellings.
- **Formatting** via `wand fmt` (format-on-save works through the standard
  setting).
- **Go to definition**, including into the standard library — stdlib
  sources are embedded in the binary and open as read-only documents.
- **Rehearse lens** on the `uses {...}` line (or the first line, for a
  file without a manifest): one click runs
  `wand --dry-run` on the file in the integrated terminal, showing what a
  real run would do without doing it.

## Requirements

A `wand` binary with the `wand lsp` subcommand — a build from `main`, or
any release after 0.12.0. The server ships inside the binary, so there is
nothing else to install. The extension finds it on `PATH`, or failing that
in the places installs land (`~/.local/bin`, Homebrew's prefixes) — set
`wand.path` only for a binary somewhere else.

## Building and installing from the repo

The extension is not on the Marketplace yet; build and side-load it:

```sh
cd editors/vscode
make install
```

That runs `npm install`, compiles, packages the `.vsix`, and installs it
with `code --install-extension`. `make package` stops after building the
`.vsix`, for installing by hand.

## Settings

| setting | default | meaning |
|---|---|---|
| `wand.path` | `wand` | The wand binary the extension spawns (`wand lsp`, `wand --dry-run`). |

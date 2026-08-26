## 0.51.0 - 2026-08-26

Three editor problems, all in `wand lsp`. The binary carries the fix. The
extension does not change.

### Added

- **A type lens above each definition.** `wand lsp` answers
  `textDocument/codeLens`. Each lens gives the inferred signature of one
  value. A `type` line gets no lens. When a line binds more than one name,
  each lens shows its name. The `editor.codeLens` setting turns lenses off

### Fixed

- **A label in `uses {...}` is an effect.** The hover showed `Env` and `IO`
  as modules. A manifest declares effects, not modules. It showed nothing for
  `FS.Read`, `Raise` and `Proc`, because they name no module. The parser now
  gives the extent of the manifest. A label reads as an effect in the
  manifest, and as a module elsewhere
- **A doc example keeps its answer on its own line.** The editor reads a doc
  string as markdown. `>> ` starts a blockquote, so the answer joined the
  paragraph above it and the prompt disappeared. Examples now go in a fence.
  A hover shows the transcript that `wand d` shows

A hover uses the last check that was successful. In a file that never
typechecked, a manifest label still reads as a module.

## 0.48.0 - 2026-08-25

A type belongs to the module that declares it.

    let one = import ./one
    let two = import ./two

    let f (s: one.Status) = s
    f two.Live
    -- expected one.Status, got two.Status

Two modules can each declare a type called `Status`. They declare two types.
A file can use both. The line above used to typecheck. One of the two types
won, and nothing said which.

### Added

- A type and a constructor take the module's name: `Test.TestOutcome`,
  `Test.Pass "x"`, `| Test.Pass s ->`. This works in a type, an expression
  and a pattern
- An uppercase name in a destructured import selects a type or a
  constructor: `let {TestOutcome, Pass} = import Test`

### Changed

- An import brings only what it names. A file that writes a bare imported
  type or constructor fails with "unknown type" or "unknown constructor".
  Use one of the two spellings above. Twenty-six places in this repository
  needed the change
- Renaming a type in an import also renames its constructor, where it has
  one. An alias does the same: `type MyConf = Foo.Conf` builds and matches.
  Renaming one constructor out of several is refused
- A type error prints the short name. Where two names print the same, both
  take the module
- `wand f` prints an uppercase key in an import without quotes

### Fixed

- The compile cache keyed on a module's source and its dependencies. Two
  files with the same bytes at two paths shared one entry, which gave one
  file the other's type names. The key includes the path
- One module reached by two spellings of its path was two modules. A module
  key is normalised

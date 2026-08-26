## 0.52.0 - 2026-08-26

Two errors that were not reporting as errors. The binary carries both fixes.
Nothing you write changes.

### Fixed

- **An import that cannot be loaded says where it is.** A module this binary
  does not carry, a file that is not there, a symbol or constructor a module
  does not export, a bare `import` that binds nothing, a pattern that cannot
  destructure one, a cycle -- each of these came back as an internal failure
  with no position, so `wand t` could not point at the line and the editor
  could not underline it. They report as `E-IMPORT` now, at the import
- **A wide type prints as a type.** A type with more than 26 type variables
  named the 27th `'{` and the ones after it as bytes that are not characters.
  Past 158 it stopped printing at all and gave a backtrace. Names run `'a` to
  `'z`, then `'a1`. A function of 180 arguments is enough to have met this

Both were found by a fuzzer that is new in this release, in `test/fuzz`. It
mutates the wand already in the repository and checks that a typecheck of
anything at all answers with a diagnostic rather than a crash. It runs
nightly. Nothing about it reaches an installed wand.

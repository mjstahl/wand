## 0.49.0 - 2026-08-25

This release began as a question: does wand need a trait system to get the
abstractions it is missing? The answer was no, and finding that out turned up
four defects that were costing more than any missing abstraction.

wand already has a closed trait system — `Num`, `Add` and `Ord`, narrowed on
unification and dispatched on the value. Opening it buys one thing, ordering
on a type you define, and costs a constraint clause on every printed type.
Meanwhile records and higher-order functions did not compose at all, two
relations disagreed with each other, and `List.sort` answered by the alphabet.
Those are fixed here. The trait question is recorded in `docs/gaps.md` and
left where it was.

Two changes reject code that used to compile, and one changes what a sort
returns. Each is listed below.

### Added

- `T.parser`, holding everything reading a command line takes: the account of
  the flags, the reader, and the usage line

      Args.read Opts.parser (Env.args ())

- `CommandLine`, the built-in record type `T.parser` answers with. A file can
  take one apart and can build one
- `CIDR` is an ordered type. `9.0.0.0/8 < 10.0.0.0/8`, and `Ord` is ten types

### Changed

- **`Args.read` takes one argument where it took two.** `spec` and `reader`
  were derived separately and only ever used together, and nothing said they
  had to come from one type — `Args.read B.spec A.reader argv` typechecked
  and failed during the run with a message about the arguments. A `Map
  String` carries no trace of the type it came from, so the pairing could not
  be checked anywhere. One member cannot be mispaired
- **A value cannot take the name of a type or a constructor.** `type
  Pod(host: String)` beside `let Pod = 1` was accepted, and the value could
  not be reached from anywhere. A name declares one thing
- The error at a field access on a type nothing has pinned names the
  annotation to write, and the declared types that have the field:

      let port_of p = p.port
      -- 'p' needs its type before '.port' can be read: write '(p: Pod)'

### Removed

- `T.spec` and `T.reader`. Naming either says to write `T.parser`, which
  holds both and the usage line

### Fixed

- A lambda written before the argument that says what its parameter is could
  not read a field off it. `List.map (fn p -> p.host) pods` was a type error,
  as were `filter`, `sort_by`, `fold_left` and every pipe form — every
  higher-order function in the standard library takes its function first.
  Not one lambda in `examples/` read a record field; they had all been
  written around the hole. Arguments are still read in written order, and a
  lambda's body now waits until the rest have been read
- A lambda applied where it is written had the same fault, one position over.
  `(fn p -> p.port) pod` could not see the argument under it
- `List.unique` did not answer with the equality `==` answers with.
  `2026-08-25 == 2026-08-25T00:00:00Z` was true, and
  `List.unique [2026-08-25, 2026-08-25T00:00:00Z]` returned both. Membership
  compared the stored value, so it compared the spelling. The same for `60s`
  and `1min`, and for `1000KB` and `1MB`
- `List.sort` compared a `CIDR` as text, so `10.0.0.0/8` sorted below
  `9.0.0.0/8` — the two addresses the opposite way round from what `IPv4`
  answers
- **`List.sort` ordered a variant by constructor name.** `type S = Zulu |
  Alpha` sorted to `[Alpha, Zulu]`, and renaming a constructor moved values.
  A constructor sorts where it was declared, so `List.sort [High, Low,
  Medium]` on `Low | Medium | High` comes back in that order. `Option` and
  `Result` declare their absent and failed cases first, so `None` before
  `Some` and `Error` before `Ok` are unchanged

`List.sort` still takes a list of any type and so orders more than `<` does.
The reference says why, and `List.sort_by` remains the answer where the
shape's order is not the one wanted.

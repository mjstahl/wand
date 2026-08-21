# Design: ordering the rest of the domain types

**Status: proposal — not implemented, and unblocked.** The `Ord`
constraint shipped in 0.25.0 with the clock block, which brought the
machinery and ordered the temporal types. This doc decides the four that
block held back, and one question it met first. The doc retires when the
four are ordered and `docs/reference.md` says which types compare. Line
references are from `6e932b7`, before `Ord` landed.

## The problem

Stated as it was before `Ord`; the four types below are unchanged by it,
and are still a type error under a comparison.

`<`, `>`, `<=` and `>=` are typed `'a -> 'a -> Bool`, and the evaluator
handles three types: `Int`, `Float` and `String` (`evaluator.ml:940`).
Everything else raises during the run:

```
100MB < 1GB      -- runtime error: '<' requires comparable types
1.2.3 < 1.10.0   -- runtime error
:80 < :443       -- runtime error
10.0.0.1 < 10.0.0.9  -- runtime error
```

Each of those four has one obvious total order. A script that compares a
size against a threshold, or a version against a floor, is ordinary ops
work. Today it must convert to `Int` by hand, and there is no function
that does it: `Size` has literals, equality and a decoder, and nothing
else.

The clock block fixes the machinery and the temporal types. It states the
rest as additive: "a member in the list and a normalizer beside it". This
doc writes the members and the normalizers, so that work is a lookup and
not a design.

## Port — free

`VPort` already holds an `Int` (`evaluator.ml:75`). The order is the
numeric one. There is nothing to normalize and nothing to decide.

```
:80 < :443            -- true
```

## IPv4 — one normalizer

The order is the numeric one over the 32-bit address, which is what makes
a range check read correctly:

```
10.0.0.9 < 10.0.0.10        -- true; string order says otherwise
```

`VIPv4` holds the text (`evaluator.ml:73`). The normalizer splits on `.`
and folds the four octets into an `Int`. The lexer has already rejected an
octet above 255, so the normalizer cannot fail on a value that exists.

## Size — decide the unit first

The order is by bytes. The normalizer needs a rule for the units, and wand
does not have one yet: no code converts a `Size` to a number.

The literal spells `B`, `KB`, `MB`, `GB`, `TB` and `PB`
(`lexer.ml:372`). It has no `KiB`.

**Decision: a `KB` is 1000 bytes.** The spelling is the SI one, and SI
says 1000. To read `KB` as 1024 is to lie about the unit that the author
wrote. Cloud billing, disk vendors and `df -H` agree with SI; `du -h` and
`free` do not, and they spell it `K`, not `KB`.

Binary units stay open and additive: `KiB` and `MiB` literals can be added
later, and they need one arm in the lexer and one line in the
normalizer.

A decimal literal is allowed (`1.5GB`), so the normalizer multiplies and
rounds to the nearest byte. `1.5GB` is 1500000000. `0.4B` is 0 bytes.
Round-half-up, stated because a rounding rule that nobody wrote down is a
rounding rule that changes.

`Int` holds a size of 4.6 exabytes, so no literal the lexer accepts can
overflow it.

Whether `Size.to_bytes` becomes public is a separate question. Ordering
needs the normalizer, not the module.

## Version — semver precedence, and only what the lexer accepts

The order is [semver 2.0.0][semver] precedence:

1. Compare major, then minor, then patch, as numbers. `1.10.0` is above
   `1.9.0`; string order gets this wrong, which is the reason nobody
   should reach for the shortcut.
2. A version with a prerelease is below the same version without one.
   `1.2.3-rc.1 < 1.2.3`.
3. Two prereleases compare identifier by identifier, splitting on `.`.
   A numeric identifier compares as a number. A numeric identifier is
   below an alphanumeric one. Two alphanumeric identifiers compare by
   ASCII. If every identifier matches, the version with more of them is
   above.

So `1.2.3-alpha.1 < 1.2.3-alpha.2 < 1.2.3-beta < 1.2.3`.

Build metadata needs no decision: `1.2.3+build.5` is a parse error today,
so no value carries it.

**Two spellings the lexer accepts and semver does not.** They need a
stated answer, because they exist:

- `01.2.3` — a leading zero. Semver forbids it. The normalizer reads it
  as 1, so `01.2.3` and `1.2.3` compare equal.
- `1.2.3-` — an empty prerelease. The normalizer reads it as one empty
  identifier, which is below every other prerelease.

Both are consequences of the rule below, not exceptions to it. The
alternative is to tighten the lexer, which is a separate change and
breaks a file that lexes today.

[semver]: https://semver.org/spec/v2.0.0.html

## The question this meets first: equality does not normalize

`==` compares the stored value (`evaluator.ml:376`, which is OCaml's
structural equality over the string a literal was written as). So today:

```
60s == 1min          -- false
1000B == 1KB         -- false
1.0KB == 1KB         -- false
192.168.001.1 == 192.168.1.1   -- false
2024-01-15T14:30:00Z == 2024-01-15T20:00:00+05:30  -- false
```

Every one of those is one value written two ways. Ordering normalizes, by
the rule the clock block states: *ordering compares normalized values,
never the stored string*. Put the two together and the relations
disagree. `1000B < 1KB` is false, `1000B > 1KB` is false, and
`1000B == 1KB` is false. A reader who checks two of the three learns the
wrong thing about the third.

**Decision: equality normalizes too, for every type that `Ord` accepts,
in the same block that orders it.** `wand_equal` grows a case per ordered
domain type, in front of the structural fallback. Then `60s == 1min` is
true, `<` and `==` agree, and a comparison means what it says.

This is a change in behavior, so it is breaking text in a changelog. It
is hard to write a script that wants the old answer: `60s != 1min` being
true is not a fact anybody depends on.

The clock block meets this first, with `Duration`. It should make the
decision there and this doc follows it. If that block ships without it,
this doc's four types inherit the split, and the reference has to say so
in the section on each type.

## Never ordered

Stated with the reason, so the next reader does not re-open it:

| Type | Why not |
|---|---|
| `Path`, `Glob` | Lexicographic order reads as tree order and is not. `/a/b.txt` sorts above `/a/b/c` in one and below it in the other. `List.sort` over `Path.to_string` says what it is doing. |
| `Url` | No natural order. Scheme, host and path each argue for a different one. |
| `CIDR` | A network is a set. Two that overlap are neither above nor below. `10.0.0.0/8` against `10.0.0.0/16` has no answer. |
| `Regex` | A pattern is a program. |
| `Bool`, `Unit` | `true < false` means nothing to a script. |
| lists, maps, tuples, records | Element-wise order is a real thing and a separate design. Nothing in the corpus asks for it. |
| functions | Already refused, and the reason a runtime check is the wrong place: two functions compare today only because nothing stops them at the type level. |

User-defined types stay unordered. A deriving mechanism is its own
design.

## What is touched

Each type is one member and one normalizer, as the clock block promised:

- `typechecker.ml`: the four types join the `Ord` constraint's member
  list. Where the list lives is that block's decision; this one adds to
  it.
- `evaluator.ml`: one normalizer per type, beside `parse_dur_ms`
  (`:1119`), which is the template — a literal string in, a number out.
  `Port` needs none.
- `evaluator.ml`: `wand_equal` (`:376`) normalizes an ordered domain type
  before it falls back to structural equality.
- `docs/reference.md`: the list of ordered types, the unit rule for
  `Size`, and the precedence rule for `Version`.

## Verification

- A wand-level test per type, comparing two literals in each direction,
  and one pair that string order gets wrong: `1.10.0 > 1.9.0`,
  `10.0.0.10 > 10.0.0.9`, `1GB > 999MB`.
- The prerelease chain in one test:
  `1.2.3-alpha.1 < 1.2.3-alpha.2 < 1.2.3-beta < 1.2.3`.
- Equality and ordering agree: for each type, a pair written two ways is
  `==`, and neither `<` nor `>`.
- A type outside the set is a type error, not a runtime error:
  `r/a/ < r/b/` reports that `Regex` is not ordered.
- The rounding rule for a decimal size: `1.5GB == 1500000000B`.

## Cost

Small, and it is four independent pieces. `Port` is a member with no
code. `IPv4` and `Size` are a fold each. `Version` is the only one with
real logic, and it is the semver rule written once.

`Ord` exists now, so each normalizer has somewhere to attach and the work
can start whenever it is wanted.

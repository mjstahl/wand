# One instant type, and a module that opens it

wand has three types for a point in time. `DateTime` is
`2026-08-22T14:30:00Z`, `Date` is `2026-08-22`, and `Time` is `14:30:00`.
This plan keeps the first, folds the second into it, removes the third, and
adds the module that takes an instant apart.

Counts and line anchors were true at `35fc11d`. Check each before trusting
it.

## Why

**Two of the three mean the same thing.** A `Date` and a `DateTime` are
both a point in time. Both compare. Both subtract to a `Duration`. A `Date`
is already read as midnight UTC, which is how the two subtract against each
other — so the language has stated the equivalence and then kept two types
anyway.

**The second type costs a rule that nothing else needs.** A `Duration`
moves each shape at its own resolution, so `2026-08-22 + 5h` stands still
while `2026-08-22T00:00:00Z + 5h` moves five hours. That rule exists for
this pair alone. One type answers `2026-08-22T05:00:00Z` and needs no rule.

**`Time` was never asked for.** It arrived in the repo's second commit
(`f98ee5b`, "Add lexer with full token set including domain literals") as
one of the literal shapes, and nothing has needed it since. It has no
module, no arithmetic, and no use in `stdlib/`, `examples/`, `demos/` or
`tools/`. Real documents carry whole instants: a JSON payload holds
`"2026-08-22T14:30:00Z"`, not a bare time of day.

**The literal earns everything; the type name earns almost nothing.**
`Date` as a written type appears four times in all wand code, three of them
in comments. `Time` appears once. The literals keep working either way.

**Nothing takes an instant apart.** No year, no month, no day, no weekday,
no hour. So the first thing a script reaches for — a file named for today —
cannot be written, which is what `docs/gaps.md` records.

## What changes

`2026-08-22` is a spelling of `2026-08-22T00:00:00Z`. There is one instant
type, `DateTime`, and one resolution, the second.

`14:30:00` is not a value. The lexer still recognises the shape, and
refuses it with the form to write: a time of day belongs to a day.

A value prints in full. `IO.println 2026-08-22` writes `2026-08-22T00:00:00Z`,
and the short string comes from the module. This is the one change a reader
sees.

## The module

`DateTime`, with no effects. Reading the clock stays in `Clock`, so
`Clock.now () |> DateTime.day_start` is how a script asks for today.

```ocaml
year        : DateTime -> Int
month       : DateTime -> Int
day         : DateTime -> Int
hour        : DateTime -> Int
minute      : DateTime -> Int
second      : DateTime -> Int
weekday     : DateTime -> Int
day_start   : DateTime -> DateTime
on          : Int -> Int -> Int -> Result String DateTime
on!         : Int -> Int -> Int -> DateTime
date_string : DateTime -> String
time_string : DateTime -> String
```

`weekday` is ISO 8601: Monday is 1 and Sunday is 7. The reader who has to
look that up is the same reader who would look up which day a variant's
list starts on, and the number sorts and compares.

`on 2026 8 22` builds a day at midnight, and it is the only builder. It
answers a `Result`, because `2026 2 30` is not a day, and it has the `!`
sibling the naming convention asks for. A time of day is a `Duration` on
top of it, because a `Duration` already moves an instant:

```ocaml
DateTime.on! 2026 8 22 + 14h + 30min            -- 2026-08-22T14:30:00Z
DateTime.day_start (Clock.now ()) + 2h         -- today at 02:00
```

That is one builder instead of two, one `Result` in a chain instead of two,
and it needs no rule about what `at 25 0 0` means: adding 25 hours to a
midnight is the next day at one, which is what it should be.

`date_string` is the stamped-name case, which is why a formatter is not:

```ocaml
let name = "backup-%{DateTime.date_string (Clock.now ())}.tar.gz"
```

## What stays out

- **Timezones.** Every instant is UTC. A local reading makes one script
  answer differently on two machines, and the database that would fix that
  is not going in the binary.
- **A format string.** `"%Y-%m-%d"` is a mini language nothing checks, and
  the two strings above cover what scripts write. A third case can add a
  third name.
- **Calendar arithmetic.** No "one month later": a month is not a fixed
  length, so it is not a `Duration`, and `+ 1mo` would have to state what
  the 31st of January means. If it lands later it is `DateTime.add_months`
  with the clamping rule written down.
- **Parsing arbitrary text.** `Decode` reads the spellings wand writes.
  Anything else is `$(date -d ...)`, which is where it already is.

## The steps

1. **Lex a bare date as a `DateTime`.** `lib/lexer.ml:473-492` returns
   `Date` today; it returns `DateTime` with `T00:00:00Z` appended.
   `Token.Date` retires with it.

2. **Refuse a bare time.** The same lexer branch reads `14:30:00`. It
   raises instead, naming the instant form. `Token.Time` retires.

3. **Remove both types.** `TDate` is 19 call sites in `lib/` and `VDate` is
   12; `TTime` is 12 and `VTime` is 7. Ordering, unification and the drift
   messages go with them. `Decode.date`, `Decode.time`, `String.to_date`
   and `String.to_time` retire — eight sites across `stdlib/` and `lib/`.
   `Decode.datetime` and `String.to_datetime` read both spellings.

4. **Drop the resolution rule.** The `Date` cases in `infer_binop` and the
   `date_moved` helper in `lib/evaluator.ml` were written for two types and
   are deleted with the second one. The `Time` refusal in `infer_binop`
   goes too: there is no such type to refuse.

5. **Add the primitives.** Six accessors, `weekday`, `day_start` and `on`,
   each beside `datetime_epoch` and `civil_from_days`, which already do the
   arithmetic these need.

6. **Write `stdlib/DateTime.wand`** over those primitives, with the
   signatures above and a reference section to match.

7. **Fix the corpus.** Seven lines across `test_eval.wand`,
   `test_derive.wand`, `test_ordering.wand`, `test_string.wand` and
   `stdlib/String.wand` carry a bare time.

8. **Close the gap.** `docs/gaps.md` loses "No module for dates and times".

## Cost and risk

Breaking, in four ways a script can see: a bare date prints in full;
`2026-08-22 + 5h` moves five hours instead of standing still; `14:30:00` is
no longer a value; a field written `Date` or `Time` is written `DateTime`.

The wand corpus barely notices — five written type names and seven bare-time
literals, all in tests. `lib/` is about fifty call sites, most of them one
line each. The reference is a third of the work.

The risk is the printing change. A script that echoes a decoded date now
emits a longer string, and nothing catches that but reading the output.

## Open

- **`date_string` and `time_string`.** Both say what they answer and
  neither is short. `stamp` was the other candidate and says less.

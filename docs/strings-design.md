# Strings, bytes, and Unicode

A wand `String` is a byte string. There is no UTF-8 layer anywhere in
`lib/`, and `String.length` is `String.length` on an OCaml `string`.

The question this document answers is not "should wand support Unicode" but
"is the current model honest". The model is right for what wand does. Six
operations are not honest about it, and one of them is free to fix today and
expensive to fix later.

It is a record of decisions and their reasons, written before the code. It
is not a specification.

- [What happens today](#what-happens-today)
- [The byte model is right](#the-byte-model-is-right)
- [What is safe](#what-is-safe)
- [What lies](#what-lies)
- [What to do](#what-to-do)
- [What not to do](#what-not-to-do)
- [Order](#order)

## What happens today

```console
$ cat u.wand
let s = "café"
IO.println "length: %{String.length s}"
IO.println "chars:  %{List.length (String.chars s)}"
IO.println "upper:  %{String.upper s}"
IO.println "rev:    %{String.reverse s}"
IO.println "slice:  %{String.slice 0 4 s}"
IO.println "eq:     %{s == "café"}"
IO.println "split:  %{List.length (String.split "," "a,é,b")}"

$ wand u.wand
length: 5          -- "café" is four characters
chars:  5          -- five single-byte strings
upper:  CAFé       -- ASCII-only uppercase; the é is untouched
rev:    ??fac      -- reversed the bytes, splitting the é in half
slice:  caf?       -- slice 0 4 cut a character in half: invalid UTF-8
eq:     true       -- byte comparison, correct
split:  3          -- ASCII delimiter, correct
```

`Regex` is byte-oriented on the same terms:

```console
$ wand ...
dot matches:   false      -- r/^.$/ does not match "é"
dotdot:        true       -- r/^..$/ does
```

## The byte model is right

This is worth stating before the criticism, because the conclusion is not
"add Unicode".

wand reads log files, shell output, filenames and configuration. All of that
is bytes. A log with one badly-encoded line in it is an ordinary thing to
have to process, and a `String` type that validated UTF-8 would refuse to
read it — turning a file wand should summarise into a file wand cannot open.
Path handling is byte-oriented for the same reason: the operating system
takes bytes, and inventing an encoding on the way through would break the
one job the value has.

Splitting on ASCII delimiters is byte-safe by construction, because a UTF-8
continuation byte can never be mistaken for an ASCII character. That is why
most of the module is already correct without knowing anything about
encodings.

Documents arriving from `JSON`, `TOML` and a future `YAML` decode their
escapes into UTF-8 bytes, so data read from a manifest compares and matches
correctly against a literal in the source. The boundary is not the problem.

## What is safe

These are correct on any input, and need no change and no caveat:

```
==   !=   <   >           split       lines      words
contains?                 starts_with?  ends_with?
trim   trim_left   trim_right          join       empty?
replace (with ASCII needles)           repeat
```

## What lies

Six operations promise characters and deliver bytes.

| function | promises | delivers | risk in this domain |
|---|---|---|---|
| `String.upper`/`lower` | case conversion | ASCII-only, silently | **highest** |
| `String.slice` | a substring | possibly invalid UTF-8 | high |
| `Regex` `.` | a character | a byte | high |
| `String.length` | a length | a byte count | medium |
| `String.chars` | characters | bytes | medium |
| `String.reverse` | a reversal | mojibake | low |

`upper` and `lower` rank highest precisely because they *work* for the
ASCII cases that make up almost every use — a header name, an environment
variable, a command word. The failure only appears when someone
case-folds user data, by which point the code has shipped and looks fine.

`reverse` ranks lowest because nothing in deploys, CI glue, cron or log
processing reverses a string.

This is the defect the `Stream` design record argues about `count` against
`length`: a name that hides a caveat is the thing to fix. `String.chars` is
a worse instance, because it is not merely optimistic — it is wrong, and it
has already shipped.

## What to do

**1. Document the model.** One short section in the reference: a `String` is
bytes, here is what is byte-safe, here is what is ASCII-only, `Regex` matches
bytes. Highest value for the least work, and nothing about it is expensive
to revise.

**2. Rename `String.chars` to `String.bytes`.** The whole cost today:

```
stdlib/String.wand:102      -- one doc example
test/wand/test_string.wand  -- two assertions
```

Three occurrences. It is free now and a breaking change the moment anyone
outside this repository writes a script, which is the same argument that
puts the `Net` label and the `Path` normalisation work in front of a first
release rather than behind one.

**3. Add the one UTF-8-aware function the domain needs.** Truncating for
display is the real case — a commit message in a summary, a log line in a
report — and `String.slice` produces invalid UTF-8 doing it today.
`String.truncate n` that stops on a character boundary is the whole
requirement. It is the only place where knowing about UTF-8 buys something
this domain actually wants.

**4. Leave `length`, `slice`, `upper`, `lower` and `Regex` as they are,
documented.** Renaming `length` to `byte_length` touches eleven call sites
in this repository, four of them in the standard library, plus every script
anyone has written — to fix a mismatch that documentation carries more
cheaply.

There is a second reason to leave `length` alone, and it is the stronger
one. The case people reach for it in is a width or alignment check, and a
character count would not answer that either — a CJK character occupies two
terminal columns and a combining mark occupies none. Display width is a
third quantity, and "fixing" `length` to count characters would swap one
wrong answer for a different wrong answer while implying the question had
been solved.

## What not to do

**A validated UTF-8 `String` with a separate `Bytes` type.** This is the
change people expect when Unicode is raised, and it is the wrong one here.
It puts a decode step between wand and every log file, and it needs a policy
for invalid input at exactly the point where the honest answer is to pass
the bytes through. It would also split the standard library in two, since
every function would need a byte version and a text version.

**Unicode-aware `upper` and `lower`.** Full case folding is locale-dependent
— the Turkish dotless i is the standard example — and correct case folding
can change a string's length. Nothing in this domain needs it. ASCII-only
case conversion, named as such, is the right function.

**Unicode-aware `Regex`.** `re` can be told to work in UTF-8 mode, and doing
so would change what every existing pattern means. The patterns wand scripts
write match log formats, command output and identifiers, which are ASCII.

**Non-ASCII identifiers in source.** A separate question about the lexer,
and nobody has asked.

## Order

Documentation first, because it is cheap and it makes every other decision
here reversible.

The `String.chars` rename second, and soon. It is the only item in this
document with a deadline, and the deadline is the first outside user.

`String.truncate` when something wants it. Everything else is deliberate and
stays as it is.

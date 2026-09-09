## 0.70.0 - 2026-09-09

Two more of the things the cross-language benchmark turned up in 0.69.0,
found by profiling what was left rather than by a new measurement.

### Reading one word out of a line

Pulling a field out of a log line was two operations:

```
List.get! 3 (String.words line)
```

`String.words` scans the line and builds seven strings, seven cons cells and
a reversal; `List.get!` then walks past three of them and returns one. Six of
the seven are allocated and thrown away.

```
String.word! 3 line
```

walks to word 3 and builds only that one — 410 ns a line against 636 ns, and
1.23× on counting requests by path. `String.word` is the `Option` form.

It follows the same rule `words` does: a run of whitespace separates once,
and leading or trailing whitespace adds no word. The tests check it against
`words` at every index rather than against literals, so the two cannot drift
apart.

It is deliberately not called `field`. `JSON.field`, `TOML.field` and
`Decode.field` all select a member by *name*, and so does the type error
about a record. This selects a position, and `word` is the singular of the
`words` it indexes.

### A regex literal is compiled once

```
Stream.filter (fn line -> Regex.match? r/ERROR/ line)
```

recompiled that pattern on every line — about 5 µs each, a second of it over
a 200,000-line file. The literal is a constant and the compiled form is a
pure function of the pattern and its flags, but `Re.compile` ran every time
the expression was reached. The only way to avoid it was knowing to lift the
literal into a `let` above the loop.

Written inline it now costs what lifting it out costs: 1325 ms to 370 ms,
against 362 ms for the hand-lifted version.

Kept per pattern *and* flags, so `r/ABC/i` and `r/ABC/` stay two patterns.
`Regex.compile` is deliberately not cached — its argument can be built at run
time, and a table keyed on that would grow with the data. One table per
domain, because `Par` workers evaluate on domains of their own and a table
written from several at once is a data race.

### Also

`bench/startup.sh` and `bench/throughput.sh` are gone. The startup-path rule
still asks for before-and-after numbers on any change to that path — time the
two binaries directly.

## 0.66.0 - 2026-09-08

`Result` has seven more functions. A script can now write the `!` half of
its own pair.

### What `Result` had

```ocaml
to_option : Result 'b 'a -> Option 'a
ok?       : Result 'b 'a -> Bool
error?    : Result 'b 'a -> Bool
```

Three functions. `Option` had eight, over a type that carries less. Every
fallible operation in wand answers with a `Result`, so the thinner module
was the one in the way more often.

The gap showed up as hand-written code. The standard library and the
examples had fourteen arms that read `| Error why -> Error why`, and
fourteen more that read `| Ok v -> v | Error _ -> <default>`. Three
functions in the standard library unwrapped a `Result` by hand to raise its
reason. None of those say anything a name could not.

### What it has now

```ocaml
to_option : Result 'b 'a -> Option 'a
reason    : Result 'b 'a -> Option 'b
ok?       : Result 'b 'a -> Bool
error?    : Result 'b 'a -> Bool
map       : ('a -> 'b ! 'e) -> Result 'c 'a -> Result 'c 'b ! 'e
and_then  : ('a -> Result 'c 'b ! 'e) -> Result 'c 'a -> Result 'c 'b ! 'e
map_error : ('a -> 'b ! 'e) -> Result 'a 'c -> Result 'b 'c ! 'e
flatten   : Result 'b (Result 'b 'a) -> Result 'b 'a
default   : 'a -> Result 'b 'a -> 'a
get!      : Result String 'a -> 'a ! {Raise}
```

Matching a `Result` is still the usual way to deal with one. These are for
where a match says nothing a name could not.

### Chaining steps that can fail

`map` applies a function to the value. `map_error` applies one to the
reason. `and_then` applies a function that returns a `Result` of its own, so
a run of steps stays one `Result` deep and stops at the first failure:

```ocaml
let read path = JSON.read_file path |> Result.and_then (JSON.decode Release.decoder)
```

That is `examples/ports/release-check.wand`, which was four lines. The same
shape was written out in `pod-restarts.wand` and `http-retry.wand`.
`check!` in `verify-archives.wand` was seven lines and two levels of
nesting around one comparison:

```ocaml
let check! file =
  stated file
    |> Result.and_then (fn (digest, archive) ->
      taken! archive |> Result.map (fn got -> got == digest))
```

### Reaching the reason

`to_option` returns the value and drops the reason. Until now nothing
returned the reason, so a script that wanted to report a failure had to
match. `reason` answers it as an `Option`:

```ocaml
List.filter_map Result.reason [Ok 1, Error "a", Ok 2, Error "b"]   -- ["a", "b"]
```

### Two layers of `Result`

`Par.map` returns one `Result` per item, for the work that raised. Work that
itself returns a `Result` therefore comes back with two, and every caller
matched all four combinations. `flatten` turns
`Result 'e (Result 'e 'a)` into `Result 'e 'a`:

```ocaml
match Result.flatten outcome with
| Ok true -> None
| Ok false -> Some (file, "digest does not match")
| Error why -> Some (file, why)
```

`Par.timeout` is written with it too. It raced the work against a sleeper
and then unwrapped the two answers by hand; it is now one line.

### Writing your own `!` function

Every fallible operation in wand comes as a pair: the plain name returns a
`Result`, and the `!` sibling raises. A script could write the plain half.
It could not write the `!` half, because nothing in the language raises a
message a script composed. A script's `!` function had to call a standard
library one and inherit its message, which described the wrong thing.

`get!` returns the value and raises the reason:

```ocaml
let port_of s = if s == "" then Error "no port given" else String.to_int s
let port_of! s = Result.get! (port_of s)
```

It takes `Result String 'a` rather than `Result 'e 'a`, because the reason
becomes the message and a message is a `String`. A `Result` carrying a
structured error still needs a match, which is correct: a type with
constructors is not a sentence.

This adds no way to raise from nowhere. wand still has no `raise`. A raise
still comes from a check that failed, and `try` still turns it back into a
`Result`.

### Also

`Digest.of_hex!`, `Base64.decode!` and `Base64.decode_url!` are written with
`get!`. They were the three functions that unwrapped a `Result` by hand to
raise its reason, and `get!` is now the only one that does.

Six examples, four standard library modules and one test file use the new
functions. Outside the three that implement `Result` itself, no
`| Error why -> Error why` arm is left in the tree.

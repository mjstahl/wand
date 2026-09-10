## 0.71.0 - 2026-09-10

Three of the functions a script reaches for most stop converting a value they
already had, counting becomes one loop instead of two closures a line, and the
manifest says out loud what it does not bound.

### Counting a log, and beating Python at it

Counting requests by client is the most ordinary thing anyone does to a log,
and wand was three times slower than Python at it. Two things were in the way,
and neither was the counting.

`Map.get`, `List.get` and `String.word` were each `Result.to_option` over a
builtin: build an `Ok`, apply a library closure, match it, build a `Some` — to
convert a value the builtin already had, and to build an error string every
caller threw away. `Map.get` cost 1.22µs a call against 480ns for `Map.get!`,
which does the same search. All three answer with the `Option` itself now.

That left the fold. Counting written as one applies two functions to every
item — the fold's own, and the one `Map.update` increments with — so the
interpreter runs the loop as well as the counting, and neither cost can come
out of a fold whose contract is to apply what it was given.

```
FS.stream_lines log |> Stream.filter_map (String.word 0) |> Stream.tally
```

`tally` is the loop, in OCaml, and enters nothing above it. Counting the first
field of a 200,000-line log:

| | |
|---|---|
| 0.70.0 | 379ms |
| the same script, on this release | 251ms |
| rewritten with `Stream.tally` | **108ms** |
| Python, `collections.Counter` | 125ms |

Counting by something other than the whole line goes in front of it, and those
stages run in the same loop. A stream that does not fit in memory still
tallies: what it holds is one count per different string, not the stream.
`List.tally` is the same over a list.

Measured on a 200,000-line log, interleaved in random order over 13 rounds,
with the minimum and the median agreeing on the sign.

`Env.get` is unchanged, on purpose. It is `try env_get_exn`, so the `Env!get`
operation supplies the `String` that a handler double stands in with.

### A subprocess is outside every label

This release corrects a claim rather than a behaviour. The README said a
script cannot do what it did not declare. A script's own code cannot. A
subprocess can do anything, and all five of these typecheck:

```
uses {Shell(curl)}      -- sends bytes to any host, and declares no Net
uses {Shell(cat)}       -- reads any file, and declares no FS.Read
uses {Shell(rm)}        -- removes any file, and declares no FS.Write
uses {Shell(printenv)}  -- reads the environment, and declares no Env
uses {Shell(sleep)}     -- waits, and declares no Clock
```

The reference already covered the hostile case: a manifest is not a sandbox,
and hostile code writes `Shell(sh)` where you can see it. It did not cover the
ordinary one. `Shell(curl)` is a perfectly normal line that reaches any host,
and an absent `Net` tells a reviewer nothing — so anyone narrowing `Net` to
bound where a script sends bytes was wrong whenever the file also ran a
command.

*A subprocess is outside every label*, a new section under Manifests, says so,
and says why it is not a gap waiting to be closed. wand reads the file, not the
binary: there is nothing in `curl` for a typechecker to look at, and a label
wand cannot infer is a label wand cannot check. Making `Shell` imply the other
nine would be truthful and useless — every script that runs `git` would declare
`Net`, `FS.Read`, `FS.Write` and `Env`, and the labels would stop telling a
reader anything.

There is no lint rule for it. Flagging `Shell(curl)` without `Net` implies the
same for `cat`, `rm` and `printenv` — a database of what binaries do,
permanently incomplete, and its real cost would be that a clean `wand t` starts
to imply a bound that does not exist.

What the manifest gives you is the name of each binary a script starts, on the
first line, where a reviewer sees it. What bounds what those binaries then do
is the thing that bounds processes.

### A formatting that parses and does something else

`wand f` wrote source that did not parse. A `let … in` cuddled onto `fn -> `
put its keyword at the end of that line, while its value and its `in` were laid
out from the indent the lambda was handed — so every line of the binding sat
left of the `let` it belonged to, and the parser reads a line left of the
keyword as something new.

Reduced, it is worse than the input the fuzzer reported:

```
let s = (fn -> let t = with a as d -> g (h "x") "y" in "")
```

came back as three statements with the `in` at the top level. That formatting
parses, runs, and does something else.

A `let … in` that wraps now takes the line under the lambda, so its keyword
starts at the indent its own continuation uses.

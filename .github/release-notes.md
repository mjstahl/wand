## 0.73.0 - 2026-09-12

`wand f` leaves more of your layout alone, and a new lint rule finds a
binder that does nothing.

### `wand f` keeps a call that ends in a constructor

A call whose last argument is a constructor was pulled apart, one argument
per line, and wrapped in brackets it did not need:

```ocaml
-- before
let response =
  (HTTP.request!
    HTTP.Request(
      url = endpoint,
      headers = auth
    ))

-- after
let response =
  HTTP.request! HTTP.Request(
    url = endpoint,
    headers = auth
  )
```

A list or a map in that position always kept its shape. A constructor now
does too.

### `wand f` keeps `if` inside the margin

A `then` branch that did not fit was written past the right margin instead
of moving down a line:

```ocaml
-- before, 113 columns
if HTTP.ok? response then JSON.parse body |> Result.and_then (JSON.decode d) |> Result.get!

-- after
if HTTP.ok? response then
  JSON.parse body |> Result.and_then (JSON.decode d) |> Result.get!
```

`else` already did this. Both branches do now.

### `A-BIND1` finds a `let _ =` that binds nothing

`let _ =` says a failure is being thrown away on purpose. When the value is
`Unit` there is no failure, so the binder does nothing:

```ocaml
let _ = IO.println "done"     -- before
IO.println "done"             -- after
```

`wand t --fix` takes it off at the top level of a file and inside
`( ... ; ... )`. Inside a function body it cannot come off on its own,
because the statements would run together — `wand t` names the line and you
write the `;`.

A `let _ =` over a `Result` is left alone. That one is doing its job, and
`V-DROP1` is the rule that asks for it.

### Also fixed

`wand f` dropped the brackets around an `import` used as a value, so
`(import O) xs` came back as `import O xs` — an import and a separate
statement rather than one call. Found by the daily fuzzer (#25).

### Upgrading

Nothing to change. `wand f` output shifts where the cases above applied, so
a file formatted by an older wand may show a diff on its first run.
`A-BIND1` is advisory and never fails a build.

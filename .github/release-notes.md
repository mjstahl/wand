## 0.72.0 - 2026-09-10

Six names go back to the files that want them.

### An HTTP method is written with its module

`GET`, `POST`, `PUT`, `PATCH`, `DELETE` and `HEAD` were built-in
constructors, in scope in every file the way `Ok`, `Error`, `Some` and
`None` are. That list is the language's own vocabulary, and six HTTP verbs
were sitting in it. A file could still declare its own `PATCH`, and the
declaration shadowed the built-in correctly — the cost was not a name taken
away, it was that a bare `POST` said nothing about where it came from, and
that a reader looking up what the language provides found HTTP in the
answer.

They are now reached through the module:

```ocaml
HTTP.Request(url = https://api.example.com/x, method = HTTP.POST)
```

Bare `POST` names nothing, and says what to write instead:

```
Error: type error: 2:1: unknown constructor 'POST' -- write 'HTTP.POST'
```

The type stays built in. The compiler names it — it is a field of the
`Net!http` payload — and a module's types are keyed by a path that moves
with `WAND_STDLIB`, which is the same reason `HTTPRequest` and
`HTTPResponse` are built in. What changed is where its constructors can be
read: `HTTP.Method` is the type, and `HTTP.GET` its constructors, in an
expression and in a pattern alike.

One position still accepts the bare name. `Mod.X(...)` reads that module's
names for the whole construction, field values included, which is how every
module has always read — so `HTTP.Request(method = POST)` typechecks, and
this release does not make it an error:

```ocaml
HTTP.Request(url = u, method = POST)        -- accepted, in this position only
HTTP.Request(url = u, method = HTTP.POST)   -- write this
```

Both build the same value. The qualified spelling is the one that reads the
same wherever it appears, and whether that position should keep its
exception is a question about every module rather than about HTTP.

### Upgrading

A file that builds a request without naming the module needs the prefix:

```ocaml
HTTPRequest(url = u, method = POST)        -- before
HTTPRequest(url = u, method = HTTP.POST)   -- after
```

`wand t` names each one and the correction. Requests written as
`HTTP.Request(...)` need no change.

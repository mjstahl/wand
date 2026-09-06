# HTTP, and the `Net` effect label

wand reaches the network today by running `curl`, so a manifest that should
say where a script sends bytes says which binary it runs. This document is
the design record for closing that: an `HTTP` module, and a tenth effect
label to go with it. It is a record of decisions and their reasons, written
before the code. It is not a specification.

- [Why the label and the library are one change](#why-the-label-and-the-library-are-one-change)
- [Settled by what is already here](#settled-by-what-is-already-here)
- [The narrowing unit is the host](#the-narrowing-unit-is-the-host)
- [A manifest word may be a pattern](#a-manifest-word-may-be-a-pattern)
- [One operation, named for its protocol](#one-operation-named-for-its-protocol)
- [The Request type](#the-request-type)
- [What a call answers](#what-a-call-answers)
- [Where the guarantee frays](#where-the-guarantee-frays)
- [Testing and rehearsal](#testing-and-rehearsal)
- [Transport](#transport)
- [Left out on purpose](#left-out-on-purpose)
- [Order](#order)

## Why the label and the library are one change

`effect_set.ml` states the rule for adding a label:

> One is added when something can actually perform it: network access
> reaches the outside world through a command today, and so reports as
> Shell.

So `Net` is not a decision that can be taken on its own. It is blocked
until a primitive performs it, and shipping `HTTP` without it would leave
`HTTP.get` reporting `Shell`, which is a lie. The two go in together or
neither does.

The label earns its place under the reference's own test. `What earns a
label` gives three justifications, and `Net` is the first of them — reach.
It reaches further than anything else on the list.

The cost is the sentence above that table: you must be able to hold every
label in your head. Nine becomes ten. `Net` is the most predictable of the
set, so the price is small, but it is a price and it is paid once.

This is a breaking change to the manifest grammar. wand has no outside
users, so it is free now and will not be later.

## Settled by what is already here

Five questions that look open are answered by precedent, and are recorded
here so they are not reopened.

**`Net` does not imply `Clock`.** `$()` waits on a subprocess for as long
as the subprocess takes, and carries `{Raise, Shell}`. An unbounded wait
behind a call is not what `Clock` is for.

**The host is checked as written. wand does not resolve DNS.** This is the
rule `shell_scan.ml` already states for binaries:

> Wrappers (`env`, `xargs`, `sh`) are *not* peeled: the wrapper is the
> thing the manifest allows.

The host as written is the thing the manifest allows. `Net(example.com)`
does not stop a connection to an IP literal that the script writes out.
Say this in the reference, or someone will read the label as a firewall.

**A host the run decides is checked at dispatch.** wand checks the
resolved URL against the same list. The check lives in the default
handler, so a test mock does not trip it and neither does a `--dry-run`
rehearsal. `V-NET1` reports each such site: a warning, an error under
`--strict`, for a repository that wants every host readable from the text.
This is the `V-SHELL1` paragraph with the nouns changed.

**A miss at dispatch raises, and can be caught. Nothing is sent.**

**`Net` and `Shell(curl)` coexist.** A script may still run `curl`, and a
reviewer still sees `Shell(curl)` when it does. The two labels are honest
about different things, and neither is a way around the other.

## The narrowing unit is the host

```
uses {Net(api.github.com, hooks.slack.com)}     -- yes
uses {Net(https://api.github.com/repos/*)}      -- no
```

The host answers the question a reviewer is asking, which is where the data
goes. A path list gets long, drifts on the first API change, and invites
people to read a manifest as an authorization boundary. It is not one.

The machinery for this mostly exists. The manifest AST is already a label
with an optional word list, so `Net(api.github.com)` parses today:

```ocaml
manifest : ((string * string list option) list * Token.loc) option;
```

One gate stands in the way — `parser.ml`, "only Shell takes a list of
binaries in a manifest" — and `check_shell_words` hardcodes `"Shell"` in
two places. Narrowing is one mechanism about to have a second user: a label
carrying an allow-list, checked over written literals, checked again at
dispatch, with a `--fix` that adds the missing word. Lift it out rather
than copying it.

## A manifest word may be a pattern

The mechanism above is being lifted out for its second user, so it gains
patterns once rather than twice. A word in any narrowed label may contain
`*`, and the rule is one line:

> `*` matches any run of characters that holds no separator. The separator
> is `.` in a host and `/` in a binary.

```
uses {Net(*.example.com)}          -- api.example.com, not a.b.example.com
uses {Shell(docker-*)}             -- docker-compose, docker-credential-osx
uses {Shell(./scripts/*)}          -- ./scripts/probe.sh, not ./scripts/a/b.sh
```

One separator, one `*`, no crossing it. This is what a shell glob does with
`/`, and what a TLS certificate does with `.`, so neither reader has to
learn a third convention. Nesting deeper is written with a second `*`.

**`Net(*)` and `Shell(*)` are errors.** A pattern that admits everything is
a bare `Shell` or a bare `Net` spelled at greater length, and the error says
to write that instead. A manifest should not have two spellings for the
same claim, and the shorter one is the one a reader already knows.

**A suggested manifest never contains a pattern.** `wand t` and
`wand t --fix` write the literal words they read, because a suggestion that
widened past what it observed would be inventing permission. A pattern is
something a person writes on purpose.

This does cost something, and it should be said plainly: `Net(*.example.com)`
admits hosts that appear nowhere in the file, so a reviewer no longer reads
the exact set off the first line. The claim weakens from *these hosts* to
*hosts of this shape*. It is still far narrower than bare `Net`, and the
alternative is a manifest line that grows a word per subdomain until nobody
reads it — which is the same failure by a slower route.

Two smaller rules follow from wand's own conventions. A manifest word is
**not** a `Glob` value: `Glob` is a type about paths, with rules about `./`
prefixes and directory parts that mean nothing to a hostname. And a `*` is
matched against the word as written, never against a resolved one, which is
the no-DNS and no-peeling rule already recorded above.

## One operation, named for its protocol

The effect family is `Net`. The operation is `Net!http`.

```ocaml
| Net!http request k -> k mocked_response
```

**One operation, because the operation count is the mocking surface.** The
reference warns what happens otherwise:

> The mock above still reports `Shell`. It does not cover
> `Shell!run_quiet`, `Shell!capture` or `Shell!exit_code`, and those three
> would reach the real shell.

Four operations means four ways for a test to think it is sealed and not
be. `HTTP.get`, `HTTP.post`, `HTTP.download` and the rest are written in
wand over the single primitive, so one handler case covers the module for
good.

**Named for the protocol, because the label should not have to grow
again.** A listening socket or a raw TCP read is a second operation under
the same label — `Net!tcp` — not an eleventh label. `Net` is the reach; the
operation says how. That keeps the head-count budget fixed no matter what
is added later, and it keeps one handler case per protocol rather than one
per convenience function.

What narrowing means for a future `Net!tcp` is not decided here. A host
list may not be the right unit for it, and it does not have to be: the
manifest already lets one label carry a word list whose meaning the label
defines.

## The Request type

Every field but the URL has a default, so field defaults do the work a
builder pattern does elsewhere, and record update gives the chaining.

```ocaml
type Method = Get | Post | Put | Patch | Delete | Head

type Request(
  url       : URL,
  method    : Method = Get,
  headers   : Map String = {},
  body      : String = "",
  timeout   : Duration = 30s,
  redirects : Int = 0,
)
```

```ocaml
let base = Request(url = api, headers = {authorization = "Bearer %{tok}"})
let slow = Request(base, timeout = 2min)      -- not {base with ...}
```

**`headers` is `Map String`, not `Map String String`.** `Map` takes one
parameter and its keys are always `String`. Header names are
case-insensitive on the wire and a `Map` is not, so the module lowercases
on the way in and out, and the reference says so. A request cannot repeat
a header, which is fine for requests. Responses genuinely repeat
`Set-Cookie`, and `URL` already answers that shape with a pair: follow it
with `HTTP.header` and `HTTP.header_list`.

**`body` is a `String`, and the effect system is why.** The tempting
version is a sum:

```ocaml
type Body = Empty | Text String | File Path    -- do not
```

A `File` case means `HTTP.request` can read the disk, so its signature
carries `FS.Read`, so every script that posts a little JSON declares
`FS.Read` in its manifest. That is the manifest getting less honest, which
is the thing being protected. File work goes in its own functions, where
the signature stays exact:

```ocaml
HTTP.download : URL -> Path -> Result String Unit     ! {Net, FS.Write}
HTTP.upload   : URL -> Path -> Result String Response ! {Net, FS.Read}
```

**`timeout` is a field, not a wrapper.** `Shell.timeout d thunk` and
`Par.timeout d thunk` both argue for a third wrapper. The wrapper loses
here: it cannot differ per request inside a `Par.map` over a list of URLs,
which is the case that wants a timeout most. A field is also visible at the
call site, where the reviewer is reading.

**`method` is a sum, not a `String`,** so a typo is a type error. It is the
same reason `Port` and `Version` are types. The library uppercases for the
wire. An `Other String` escape hatch is available later if an extension
verb ever asks for it.

## What a call answers

**A 404 is not an `Error`.** The exchange succeeded; the server said no.
`Error` is for a transport failure — DNS, connect, TLS, a timeout.

```ocaml
HTTP.get  : URL -> Result String Response ! {Net}
HTTP.get! : URL -> Response               ! {Net, Raise}
HTTP.ok?  : Response -> Bool
```

This is `$?()` and `$()` again. `$?()` hands back a `ShellResult` and lets
the caller ask; `$()` raises on a non-zero exit. So `HTTP.get` returns a
`Response` whatever the status, and `HTTP.get!` raises on a non-2xx.
`HTTP.ok?` is `Shell.ok?` for a status code.

The current port shows what this replaces. `examples/ports/http-retry.wand`
spends a paragraph apologising for curl:

> Every failure is retried, including a 404 that will never succeed.
> Telling those apart needs the status code, which `--fail` does not hand
> back; `--write-out "%{http_code}"` does, at the cost of parsing the
> number back out of the output.

A `Response` with a `status` field deletes that paragraph.

**A body is a `String`, never transcoded by charset.** A wand `String` is a
byte string — `String.length` is `String.length` on an OCaml `string`, and
there is no UTF-8 layer in `lib/` — so the bytes of a gzip response survive
being held in one. What does not survive is describing them: `String.length`
counts bytes rather than characters, `String.slice` cuts a multi-byte
character in half, and printing the value writes rubbish to a terminal.

So the reason binary goes to disk through `HTTP.download` is not that a
`String` would corrupt it. It is that a 2GB artifact should never become a
value at all, and that every `String` operation a caller reaches for
afterwards would be answering about bytes while sounding like it answers
about text. `download` streams, and is load-bearing rather than a
convenience — its doc should say so.

**Reading a body is a decoder.** No `get_json`. `HTTP.decode d response`
mirrors `Shell.decode d out`, for the reason `Shell` already gives: the
reading happens in one place, with a message that says what was wrong,
rather than a chain of scrapes that each assume the last one worked.

## Where the guarantee frays

The claim a manifest makes is that no byte leaves this program to a host it
does not name. Three things can void it quietly.

**Redirects.** `git` does not turn into `rsync` halfway through. A 302 does
exactly that, and this has no analogue in `Shell(git)`.

```
uses {Net(example.com)}     -- declared
                            -- 302 -> evil.test, and the body goes there
```

`redirects : Int = 0` answers both questions with one field: whether to
follow, and how many hops before a loop is a loop. At zero a 302 is simply
a `Response` with status 302 and the caller decides, which is how `$?()`
already behaves. Above zero, every hop is checked against the manifest.

**Proxy environment variables.** Honouring `HTTPS_PROXY` sends the bytes to
a host the manifest never named, *and* makes the call read the environment
— so `HTTP.get` would carry `{Net, Env}` and every script that fetches
anything would declare `Env`. wand ignores proxy environment variables. If
a proxy is ever wanted, it arrives as an explicit field, where it is
readable.

**TLS verification.** There is no toggle. An escape hatch here is used far
more often than it is needed, and a manifest cannot describe what turning
it off costs.

## Testing and rehearsal

**A test double is not optional.** `Test` has one for every effect —
`with_shell`, `with_lines`, `at`, `without_writes`. `Net` needs
`Test.with_http`, keyed by URL, and an `HTTP.requests` recorder mirroring
`Test.shell_calls`. The single `Net!http` operation is what keeps this to
one interception point.

**`--dry-run` follows the filesystem rule.** Reads go through; writes are
held and reported. Method safety maps onto that exactly: `Get` and `Head`
run, and every other method reports what it would send without sending it.

```
would POST https://api.example.com/deploy
```

A rehearsal that sends nothing cannot preview a script that fetches its
configuration before it posts, which is most deploy scripts. A rehearsal
that sends everything is not a rehearsal. Method safety is the line that
already exists in the protocol, so it is the one to use.

## Transport

Three ways to get bytes onto the wire:

- **`ocaml-tls` + `mirage-crypto`** — pure OCaml, so the static musl build
  survives. Roughly twenty transitive packages, and it brings a CA trust
  store problem: the binary carries its own stdlib but cannot carry a
  decision about system roots, and macOS does not keep them where Linux
  does.
- **OpenSSL bindings** — a short dependency list, and a C library in the
  way of a static build that already needs three retries on the runners.
- **A `curl` subprocess** — no new dependency, and the binary stops being
  the whole installation.

**Take the subprocess first.** The irreversible parts of this design are
the label, the narrowing unit, the operation name, the redirect rule and
the `Request` type. The transport is none of them. The manifest check works
on the URL, so the guarantee holds identically whichever way the bytes
move, and swapping in real TLS later touches no script.

It costs one asterisk, and the reference should carry it: `Shell(git)` then
means only `git` runs *from this script*, not that only `git` runs. That
asterisk is the argument for moving in-process eventually. It is not an
argument for paying twenty packages before the API has been used.

## Left out on purpose

**Retry.** `examples/ports/http-retry.wand` writes it in six lines, and
every call site wants it different — how many, what jitter, which failures
count, whether a 404 is worth a second try. It belongs in the docs.

**Cookies, sessions, auth helpers, multipart.** Each is a policy. None is
needed to make the manifest honest, which is what this change is for.

**Streaming a response.** `HTTP.stream_lines` pairs naturally with
`FS.stream_lines` and belongs with the wider `Stream` work, not here.

## Order

The narrowing unit is the host and the operation is `Net!http`; both are
decided. What is left in the same tier is the pattern rule — the separator,
and the refusal of a bare `*`. It is manifest grammar, so it is what cannot
be walked back.

Decide `--dry-run` next. It is the feature the README leads with, and it is
the one most likely to be discovered late.

Everything else is a library decision that can be revised in an afternoon.

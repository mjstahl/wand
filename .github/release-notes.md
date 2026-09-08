## 0.65.0 - 2026-09-07

wand can call an API without shelling out to `curl`, and the manifest says
where the bytes go rather than which binary ran.

### The tenth label

```ocaml
uses {Net(api.github.com, hooks.slack.com)}
```

Reaching the network went through a command, so a script that posted to
Slack declared `Shell(curl)`. That is the wrong sentence: it names the tool
and hides the destination, which is the one thing a reviewer is trying to
read off the first line.

`Net` says a file sends bytes to a host outside this machine, and the
manifest narrows it by host. The host is the unit because it answers the
question being asked. A path list grows long, drifts on the first API
change, and invites a manifest to be read as an authorization boundary,
which it is not.

The host is checked **as written**. wand resolves no DNS, so
`Net(example.com)` does not stop a connection to an address the script
writes out — the same rule `Shell(git)` already follows by not peeling a
wrapper. The manifest bounds the text, and that is the whole of what it
claims.

### Manifest words can be patterns

```ocaml
uses {Shell(docker-*)}        -- docker-compose, docker-credential-osx
uses {Net(*.example.com)}     -- api.example.com, not a.b.example.com
```

`*` stands for part of a name, and stops where the name's parts divide: at a
`/` in a binary, at a `.` in a host. So `Shell(./scripts/*)` admits
`./scripts/probe.sh` and not `./scripts/a/b.sh`, and `Net(*.example.com)`
admits `api.example.com` but neither `a.b.example.com` nor the bare
`example.com`.

Neither rule is new to learn. A shell glob already stops at `/`, and a TLS
certificate already stops at `.` and already refuses the bare domain.

A binary named without a path matches wherever it is found, which is how
`Shell(git)` has always admitted `/usr/bin/git`. That carries over: a
`Shell(docker-*)` admits a `docker-compose` anywhere on `PATH`. A host has
no such rule and is matched exactly as written.

A pattern is something a person writes on purpose. The ordinary manifest
still names its hosts one by one, `wand t --fix` writes the literal words it
read, and nothing turns a list into a pattern on an author's behalf —
widening past what was observed would be inventing permission.

Where one is written, it says so: `Net(*.example.com)` admits a host that
appears nowhere in the file, so a reviewer reads *hosts of this shape*
rather than *these hosts*. That is the author's trade to make against a line
that grows a word per subdomain, and it is still far narrower than bare
`Net`. `A-USES1` leaves a pattern alone rather than reporting it unused, for
the same reason: it claims a shape, and deleting it would undo a deliberate
choice.

`Net(*)` and `Shell(*)` are errors. A pattern that admits everything is the
bare label spelled at greater length, and a manifest should not have two
spellings for one claim.

### `HTTP`

```ocaml
uses {IO, Net(api.example.com)}
import HTTP
import IO

let r = HTTP.get! https://api.example.com/health
let () = IO.println "%{r.status}"
```

`request`, `get`, `post`, `download` and `upload`, each with a `!` sibling,
plus `ok?`, `header`, `header_list` and `decode`.

**A 404 is not an `Error`.** The exchange succeeded and the server said no.
`Error` is for the transport failing. This is `$()` and `$?()` again:
`HTTP.get` answers with a response whatever the status, and `HTTP.get!`
raises on a non-2xx. `examples/ports/http-retry.wand` used to spend a
paragraph explaining that `curl --fail` cannot hand back a status code, so
the retry could not tell a 503 worth asking again from a 404 that never
will. That paragraph is gone, and the retry is one `match` on `r.status`.

Every field but the URL has a default, so a request is written by naming
what differs, and record update gives the chaining a builder gives
elsewhere:

```ocaml
let base = HTTPRequest(url = api, headers = {authorization = "Bearer %{tok}"})
let slow = HTTPRequest(base, timeout = 2min)
```

**Every redirect is checked against the manifest.** A 302 is the one thing
that can send a body to a host nobody wrote down — `git` does not turn into
`rsync` half way through, and a redirect does exactly that. Following them
is the default because the check is what makes it safe: a manifest naming
two hosts admits a redirect between them, and one naming a single host does
not.

`download` writes to a file without the body ever becoming a value. That is
load-bearing rather than a convenience, and it is why a response body is a
`String`: a 2GB artifact should not be one.

`Test.with_http` answers requests from a table and `Test.http_calls` reports
what a body would ask for. Both cover every `Net` operation, so a test that
seals the module reaches nothing.

### The transport, and what it costs

wand has no TLS of its own, so bytes reach a host through a `curl`
subprocess. The alternatives both cost more than this release is buying: a
pure-OCaml stack is about twenty packages, and linking a C one statically
would make every advisory against it a wand release, for binaries already
copied onto machines.

That subprocess is **not** bounded by a narrowed `Shell`. `Shell(git)` means
only `git` runs *from this script*, not that only `git` runs. The reference
and the README say so rather than leaving it to be discovered, and `--trace`
reports the request.

Nothing about a script changes when TLS moves in-process, because the
manifest is checked on the URL either way.

### `--dry-run` sends what is safe to send

Reads go through and writes are held: that is the filesystem rule, and the
protocol already draws the same line. `GET` and `HEAD` are defined not to
change anything, so a rehearsal runs them and reports everything else:

```
would post: https://api.example.com/deploy -> 202, no body
```

A rehearsal that sent nothing could not preview a script that fetches its
configuration before it posts, which is most deploy scripts. One that sent
everything is not a rehearsal.

### An error position names its file

```
Error: eval error: 4:9: ...                        -- the file being run
Error: eval error: lib/deploy.wand:12:3: ...       -- a module it imported
Error: eval error: <stdlib>/HTTP.wand:71:11: ...   -- the standard library
```

A position used to be a line and a column, which reads as a line of the file
you are looking at. When the raise came from somewhere else, that sent you
to the wrong place entirely. Positions now carry the file they were lexed
from, and one in the file you asked to run stays bare, because that is the
file you have open.

### Also

An alias to a built-in record was broken, and had been since those records
existed: `type SR = ShellResult` was kept as a variant declaring a nullary
constructor named `ShellResult`, which shadowed the real one and took its
fields with it for the rest of the file — whether or not the alias was ever
used. Such an alias now builds, matches, and carries its field defaults.

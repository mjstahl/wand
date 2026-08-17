# Design: naming paths in `FS.Read` / `FS.Write`

**Status: proposal — not implemented.** Review this document before any
code changes. (Like the Shell-granularity doc before it, this file is a
review artifact: once the feature ships and the reference documents it,
it gets retired.)

## The problem

`FS.Write` is one bit, and it suffers the same collapse `Shell` did: a
deploy script's manifest says it writes, but `/srv/app` and `/etc/passwd`
are indistinguishable. The manifest should let the file say *where*:

```
uses {Shell(rsync), FS.Read(./build/**), FS.Write(/srv/app/**, /tmp/**)}
```

## This is not Shell(...) again

`Shell(git, curl)` stands on four legs, and three of them are missing
here. Command words are usually **literal** in the text; paths are
usually computed (`"%{target}/config.toml"`, `Path.join dir (basename
p)`) — our own demos have almost no literal write targets. `$()` is a
**syntactic form the file owns**, so each site carries its file's bound;
FS reach flows through ordinary calls into stdlib performs that carry no
site. And `wand t` could **infer** the Shell list from the text; it
cannot read a computed path, so it can never print an FS list to paste.

What survives is the runtime half — every FS effect arrives at the
default handler with a concrete path, with none of the `sh -c` parsing
swamp — and for disk, the runtime half is the valuable one. So this
design is honest about what it is: **a run-time bound with a small
static bonus**, not a static proof with a runtime net.

## Jurisdiction: the entry file bounds the run

The Shell rule ("each file's manifest bounds its own text") cannot work
here — there is no per-file text to bound. The rule that fits the shape
of the effect:

**The manifest of the file you run bounds every FS effect of the run,
imported helpers included.**

That asymmetry is deliberate, and it matches how each effect is used.
Command words are properties of a file's text, so they are audited per
file. Disk reach is a property of a *run* — the operator's question is
"what can `wand deploy.wand` touch?", and the answer should be on the
first line of `deploy.wand`, not spread across its imports.

Consequences, stated plainly:

- An imported file's `FS.Write(...)` list is **not** enforced when it is
  imported; only the entry file's is. A helper's list still gets the
  static literal check over its own text, and still documents intent.
- A REPL session, `wand e`, and any file without path lists run
  unbounded, exactly as today.
- The whole-run rule is what makes the mechanism cheap: the runner sets
  the entry file's lists once, and the default handler consults them —
  no site tagging, no closure surgery, and `Par` needs nothing new.

## What is checked, and when

1. **At `wand t`, literal paths in the declaring file's own text.** A
   literal `Path` argument to a known FS function — `FS.write_file!
   /etc/app/config.toml ...` under `FS.Write(/tmp/**)` — is a type error
   naming the path and the list. Modest coverage, but it catches the
   backup-script-that-also-writes-somewhere-new shape for free.
2. **At the moment of effect, every path.** The default handler checks
   the resolved path of each FS effect against the entry file's list —
   write-family effects (`write_file`, `append`, `create_file`,
   `delete`, `delete_tree`, `mkdir`, `rename`/`copy` destinations)
   against `FS.Write(...)`, read-family (`read_file`, `list_dir`,
   `glob`, `exists?`, `rename`/`copy` sources) against `FS.Read(...)`.
   A miss raises, catchably, without touching the disk. Mocks,
   `Test.without_writes`, and `--dry-run` intercept before the default
   handler, so they never trip it — same rule as Shell.
3. **No per-site lint.** `V-SHELL1` earns its keep because dynamic
   command words are the exception; dynamic paths are the rule, and a
   finding on nearly every FS call is noise, not audit. The narrowed FS
   list is understood as a runtime bound, and the reference says so.

## Pattern semantics

- Entries are the language's own path and glob literals: `/etc/hosts`
  (exactly that file), `/srv/app/**` (that subtree), `./build/**`
  (relative to the working directory the run started in), `~/x`
  (expanded at program start).
- Paths are judged **lexically normalized, symlinks not resolved**:
  the effect's path is made absolute against the starting working
  directory and `.`/`..` segments are collapsed, so `/tmp/../etc/x` is
  judged as `/etc/x` — but a symlink inside an allowed subtree can
  still point out of it. Audit surface, not sandbox: the same threat
  model as `Shell(...)`, stated in the reference the same way.
- **The temp family is its own grant.** `FS.temp_file!`/`temp_dir!`
  return system-tmp paths and are allowed under any `FS.Write(...)`;
  making every manifest carry `$TMPDIR` patterns would be ceremony
  without information. Subsequent writes *into* a returned temp path
  are allowed by the same grant.
- `FS.Read()` / `FS.Write()` empty is a parse error, like `Shell()`:
  a file that does not read drops the label.

## What this does not bound

A subprocess writes wherever it wants: `FS.Write(/tmp/**)` beside
`Shell(rsync)` bounds wand's own writes and says nothing about rsync's.
This is already true of the bare labels today, and the deploy scripts
this feature targets are exactly the Shell-heavy ones — so the reference
must say it bluntly: **the FS lists bound the wand-level effects; the
Shell list is the bound on everything else.** The two narrow different
things, and reading the one line tells you both.

## Inference and suggestions

`wand t` keeps suggesting bare `FS.Read`/`FS.Write` — it cannot read
computed paths, and a suggestion that cannot be trusted is worse than
none. This is the one manifest interaction where the author writes the
parenthesis by hand.

A possible follow-on, not part of this design: suggest from rehearsal —
record the path set a `--dry-run` touches and print a candidate list.
Named here so nobody mistakes its absence for oversight: the recorded
set is sample-dependent, and generalizing `leases/web-01`…`web-20` into
one glob is a heuristic. If it ever lands, it lands as "a candidate to
edit", never as "paste this".

## Mechanics

- The manifest already carries `(label, string list option)` pairs from
  the Shell work; `FS.Read`/`FS.Write` reuse the slot, and the parser's
  "only Shell takes a list" error relaxes to admit the two FS labels
  with path/glob-literal entries. Formatter and `render_manifest`
  extend the same way.
- The runner records the entry program's two lists (plus starting cwd
  for normalization) when a run begins; the default handler's FS cases
  check them. Handlers, `Par`, and the effect payloads are untouched.
- Compile-cache format bump (manifest shape is already version "2";
  this rides whatever bump is current at implementation time).

## Migration

Bare `FS.Read`/`FS.Write` keep meaning anywhere. Nothing is suggested
automatically, so no existing file changes meaning or gains warnings.
The demos are the dogfood candidates again — d5 writes under one target
directory, d6 writes exactly one config path — and narrowing them is
part of the acceptance below.

## Test plan (for the implementation, when approved)

- Parse/format round-trip: `FS.Write(/srv/app/**, ./build/**, ~/x)`;
  empty-list and non-path entries are errors.
- Static: a literal write outside the file's own list is a type error
  naming path and list; a literal inside passes; computed paths pass.
- Runtime: allowed and refused paths for each effect family; the
  refusal is catchable with `try`; `rename`/`copy` check source against
  read and destination against write; `..` normalization; a relative
  entry judged against the starting cwd.
- Temp grant: `temp_file!` under a narrow `FS.Write`, then a write into
  the returned path.
- Jurisdiction: an imported helper's write refused under the entry
  file's list; the helper's own list not enforced when imported; the
  same helper run directly is bounded by its own line.
- Interception: `--dry-run`, `Test.without_writes`, and a mock never
  trip the check.
- Demos: d5 and d6 narrowed, their run.sh moments updated.

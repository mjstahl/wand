# A rehearsal remembers

`--dry-run` withholds a change and reports it. It runs reads for real, so
that the script takes the path it would really take. That is the claim, and
it breaks at the first script that reads back what it wrote:

```ocaml
with FS.temp_dir "demo_" as d -> (
  let f = Path.join d ./x;
  FS.write_file! f "hi\n";
  IO.println (FS.read_file! f)
)
```

```console
$ wand --dry-run w.wand
would create temp directory: demo_ -> /tmp/wand-dry-run-189895a-dir
would write: /tmp/wand-dry-run-189895a-dir/x (3 bytes)
read: /tmp/wand-dry-run-189895a-dir/x
Error: read_file: /tmp/wand-dry-run-189895a-dir/x: No such file or directory
```

The real run prints `hi`. The rehearsal fails on a line the real run never
fails on, and it fails late — after it has already reported two steps as if
they had happened. A rehearsal that stops early reports less than the whole
plan, which is the one thing it is for.

This is the design record for the fix. It is a record of decisions and their
reasons, written before the code. It is not a specification.

- [The rule](#the-rule)
- [Where the overlay lives](#where-the-overlay-lives)
- [What it holds](#what-it-holds)
- [Which operations record, and which consult](#which-operations-record-and-which-consult)
- [The environment has the same hole](#the-environment-has-the-same-hole)
- [What stays different from a real run](#what-stays-different-from-a-real-run)
- [Left out on purpose](#left-out-on-purpose)
- [Order](#order)

## The rule

A rehearsal answers every read as the real run would answer it, and changes
nothing outside the program.

Today it keeps the second half and drops the first. The fix is an overlay: a
rehearsal remembers what it withheld, and answers later reads from that
memory before it looks at the disk.

This is not a sandbox and does not become one. Nothing is intercepted that
was not intercepted before. The overlay only decides what a withheld
operation answers with.

## Where the overlay lives

In the rehearsal's own handler, not in the default handler.

`run_in_mode` already wraps the program in a handler that sees every
operation, decides whether to withhold it, and either substitutes an answer
or passes it to the default handler. That is the one place that knows a
rehearsal is happening. The default handler stays what it is: the single
implementation of each operation, which is what stops a rehearsal drifting
from a real run by reimplementing one.

So the overlay is one value, created per run, read and written by that
handler alone.

## What it holds

A path maps to one of three things:

- **A file**, with its contents and the moment the rehearsal wrote it.
- **A directory.**
- **Gone**, for a path the rehearsal deleted.

A path the overlay does not name is not known to it, and the read goes to
the disk. So a rehearsal reads the real tree everywhere it did not pretend
to change it, which is what makes the control flow honest.

Contents are held in memory. A rehearsal of a script that writes a 10GB file
holds 10GB, and that is the honest cost of answering the read that follows.
A rehearsal is not a batch job; the alternative is a temporary tree on disk,
which is a change outside the program and is the thing being avoided.

## Which operations record, and which consult

**Record** — every withheld change:

| operation | what the overlay learns |
|---|---|
| `FS!write_file` | the file, with the given contents |
| `FS!append` | the file, contents extended (from the overlay, else the disk, else empty) |
| `FS!write_lines`, `FS!append_lines` | the file, from the lines the stream produced |
| `FS!create_file` | an empty file, when there is not one already |
| `FS!delete` | gone |
| `FS!delete_tree` | gone, and every path under it |
| `FS!mkdir` | a directory, and its parents |
| `FS!rename` | the new path with the old path's contents; the old path gone |
| `FS!copy` | the new path with the source's contents |
| `FS!copy_tree` | every file under the source, at its place under the destination |
| `FS!temp_file` | an empty file at the substituted path |
| `FS!temp_dir` | a directory at the substituted path |

**Consult** — every read, whether or not it is withheld:

`FS!read_file`, `FS!stream_lines`, `FS!exists?`, `FS!file?`, `FS!dir?`,
`FS!size`, `FS!mtime`, `FS!list_dir`, `FS!glob`, `Hash!file`.

`list_dir` and `glob` answer with the disk's entries and the overlay's
together, minus what the overlay says is gone. A rehearsal that writes three
files into a directory and then lists it sees three more entries than the
disk has, which is what the real run would see.

The two sinks need one change to make this work. `FS!write_lines` answers
with an open file today. It will answer with a pair of closures instead —
write a line, and close — so the real handler can hand back the channel and
the rehearsal can hand back a buffer that commits to the overlay. The value
stops naming an `out_channel`, which it should not have named anyway: the
sink is a place lines go, not a file.

## The environment has the same hole

`Env!set` is withheld in a rehearsal, so `Env.get` after `Env.set` answers
what the shell had rather than what the script set. The same overlay answers
it: a name maps to a value it was set to, or to gone. `Env!get` and `Env!all` consult it.

`Env!read` needs nothing of its own. It is handed the text of a dotenv file,
which the wrapper already read through `FS!read_file`, so the file half of
the overlay answers it.

It is the same bug and the same fix, and leaving it out would mean a
rehearsal is honest about files and not about variables.

## What stays different from a real run

Said in the reference rather than left to be discovered.

- **A withheld command changes nothing the overlay can know.** `$(cp a b)`
  is reported and not run, and no read sees `b`. wand cannot model what a
  subprocess would have done. This is the limit of a rehearsal, and it is
  the reason a manifest names the binaries a file may run.
- **Only the program's own changes are remembered.** The disk is read as it
  is now, so a rehearsal of a script that races something else is not a
  prediction.
- **`mtime` of a written file is the moment the rehearsal wrote it**, not
  the moment a real run would have. Nothing else could be true.
- **Permissions and ownership are not modelled.** A rehearsal answers about
  contents and existence.

## Left out on purpose

**A rehearsal that writes to a scratch tree.** Real files under a temporary
root would answer every read for free, including the reads the overlay
cannot answer, and `cp` inside a withheld command would still miss it. It
also writes to disk during a rehearsal, which is the promise being kept.

**Making the overlay visible to a script.** No `Rehearsal.` module and no
way to ask whether this is a rehearsal. A script that behaves differently in
a rehearsal is a script the rehearsal cannot speak for.

**Sharing it across `Par` workers.** A worker's rehearsal already forwards
its effects to the main handler, so one overlay serves them all. Nothing
extra is needed and nothing is promised about ordering between workers,
which is what `Par` already says.

## Order

The overlay and the `FS` reads first, because that is the bug. Then the
sinks' change of value, which the overlay needs. Then `Env`. Then the
reference's account of what a rehearsal is and where it stops.

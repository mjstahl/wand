## 0.62.1 - 2026-09-06

`Stream` gets the stages between the source and the fold. `FS` gets the
write end it never had. And `--dry-run` answers a read from what it
withheld, so a script that writes a file and reads it back no longer fails
in a rehearsal.

### The stages

```ocaml
filter_map : ('a -> Option 'b ! 'e) -> Stream {..} 'a -> Stream {..} 'b
flat_map   : ('a -> List 'b ! 'e) -> Stream {..} 'a -> Stream {..} 'b
take_while : ('a -> Bool ! 'e) -> Stream {..} 'a -> Stream {..} 'a
drop       : Int -> Stream {..} 'a -> Stream {..} 'a
drop_while : ('a -> Bool ! 'e) -> Stream {..} 'a -> Stream {..} 'a
indexed    : Stream {..} 'a -> Stream {..} (Int, 'a)
scan       : ('a -> 'b -> 'a ! 'e) -> 'a -> Stream {..} 'b -> Stream {..} 'a
chunks     : Int -> Stream {..} 'a -> Stream {..} (List 'a)
unique     : Stream {..} 'a -> Stream {..} 'a
```

`filter_map` maps and filters in one step. A line that does not parse
answers `None` and never reaches the fold, which is how a stream handles a
bad line.

`flat_map` is the one stage that emits more than it is given. A log line
that holds several records needs it.

`scan` is a running `fold_left`. Each element answers with the total after
it, so a running sum is a stream rather than a fold that keeps a list.

`chunks n` groups elements into lists of n, and the last group holds what is
left. Batching a write is the case for it: a thousand rows per request
rather than one, without holding the file.

`unique` holds every distinct element it has seen. On a source without an
end that is memory without an end, and the doc says so.

There is no `zip` and no `concat`. Two streams advanced in step is array
code rather than log reading, and the concatenation people want is several
files read as one.

### The write end

```ocaml
FS.stream_lines /var/log/app.log
|> Stream.filter (fn l -> String.contains? "ERROR" l)
|> FS.write_lines! ./errors.log
```

`FS.stream_lines` read and nothing wrote. So a filtered log was
`Stream.each` with `FS.append!`, which opens and closes the file once per
line. `FS.write_lines` and `FS.append_lines` open the file once and write
each element on its own line. Both have `!` siblings.

`FS.stream_lines_all` reads several files as one stream:

```ocaml
FS.glob *.log |> FS.stream_lines_all |> Stream.count
```

It opens each file when the file before it runs out, so it holds one file
open however many are named.

### A rehearsal remembers

```console
$ wand --dry-run publish.wand
would create temp directory: build_ -> /tmp/wand-dry-run-8b792a8-dir
would write: /tmp/wand-dry-run-8b792a8-dir/manifest.json (214 bytes)
read: /tmp/wand-dry-run-8b792a8-dir/manifest.json
would delete recursively: /tmp/wand-dry-run-8b792a8-dir
```

`--dry-run` withholds every change and runs every read. Those two contradict
each other as soon as a script reads back what it wrote: the write was
withheld, so the read found nothing. The rehearsal failed on a line the real
run never fails on, and it failed after reporting two steps as though they
had happened.

A rehearsal now remembers what it withheld. Writes, appends, deletes,
renames, copies, directories, the stream sinks and `Env.set` are all written
down, and every read consults them: `read_file`, `stream_lines`, `exists?`,
`file?`, `dir?`, `size`, `mtime`, `list_dir`, `glob`, `Hash.file`,
`Env.get`, `Env.all`. A path the rehearsal did not touch is read from the
disk as it is.

Nothing is written to disk. The memory is the program's and goes when the
program does.

Four things stay different from a real run:

- A withheld command changes nothing a read can see. `$(cp a b)` is
  reported and not run, so no read finds `b`. wand cannot model what a
  subprocess would have done.
- Only the script's own changes are remembered.
- `mtime` of a file the rehearsal wrote is when it wrote it.
- Permissions and ownership are not modelled.

A second report was missing for the same reason. `FS.temp_dir`'s release
asks `exists?` first, which was false in a rehearsal, so the plan ended
without the `would delete recursively` line that a real run performs.

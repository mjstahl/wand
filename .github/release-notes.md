## 0.64.0 - 2026-09-07

Two filesystem primitives that a shell script fakes and gets wrong: an
atomic write, and a lock.

### Publishing a file

```ocaml
FS.write_atomic! /etc/app/config.toml (TOML.stringify (TOML.of! settings))
```

`FS.write_file` opens the target and truncates it, so a reader can see a
short file. `FS.write_atomic` writes to a temporary file beside the target
and renames it over the target. A reader gets the whole of the old contents
or the whole of the new ones.

The version people compose by hand is wrong three ways, and none of them
shows on the machine where the script is written.

- **The temp file lands on another filesystem.** `FS.temp_file` is committed
  to the OS temp directory, and a rename cannot cross a device. On a Linux
  box where `/tmp` is tmpfs, the rename fails. The script passes in
  development and fails in CI.
- **The published file changes mode.** A rename replaces the inode, so the
  target's permissions become the temp file's. A 644 configuration file
  silently becomes 600.
- **A symlink is replaced rather than followed.** `write_file` writes through
  a link. A rename replaces the link itself, so a deploy publishing to
  `/etc/app/config -> config.v3` gets the opposite of what it asked for.

`write_atomic` puts the temp file beside the target, carries an existing
target's mode across, and writes through a symlink. It syncs the temp file
before the rename, so a published file is never a name with nothing behind
it. It does not sync the directory, so a power loss can still lose the
publication: what it promises is that no reader sees half a file, not that
the write survives the machine going down.

Reading the mode and resolving the link are stats, so this is the one write
that declares `FS.Read` as well as `FS.Write`.

`FS.write_lines_atomic` is the same publication for a stream, so a filtered
log can be published rather than filled:

```ocaml
FS.stream_lines /var/log/app.log
|> Stream.filter (fn l -> String.contains? "ERROR" l)
|> FS.write_lines_atomic! ./errors.log
```

It publishes only a stream that finished. `FS.write_lines` writes into the
target, so a source that fails part way leaves the file short -- the old
contents destroyed and the new ones incomplete. This one removes its temp
file and leaves the target holding what it held.

`FS.write_file` is not atomic and does not become so. Atomicity costs a
rename and a new inode, and the name is where that is said.

### Guarding a run

```ocaml
with FS.lock /var/run/deploy.lock as taken ->
  match taken with
  | Ok _ -> deploy ()
  | Error FS.Held -> IO.println "a deploy is already running"
  | Error FS.Denied why -> Proc.exit 1
```

A lockfile holding a pid goes stale the moment a job is killed: the next run
finds the file, tries to work out whether that process is alive, and races
everyone else doing the same. `FS.lock` is the kernel's lock, so it is
released when the process dies -- `kill -9` included. Nothing goes stale,
and there is no policy for breaking a stale lock, because there are none.

The acquire says which failure it was. `Held` is another run, which is the
guard working, so a cron job stands down and exits 0. `Denied` is a lock
that could not be asked for at all, which is a broken script and exits 1.
`flock -n` reports both as one non-zero exit, so a shell guard that is quiet
about the first is quiet about the second too.

`FS.lock!` raises on either, for a script with nothing to say about both.

The lock guards other `Par` workers as well as other processes: a lock
belongs to the open file rather than to the process, so a second worker
conflicts with the first exactly as another process would. It follows that a
lock is not re-entrant.

The lock file is created if missing and is **never deleted**. That looks
like a leak and is not -- deleting it is the very race the lock prevents,
since another process can be holding the same name open, and after the
delete the two hold locks on two files with one name.

On NFS the lock is emulated and is not dependable. Keep the file on the
machine that runs the job.

A rehearsal takes the lock, unlike every other `FS.Write`. Withholding it
would let a `--dry-run` run beside a real one, which is the situation being
guarded against.

### Waiting for a lock

```ocaml
with FS.lock_wait 5min /var/run/deploy.lock as taken -> ...
```

`FS.lock` never waits. `FS.lock_wait` is for a script that would rather
queue than stand down -- a deploy behind another deploy, where the second one
still has to happen.

A budget that runs out answers `Held`: waiting and being told no says what
being told no at once says. A `Denied` ends the wait immediately, and so
does a wait on a lock the same bracket already holds, since nothing is going
to release it.

It carries `Clock`, because it sleeps, so a script that waits for a lock
says so in its manifest and one that does not, does not.

A rehearsal takes the lock and does not wait, and says so in the line it
reports. A rehearsal that waited out a real budget would be useless on
exactly the scripts that need one.

### Testing a guarded script

`Test.with_lock` answers every acquire as taken and `Test.with_lock_held`
answers every acquire as held, so both branches of a guarded script are
reachable from one process and no lock file is created. `Test.lock_calls`
reports the paths a body would lock. All three answer a waiting acquire at
once, so a test of a five-minute wait takes no time.

`Test.without_writes` and `Test.writes` now cover every write of a file's
contents rather than `write_file` alone. They missed `append`,
`create_file`, `write_lines` and `append_lines`, so a sealed test wrote to
the real disk the moment a script reached for one of them. `delete`,
`mkdir`, `rename`, `copy` and taking a lock still reach the disk.

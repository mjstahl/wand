## 0.68.0 - 2026-09-09

A security review of the whole tree, and what it found. Six areas were read
end to end — shell execution, the effect system, the filesystem and the
cache, the CLI and language server, CI and supply chain, the standard
library's parsers — and every critical and high finding was reproduced
against the built binary before anything was changed.

Twenty-six findings are fixed.

### Typechecking ran the code it imported

This is the one that blocked the release.

```
-- evil.wand
uses {Shell(sh)}
let boom = $(sh -c "echo owned > PWNED")

-- victim.wand
let {boom} = import ./evil
let x = boom
```

`wand t victim.wand` created `PWNED` and exited 0. Typechecking evaluated
every imported module under the same handler a real run uses. The language
server typechecks on every keystroke, so opening a file in an editor ran what
it imported — and the attacker writes the imported module's own manifest, so
nothing static stood in the way.

Loading a module for its signature and loading it to use it are two different
questions now. `wand t`, `wand f`, `wand t --fix`, the linters and the
language server load a module for its types and never evaluate its body.
Running a script, running a test file and the REPL still do. A type error or
a manifest violation inside an import is still reported.

### A newline was not a command separator

Under `uses {Shell(echo)}`:

```ocaml
let c = "hi\ntouch NEWLINE_PWNED"
IO.println $(echo %!{c})
```

ran `echo`, then ran `touch`, and exited 0. The shell reads an unquoted
newline as a separator; wand read it as whitespace, so the word after one was
never a command position and neither check ever saw it. It sets the same flag
`;`, `|` and `&` do now. A newline inside quotes is still data.

### Two crashes a script could not catch

`JSON.parse "1e999999"` answered `Ok` with a value holding infinity, and
every later look at it — `JSON.stringify`, `"%{j}"` — ended the program with
a fatal error, past `try` and past `$?()`. Meanwhile `stringify_pretty` wrote
`Infinity`, which is not JSON: the two serializers disagreed about the same
value.

A NUL byte in a shell splice did the same. A `String` holds bytes, and one
reaches a splice from a command's output, a file read or `Base64.decode!`.

Both are ordinary raises now.

### Three things that used to work and no longer do

- **`192.168.001.1` is not an address.** A leading zero is octal to libc and
  to every resolver, so `010.8.8.8` was `10.8.8.8` here — private — and
  `8.8.8.8` everywhere else. A script asking `IPv4.private?` and handing the
  same text to a command checked one host and reached another
- **`JSON.parse` refuses a number that reads as infinity.** JSON has no way
  to write one, so no `JSON` value holds one, and reading, writing and
  showing a value cannot fail. `YAML` reads into the same value, so `.inf` is
  an error there too
- **`wand s` does not walk into a symlinked directory.** A run covers what
  the tree holds. A directory named on the command line is still searched,
  and a linked *file* is still read

If a leading-zero address is a real spelling in your scripts, that was the
hazard rather than a convenience.

### A release now says who built it

The `.sha256` beside an archive is written by the job that builds the archive
and uploaded next to it, so anyone who can write the release can write both:
it authenticates the download, not the publisher.

Each release build job now signs a build attestation over the archive it
built, with a token it cannot forge or pass on.

```sh
gh attestation verify wand-0.68.0-linux-x86_64.tar.gz --repo mjstahl/wand
```

It covers the three archives CI builds. The macOS x86_64 archive is built by
hand, because GitHub's Intel runner never leaves the queue, so it has the
`.sha256` and no attestation — worth knowing before you run the command
against it.

### The rest

- A corrupt compile-cache entry used to segfault **every later run** of that
  script until the cache was deleted by hand. Entries carry a digest now, and
  the write reaches the disk before the rename
- One malformed frame killed the language server, and every request after it
  in that session went unanswered with nothing to say why
- `wand f` and `wand t --fix` truncated your source and then filled it. Both
  write beside and rename into place now, keeping the mode and writing
  through a symlink
- `FS.lock` leaked into spawned children, so a script that started a
  background process while holding the lock left the next run reporting
  `Held` with nothing holding it — the cron guard the lock exists for
- `FS.copy` read the whole file into memory. A 1 GB copy peaks at 7.0 MB now
  instead of 1.08 GB
- `Env.clear` set the name to the empty string, which a child can tell from
  its absence. It removes it
- `Size` and `Duration` addition wrapped silently past the end of an `Int`
- `Regex.compile "a{999999999}"` never finished. A repeat is bounded at
  10,000; matching is a non-backtracking automaton and is unaffected
- The VS Code Rehearse lens built a shell command with the file name in it,
  so a file named `x$(cmd).wand` ran `cmd` when the lens was clicked
- `wand.autoEdit` turns off the edits the server pushes as you type, and
  `wand.path` is machine scope so a workspace cannot redirect the server
- `FS.delete_tree` named every step by path — `lstat` said a name was a
  directory, `readdir` listed it, `rmdir` removed it — so anything able to
  write inside the tree could swap a directory for a symlink between two of
  those and send the deletions elsewhere. It walks by directory descriptor
  now, which is what `rm -rf` does
- `install.sh` could not resolve "latest" without curl, and its wget fallback
  is gone rather than repaired — it never asked wget for the headers it was
  scraping, no CI runner lacks curl so it never ran anywhere, and the text it
  read differs between the wget on Alpine and GNU's. The script needs curl
  now and says so
- The reference records that `%{x}` is one-word safe but **not option safe**.
  It decides where an argument ends, not how the command reads it, and most
  commands read a leading dash as a flag — `$?(grep %{pat} f)` with
  `pat = "--version"` prints grep's version. Use `--` where the value comes
  from outside the script
- CI pins every action to a commit, declares its token scopes, and passes
  trigger values through `env:`

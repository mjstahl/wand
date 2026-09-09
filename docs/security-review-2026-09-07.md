# Security review, 2026-09-07

A pre-release audit of the whole tree at commit `33e96eb`. Six areas were
reviewed: shell execution, effect-system soundness, filesystem and cache
handling, the CLI/REPL/LSP, CI and supply chain, and the stdlib parsers.
Every critical and high finding was reproduced against the built binary.
Line numbers refer to `33e96eb`.

**Closed 2026-09-09.** Every finding is either fixed — see **Fixed** at the
bottom, one line each with the commit — or kept for a stated reason under
**Kept, with the reason**. Nothing is open.

## Verdict

The core guarantees mostly hold. Shell quoting resisted every injection
payload. The effect table is complete. The dry-run overlay withholds every
write it promises to. The Marshal cache is permission-gated.

Two findings broke the README's promises and blocked release: typechecking
executed imported code, and a newline bypassed the `Shell(...)` allowlist.
Both are fixed.

---

## What held up (verified, no action)

- **Shell quoting.** `shell_quote` (evaluator.ml:1435) and `quote_within`
  (1455) resisted every payload: quotes, backslashes, `$()`, backticks,
  history expansion, splices inside the author's own quotes. Empty value
  becomes `''`.
- **Allowlist mechanics apart from H1.** `env git` refused under
  `Shell(echo)`; dynamic first words caught at spawn; `;` `&&` `|`
  subshell and backtick positions scanned; reserved words refused;
  Command values carry the allowlist of the file where the literal was
  written (evaluator.ml:1728, 4837-4847), and building one already
  requires the Shell effect there.
- **The effect table.** Every world-touching builtin carries the right
  label; streams pay at the fold; `discharge` (effect_set.ml:213) removes
  a label only when every operation carrying it is handled; unification
  over-approximates, never omits; no unsafe escape hatch; `Hole` raises at
  eval.
- **Manifest checking on run paths.** `check_manifest`
  (typechecker.ml:4429) is reached from every entry point via
  `infer_program_body`. A file with no manifest is unbounded by design.
- **Dry-run.** Every `is_mutation` case has a matching `remember_change`;
  reads consult the overlay (runner.ml:2047-2278); shell run/capture/
  stream withheld; temp names are 8 random bytes per call; Par forwards
  effects to the calling domain, so it cannot escape a rehearsal.
  `Proc.exit` is the one gap (Low above).
- **Cache trust gate.** Marshal reads only from a uid-owned,
  non-group/other-writable dir (compile_cache.ml:98-107); entries 0600 via
  temp+rename; key covers format version, binary identity, path, source,
  transitive dep keys. What is marshaled is types only — no closures, no
  code; effects are re-inferred every load. M1 is the remaining hole.
- **Atomic writes.** `write_atomic` (runner.ml:789-835): same-dir temp,
  urandom name, O_EXCL, fsync before rename, target mode preserved.
- **Resource brackets.** Release runs on raise, `Proc.exit`, and SIGTERM
  mid-body; interrupts deferred around acquire and release
  (evaluator.ml:1861-1888).
- **FS modes.** Explicit everywhere — 0644 files, 0700 temp dirs, 0600
  temp files; verified under `umask 0`.
- **Glob.** Symlinks match as entries, never traversed
  (evaluator.ml:4600-4632).
- **Hostile-data robustness.** Million-deep JSON parses and stringifies
  (Yojson is iterative); deep wand recursion returns "too many nested
  calls", never a segfault (evaluator.ml:677-697); TOML and CSV fail
  closed; Base64 never crashes; Int arithmetic overflow-checked; URL
  parsing handles `https://good.com@evil.com` correctly (host is
  `evil.com`); Regex matching is linear (Re automaton — `^(a+)+$` on 5000
  chars in ~25ms).
- **Crypto labels are honest.** Digestif primitives; `Hash.equal?` is
  constant-time via Eqaf (evaluator.ml:3835-3837); MD5/SHA1 marked
  interop-only; Random marked predictable.
- **install.sh.** Fails closed on checksum mismatch; verify → extract →
  run → install inside one fresh 0700 `mktemp -d`; all variables quoted;
  atomic `mv -f`.
- **Argument parsing, fix machinery, diagnostics.** `--` splitting and
  `-e` shielding are careful; `Diag.Replace` applies only when the byte
  extent matches exactly, bounds-checked; `escape_json` escapes control
  bytes; REPL completion evaluates nothing.

## Suggested fix order

1. ~~C1~~ — done at `d20f7d1`.
2. ~~H1~~ — done at `d427837`.
3. ~~H2 + H3~~ — done at `5c43893`.
4. ~~M2, M6, M7~~ — done at `dc45301`.
5. ~~M1, M3, M4, M5~~ — done at `a476a1e`, `616250b` and `8d22d73`.
6. ~~M8 and the workflow hygiene items~~ — done at `1b5db1e`.
7. ~~The two decisions M8 left~~ — done at `24e963c`.
8. ~~The Lows, then the functionality bugs~~ — done at `d91db2c`, `0949b29`,
   `4a98cd2`, `64d64e3`, `c748bea`, `02a7246` and `315e4ae`.

The review is closed.

## Kept, with the reason

- **`delete_tree` walks by path.** Between the `lstat` that says "directory"
  and the `readdir` that reads it, that name can be replaced with a link.
  Closing it means walking by directory descriptor — `openat`, `fdopendir`,
  `unlinkat` — none of which OCaml's Unix has, so the whole traversal would
  move into C. It needs someone able to write inside the tree while wand
  deletes it. The reason is beside the code.
- **The macOS x86_64 release archive has no build attestation.** It is built
  by hand, so no workflow produced its bytes and none can honestly claim
  them. Closing it means CI building that target.
- **install.sh's wget path is fixed but not run.** There is no wget on the
  machine the fix was written on. The sed was checked against wget's header
  format; the `-S` behaviour was not.

## Fixed

- **C1. Typechecking and the LSP execute imported modules** — `d20f7d1`.
  `load_imports_for` and `load_module` take `~evaluate`; every analysis path
  passes false and loads a module for its types only. The module cache is
  keyed by the mode as well as the path. Left open by design, and separate
  from this: whether an import's top-level effects should join the
  importer's manifest.
- **H1. Newline bypasses the `Shell(...)` allowlist** — `d427837`. The
  newline arm of `scan_lit` sets `expecting`, as `;` `|` `&` do.
- **H2. JSON round-trip of a huge exponent is an uncatchable crash** —
  `5c43893`. No JSON value holds an infinite or NaN number; each door
  refuses one. YAML is read into the same value and answers the same way.
- **H3. NUL byte in a shell splice is an uncatchable crash** — `5c43893`.
  `create_process_for` checks before it spawns and raises.
- **M2. Lock fd leaks into spawned children** — `dc45301`. O_CLOEXEC on the
  lock open, and on the three other opens in runner.ml. O_NOFOLLOW was not
  added: the lock path is resolved with `realpath` on purpose, so a
  symlinked lock file is a supported spelling.
- **M6. Size and Duration addition wraps silently** — `dc45301`. Both use
  the checked add, as do the two `DateTime` arms that were raw.
- **M7. IPv4 leading-zero octets read as decimal** — `dc45301`. A lex error
  naming the rule. This takes a spelling away: `192.168.001.1` was an
  address and is not one now.
- **M1. Corrupt compile-cache entry segfaults wand persistently** —
  `a476a1e`. An entry carries a digest of its bytes, checked before anything
  is unmarshalled, and the write reaches the disk before the rename. Format
  version 5. This answers corruption; `dir_is_trustworthy` is still what
  answers chosen bytes.
- **M3. `wand f` and `wand t --fix` destroy the file on a crash** —
  `8d22d73`. Both go through `write_atomic`.
- **M4. One malformed LSP frame kills the server** — `616250b`. A body that
  is not JSON is answered with -32700 and the session goes on; a length the
  server will not read ends the stream the way the client going away does.
  Lengths are digits only and at most 64MB.
- **M5. `wand s` follows symlinks out of the tree** — `8d22d73`. The walk
  uses `lstat` and does not descend through a link. A linked *file* is still
  read, deliberately: it is one visible name, and it is how dune's sandbox
  presents a `source_tree` dep.
- **M8. CI: unpinned cross-repo code executes; ci.yml has no permissions** —
  `1b5db1e`. `mjstahl/setup-wand` is pinned to a commit, `ci.yml` declares
  `contents: read`, and every action is pinned to a commit with its tag
  beside it.
- **The release `.sha256` authenticates the download, not the publisher** —
  `24e963c`. Each build job signs a build attestation over the archive it
  built; `gh attestation verify <archive> --repo mjstahl/wand` checks one.
  `permissions:` moved from the workflow to the two jobs, so the build job no
  longer has `contents: write`. The macOS x86_64 archive is built by hand and
  has no attestation -- no workflow produced its bytes, so none can honestly
  claim them. `make release-archive` says so, and the README names what is
  covered.
- **Action pins go stale** — `24e963c`. `.github/dependabot.yml` bumps them
  weekly, grouped into one PR.
- **Regex compile bomb** — `d91db2c`. A counted repeat is bounded at 10,000,
  in a literal and in `Regex.compile`.
- **`FS.delete`, `copy_tree`, `copy_file`, `Env.clear`, `FS.temp_dir`** —
  `0949b29`. A name is removed rather than what it points at; a re-run
  survives a dangling link; a copy is a block at a time (1 GB file: 1.08 GB
  resident, now 7.0 MB); `clear` unsets; `temp_dir` is `mkdtemp`.
- **Cache check-then-open** — `4a98cd2`. The entry is judged by `fstat` of
  the descriptor: regular, owned by this user, not writable by anyone else.
- **VS Code extension, and the LSP editing unasked** — `64d64e3`. The
  Rehearse terminal spawns from an argv; `wand.path` is machine scope;
  `wand.autoEdit` gates the pushed edits, default on.
- **Daily-fuzz reporting, install.sh wget** — `c748bea`. One failed filing no
  longer ends the loop, the fence is measured from the text, and the wget
  header is read with `-S` and an indent-tolerant pattern.
- **Fuzzer eval child memory** — `02a7246`. `RLIMIT_AS` on Linux, a GC alarm
  everywhere, 1GB either way.
- **`%{x}` is one-word safe, not option safe** — `315e4ae`. Documented, with
  the `--` sentinel.
- **`Proc.exit` under `--dry-run`** — `0949b29` and `315e4ae`. The rehearsal
  ends there, as a run does, and the line says so.
- **Comment drift on the cache format version** — `a476a1e`, where the
  version moved to 5.
- **Workflow interpolation hygiene** — `1b5db1e`. `installs.yml` and
  `daily-fuzz.yml` take trigger values through `env:`. The fuzz step also
  checks the seed, shard and minutes are digits: `$(( ))` evaluates what a
  variable holds, so `env:` alone does not close arithmetic injection.

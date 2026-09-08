# Security review, 2026-09-07

A pre-release audit of the whole tree at commit `33e96eb`. Six areas were
reviewed: shell execution, effect-system soundness, filesystem and cache
handling, the CLI/REPL/LSP, CI and supply chain, and the stdlib parsers.
Every critical and high finding was reproduced against the built binary.
Line numbers refer to `33e96eb`.

Status key: each finding is `open` until a fix lands. Update this file as
fixes land; move a fixed item to the bottom with its commit.

## Verdict

The core guarantees mostly hold. Shell quoting resisted every injection
payload. The effect table is complete. The dry-run overlay withholds every
write it promises to. The Marshal cache is permission-gated.

Two findings broke the README's promises and blocked release: typechecking
executed imported code, and a newline bypassed the `Shell(...)` allowlist.
Both are fixed; see **Fixed** at the bottom.

---

## Medium

### M1. Corrupt compile-cache entry segfaults wand persistently — open

`lib/compile_cache.ml:166` (Marshal read), `186-190` (store). The recovery
at 167-172 handles entries that make Marshal *raise* (truncation —
verified recovered). An entry with a valid 20-byte header and corrupt body
segfaults (verified, exit 139); SIGSEGV cannot be caught, so the cleanup
never runs and every later run of that script segfaults until the cache is
deleted by hand. `store` renames without fsync, so a power loss can
produce exactly this shape with no attacker. A malicious repo that gets
`WAND_CACHE_HOME` set (direnv `.envrc`, a Makefile) can ship a poisoned
entry deliberately — a checkout dir passes `dir_is_trustworthy`.

Fix: add an integrity trailer (digest of the marshaled bytes) checked
before unmarshal, and fsync before the rename.

### M3. `wand f` and `wand t --fix` destroy the file on a crash — open

`bin/wand.ml:765` and `lib/fix.ml:242-244` rewrite the source by
truncate-then-write into the original inode. A crash or ENOSPC mid-write
leaves a truncated source file, no backup. The correct pattern already
exists: `write_atomic` (`lib/runner.ml:789-835`) — same-directory temp,
fsync before rename, mode preserved. Route both writers through it,
copying the target's mode.

### M4. One malformed LSP frame kills the server — open

`lib/lsp.ml:34-65` and `864-867`. Three reproduced ways:

- `Content-Length: -1` → `Invalid_argument("Bytes.create")`, exit 2.
- `Content-Length: 999999999999999` → `Out of memory`, exit 2.
- An invalid JSON body → `read_message` returns None → serve loop reads
  "client went away" and exits; later valid requests are never answered.

Fix: reject non-positive lengths, cap the length, answer a bad body with
JSON-RPC parse error -32700 and continue.

### M5. `wand s` follows symlinks out of the tree — open

`lib/runner.ml:2644-2662` — `find_test_files` uses `Sys.is_directory`
(follows symlinks), no visited set. Verified: a symlinked directory made
`wand s` discover and run a `test_*.wand` outside the tree, with full
effects. Fix: skip symlinked directories (`Unix.lstat`) or track visited
real paths.

### M8. CI: unpinned cross-repo code executes; ci.yml has no permissions — open

- `.github/workflows/ci.yml:107-121` checks out `mjstahl/setup-wand` at
  default-branch HEAD and runs `wand s` on its suite — wand tests execute
  shell, so a push to that repo's default branch is code execution in
  wand's CI. Pin to a SHA.
- ci.yml has no `permissions:` block; token scope falls back to the repo
  default. release.yml and daily-fuzz.yml declare minimal blocks. Add
  `permissions: contents: read`.
- Trust model note: the release `.sha256` is produced by the same job that
  builds the archive and uploaded beside it (release.yml:168-175,
  Makefile:118-124), so it authenticates the download pipe, not the
  publisher. The Makefile's own comment records a clobber incident going
  undetected. Consider build-provenance attestation, or at least publish
  the sha256 list in the release notes as a second channel.

## Low

- **`%{x}` is one-word safe, not option safe.** `$?(grep %{pat} f)` with
  `pat = "--version"` runs grep's version banner (verified). The README's
  "cannot become a second command" is true; "safe for data" overclaims.
  Document the leading-dash caveat (`--` sentinels) or reject leading-dash
  data. `lib/evaluator.ml:1435`, README.
- **`Proc.exit` is not withheld under `--dry-run`.** `is_mutation`
  (`lib/runner.ml:705-708`) omits it; a rehearsal can end before reporting
  later would-writes. Report "would exit N" and continue, or document it.
- **Fuzzer eval child has no memory limit.** The 2-second SIGKILL bounds
  CPU; a pure program can exhaust host memory first. `setrlimit` in the
  child. `test/fuzz/oracle.ml:323-372`.
- **Regex compile bomb.** `Regex.compile "a{999999999}"` expands at
  compile time for minutes (verified, alarm-killed). Matching itself is a
  non-backtracking automaton — no input-driven blowup. Bound the
  quantifier. `lib/evaluator.ml:1722, 4737`.
- **VS Code extension.** The Rehearse command builds a shell string with
  `JSON.stringify` — a file named `x$(cmd).wand` injects when the lens is
  clicked in a trusted workspace. And `wand.path` lacks
  `"scope": "machine"`, so a workspace's settings can point the LSP launch
  at a script in the repo. Use argv-based execution; add machine scope.
  `editors/vscode/src/extension.ts`, `package.json`.
- **Workflow interpolation hygiene.** `${{ github.event.release.tag_name }}`
  and dispatch inputs are substituted into run blocks
  (`installs.yml:52-56`, `daily-fuzz.yml:84-87`; note `SEED=$((BASE + …))`
  is bash arithmetic, which evaluates `a[$(cmd)]` even quoted). All
  triggers need write access today. Pass via `env:` as release.yml does.
  Third-party actions are tag-pinned, not SHA-pinned; the Alpine image is
  digest-pinned with a rationale — apply the same to the actions.
- **Check-then-open races**, each narrow: cache trust check stats the dir
  then opens by path, no fstat of the fd (`lib/compile_cache.ml:160-166`);
  `delete_tree` recurses by concatenated path and a concurrent symlink
  swap redirects it (`lib/runner.ml:1193-1200`); `FS.temp_dir` has a
  remove-then-mkdir gap, fails closed (`lib/runner.ml:1179-1183`). All
  matter only in shared or hostile directories.
- **LSP applies edits without a gesture.** Auto-import and manifest edits
  are pushed on `didChange` (`lib/lsp.ml:744-768`). Undoable,
  buffer-local; worth a settings gate.
- **Daily-fuzz reporting fragility.** One failed `gh issue create` (e.g.
  invalid UTF-8 in a finding body) aborts the filing loop under `set -e`;
  later findings exist only in artifacts. A finding containing ``` also
  escapes the markdown fence (cosmetic). `daily-fuzz.yml:179-196`.

## Functionality bugs

- `FS.delete!` on a symlink to a directory fails "Not a directory" instead
  of unlinking the link — `Sys.is_directory` follows, `rmdir` gets the
  link. Use lstat, as `delete_tree` does. `lib/runner.ml:1292-1295`.
- `copy_tree` re-run fails on a dangling symlink at the destination —
  followed-link existence check answers false, `Unix.symlink` raises
  EEXIST. `lib/runner.ml:1237`.
- `copy_file` reads the whole source into memory. `lib/runner.ml:557-567`.
- `Env.clear` sets `""` instead of unsetting — observable to children.
  `lib/runner.ml:1286-1288`.
- install.sh's wget fallback for resolving "latest" is dead code —
  `wget -q` prints no `Location:` header, so a curl-less install fails
  (closed, with an error). Add `-S`. `install.sh:49-50`.
- Comment drift: `lib/compile_cache.ml:45-46` says format version "2"; the
  value is "4".

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
5. M1, M3, M4, M5 — cache integrity + fsync; `write_atomic` in fmt/fix;
   harden the LSP read loop; lstat in `wand s`.
6. M8 and the workflow hygiene items.

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

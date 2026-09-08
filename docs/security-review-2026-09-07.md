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

Two findings break the README's promises and block release: typechecking
executes imported code, and a newline bypasses the `Shell(...)` allowlist.

---

## Critical

### C1. Typechecking and the LSP execute imported modules — open

- `lib/runner.ml:1834-1839` — `load_module` evaluates a module's top-level
  items under `run_with_default_handler` (real effects).
- `lib/runner.ml:3131` — `typecheck_source` calls `load_imports_for`
  unconditionally, so `wand t` evaluates imports.
- `lib/lsp.ml:155-158` — the LSP calls `typecheck_source` on `didOpen` and
  `didChange`, so opening a hostile file in an editor executes code.
- `bin/wand.ml:277-364` — `wand d -x`, `wand d -t`, and `--load` also run
  code with live effects.

Repro:

```
-- evil.wand
uses {Shell(sh)}
let boom = $(sh -c "echo owned > PWNED")

-- victim.wand
let {boom} = import ./evil
let x = boom
```

`wand t victim.wand` exits 0 and creates `PWNED`. The same happens through
the live LSP on `didOpen`.

Two gaps compound it:

1. The attacker writes the malicious module's own manifest, so the static
   command-word check passes. The manifest is not a trust boundary against
   a hostile file.
2. An importer never has to declare its imports' top-level effects
   (`lib/runner.ml:1574-1583` — imports contribute names and types only).
   The importing file typechecks clean while its import writes to disk.

The fuzzer's purity gate is consulted *after* imports execute
(`test/fuzz/oracle.ml:333-336`): `typecheck_source` has already run the
imported modules by the time `reaches_outside ()` is read. Same class of
hole as the recorded `df` incident, through a different door.

Fix direction: analysis paths must load imports for types and signatures
without evaluating bodies. Defer top-level evaluation until the importer
actually runs, or gate module evaluation behind the same effect check.
Note the design comment at `runner.ml:1826-1833`: moving module eval under
the handler fixed an `Effect.Unhandled` crash, and cemented this. Decide
separately whether an import's top-level effects should join the
importer's manifest.

## High

### H1. Newline bypasses the `Shell(...)` allowlist — open

`lib/shell_scan.ml:156` — `scan_lit` treats an unquoted `'\n'` as
whitespace (`| ' ' | '\t' | '\n' -> finish_word (); incr i`). The shell
treats it as a command separator. The newline arm never sets
`expecting := true`, unlike `;` `|` `&` (lines 160-166), so a word after a
newline is never a command position — neither the typechecker nor
`guard_shell` (`lib/runner.ml:856-872`) checks it.

Repro: under `uses {Shell(echo), IO}`:

```
let c = "hi\ntouch NEWLINE_PWNED"
IO.println $(echo %!{c})
```

Runs `echo hi`, then `touch` — file created, exit 0. A literal newline in
the command gets only the V-SHELL2 warning and still runs unbounded; one
arriving through `%!{}` gets no warning at all. Newlines inside quotes are
data and must stay data.

Fix: make an unquoted `'\n'` behave like `;` in `scan_lit`.

### H2. JSON round-trip of a huge exponent is an uncatchable crash — open

`lib/evaluator.ml:4999-5019`. `JSON.parse "1e999999"` yields a Yojson
`` `Float infinity ``. `JSON.stringify` on it raises
`Yojson__Common.Json_error` outside the wrapping `try` at 5001 — fatal,
exit 2, and wand's `try` cannot catch it. Also reachable via
`JSON.of_float (1.0 /. 0.0)`. Any script that parses untrusted JSON and
re-emits part of it dies on one crafted number.

Related bug: `JSON.stringify_pretty` does not crash — it silently emits
`Infinity`, which is not JSON. The two serializers disagree.

Fix: wrap serialization so it returns a wand error; make both serializers
agree on non-finite floats.

### H3. NUL byte in a shell splice is an uncatchable crash — open

`lib/runner.ml:190-199` (`create_process_for`),
`lib/evaluator.ml:1435` (`shell_quote`). Strings are byte strings, and NUL
flows in from command output, file reads, and `Base64.decode!`. The
quoting is correct, but `Unix.create_process` rejects a NUL argv string
with EINVAL, and the `Unix.Unix_error` escapes as a fatal error. `try` and
`$?()` do not catch it.

Repro:

```
let v = $(printf 'A\000B')
$(echo pre %{v} post)          -- Fatal error, exit via crash; try does not help
```

Not an injection — the byte is rejected, not truncated. Fix: detect NUL
before spawn and raise a normal wand error.

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

### M2. Lock fd leaks into spawned children — open

`lib/runner.ml:616` — the `FS.lock` open lacks `O_CLOEXEC`; it is the one
descriptor in runner.ml without it (every pipe is `~cloexec:true`). A
script that starts a background process while holding the lock hands it a
copy; the flock belongs to the open file description, so the lock stays
held after wand exits, until the child dies. Verified: release ran, a
second wand still got `Error Held`. This defeats the documented cron-guard
use (`stdlib/FS.wand:224-227`).

Fix: add `Unix.O_CLOEXEC`; consider `O_NOFOLLOW` too (the open follows a
pre-planted symlink in a shared directory).

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

### M6. Size and Duration addition wraps silently — open

`lib/evaluator.ml:2036-2037` — raw OCaml `+` on byte/ms totals. Verified:
`4000000000GB + 4000000000GB` yields a negative Size, no error. Int
arithmetic is overflow-checked (`add_ovf` etc., evaluator.ml:530-554) and
Size/Duration subtraction floors at 0; addition is the gap, and it can
defeat a threshold check on untrusted totals. Fix: use the checked add.

### M7. IPv4 leading-zero octets read as decimal; libc reads octal — open

`lib/evaluator.ml:3952` — `IPv4.of_string "010.8.8.8"` parses as 10.8.8.8
(private). curl/libc/most resolvers read `010` as octal → 8.8.8.8
(public). A script that checks `IPv4.private?` and hands the original
string to a subprocess validates one host and connects to another — the
standard SSRF allowlist bypass. wand already rejects hex and bare-int
forms. Fix: reject octets with a leading zero (RFC 6943 guidance).

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

1. C1 — stop evaluating imports on analysis paths. The release blocker.
2. H1 — unquoted newline is a command separator in `shell_scan`. One arm
   of one match.
3. H2 + H3 — make the two uncatchable crashes catchable.
4. M2, M6, M7 — one-line to small local fixes (O_CLOEXEC, checked add,
   leading-zero rejection).
5. M1, M3, M4, M5 — cache integrity + fsync; `write_atomic` in fmt/fix;
   harden the LSP read loop; lstat in `wand s`.
6. M8 and the workflow hygiene items.

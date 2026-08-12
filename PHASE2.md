# Phase 2 — The wedge

**Status:** planned · **Goal:** a script can be read, bounded, and rehearsed before it is trusted.

```
$ wand --dry-run deploy.wand
would run:   rsync -a ./build/ web@host:/srv/app
would write: /etc/app/config.toml (312 bytes)
would delete: /var/cache/app/index

$ head -1 deploy.wand
uses {Shell, FS.Write}
```

Phase 1 made signatures state what a function does. This phase makes that statement enforceable at the file level and rehearsable at the command line. The runtime half already exists — every shell execution and mutating FS builtin performs an interceptable effect — so most of this is presentation and one real gap.

## The gap, measured

Which side-effecting builtins route through `perform`, and which reach the OS directly:

| | |
|---|---|
| Perform, interceptable | mutating FS ops (`fs_mkdir`, `fs_create`, `fs_remove`, `fs_rename`, `fs_copy`, `fs_append`, `fs_temp_file`), `fs_ls`, `read_file`, `write_file`, every `io_*`, every `process_*` |
| **Bypass — mutations** | **`env_set`, `env_clear`, `env_load_file`** |
| Bypass — reads | `fs_glob`, `fs_mtime`, `fs_size`, `fs_cwd` |

The mutations are the problem. A dry run that still changes the environment is worse than no dry run, because it invites trust it has not earned. The reads matter only for `--trace` completeness: under `--dry-run` reads execute anyway.

## Decisions

| Question | Decision |
|---|---|
| Where do the modes live? | **Runtime flags, implemented as internal handlers.** Never "paste this handler at the top of your script": a runtime-implemented rehearsal is a guarantee a reader can trust at a glance, a user-written one is only as good as its coverage. |
| What does `--dry-run` execute? | **Reads execute; writes, shell, and environment changes are reported.** Control flow then follows the real path, which is what makes the rehearsal informative. |
| What does it print? | What *would* happen, with the argument that decides it — the command, the path and size, the variable name. A reader is checking blast radius, not admiring a log. |
| Manifest syntax | `uses {Shell, FS.Write}` at the top of a file, checked against the whole-file inferred row. Same braces as a signature, because it is the same thing. |
| Manifest enforcement | Inferred ⊄ declared is a **type error**. A file without a manifest is unconstrained, so casual scripts pay nothing. |
| Honesty caveat | Documented, not hidden: reads see pre-mutation state, so a dry run can diverge from the real one. It cannot drift like a hand-rolled `$DRY` flag, but it cannot rehearse reads-of-writes. |

## Working rules

1. Each tranche lands green.
2. **The audit comes first and is a precondition.** Nothing downstream is trustworthy until every mutation is interceptable.
3. Every mode is demonstrated on a real script in `demos/`, not just asserted in a test.

---

## P2.1 — Close the perform gap

`env_set`, `env_clear` and `env_load_file` must perform interceptable effects, like every other mutation. The read-only builtins that bypass (`fs_glob`, `fs_mtime`, `fs_size`, `fs_cwd`) should too, so `--trace` can report them.

A test asserts the property directly rather than listing names: every builtin whose type carries `FS.Write`, `Env`, `Shell` or `Proc` must be interceptable by a handler. That way a new effectful builtin cannot be added without one.

*Accept:* a handler can intercept every mutating operation; the property test passes.

## P2.2 — `--dry-run` and `--trace`

Two internal handlers wrapping the whole program.

- `--trace`: everything executes, every effect logged with its arguments.
- `--dry-run`: reads execute; `Shell`, `FS.Write` and `Env` mutations are reported as `would …` and skipped, returning a plausible value so control flow continues.

The skipped-value question is the subtle one: `$()` under dry-run must return *something*, and whatever it returns steers the rest of the script. Report the substitution rather than pretending.

*Accept:* `demos/` gains a deploy script that rehearses; the trace of a real run matches the rehearsal's list.

## P2.3 — Manifests

`uses {Shell, FS.Write}` as a top-of-file declaration, parsed into the AST, checked against the file's inferred row after inference. Exceeding it names the offending call site.

*Accept:* a script whose manifest omits an effect it performs fails to typecheck, naming the line; a script with no manifest is unaffected.

## P2.4 — The hermetic test story

`handle`-based mocking already works. This is positioning plus one convenience: `Test.with_shell [(pattern, output), …]` so a test does not hand-write a handler for the common case, and a documented worked example of testing a deploy without a network.

*Accept:* a demo test suite exercises a script that would otherwise push to production.

## P2.5 — Formatter catch-up

`handle`, `try`, contracts, `$()`/`$?()` and regex literals currently fall back to verbatim source slices. They are the newest constructs and the ones an AI session is most likely to emit, so they are where formatting drift will start.

*Accept:* each has a formatting rule; the verbatim fallback is reserved for genuinely unknown shapes.

## P2.6 — Demos D4–D6

- **D4** — the signature that cannot lie: bury a shell call three helpers deep, watch the signature change; then add a manifest and watch it become a compile error.
- **D5** — rehearse the deploy: `--dry-run` on a real script, then the real run matching.
- **D6** — unit-test a deploy with the network unplugged.

The roadmap gates the release on these: if a demo's moment does not land, the feature is not finished.

---

## Risks

- **A dry run that lies is worse than none.** Hence P2.1 first, and a property test rather than a list.
- **Substituted values steer control flow.** A dry run that takes a different branch than the real run is misleading in a way a log cannot fix; the output has to make substitutions visible.
- **Manifests must not become noise.** They are opt-in, and the error must name the call site, not just the file.

## Exit criteria

1. Every mutating builtin is interceptable, enforced by a test that cannot be satisfied by a list.
2. `--dry-run` and `--trace` work on a real script in `demos/`.
3. A manifest that understates the script is a type error naming the call site.
4. The formatter has rules for the constructs it currently copies verbatim.
5. D4–D6 land as runnable demos.

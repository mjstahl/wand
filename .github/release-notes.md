## 0.66.1 - 2026-09-08

A rebuild. The linux-x86_64 binary would not start on some machines, and
this is the release that starts.

### What happened

```
$ wand -e '1 + 1'
Fatal error: Failed to allocate signal stack for domain 0
Aborted (core dumped)
```

Through `install.sh` it read `the downloaded binary did not run`, with no
more detail, because the script ran the binary with `2>/dev/null` and threw
the message away.

It looked like a flake. It was not one. The binary failed **every** start on
about one machine in eight and no start on any other, so re-running always
appeared to fix it, and always only moved to a different machine.

### Why

The machines are the ones whose CPU has AMX -- Intel's matrix extensions,
on Xeons from Sapphire Rapids on. AMX adds 8 KB of register state, and the
kernel saves register state onto the signal stack, so the minimum signal
stack a signal frame needs grows with the CPU. The kernel reports it:

| CPU | minimum |
|---|---|
| no AMX | 1776 |
| AVX-512 | 3376 |
| **AMX** | **11952** |

An OCaml runtime before 5.5.1 sizes that stack from the build-time
`SIGSTKSZ`, and musl fixes `SIGSTKSZ` at 8192 whatever the CPU says. musl
1.2.6 compares the request against the kernel's number and answers
`ENOMEM`, and the runtime aborts.

musl is right to refuse. 8192 really is too small there. musl 1.2.5 and
glibc both accept it in silence, which is worse rather than better: it
trades an abort at startup for a signal frame written past the end of the
stack. So the answer was not an older Alpine.

### The fix

OCaml 5.5.1 reads `sysconf(_SC_SIGSTKSZ)` instead of the constant. On one
of those machines it asks for 19120 rather than 8192, and starts.

No opam image carries 5.5.1 yet -- `alpine-ocaml-5.5` is still 5.5.0, which
does not have it -- so the release build creates the switch itself, from a
pinned opam-repository commit. That comes out once a base image ships
5.5.1.

The binary is still statically linked, so nothing about how it is installed
or copied changes.

### What else

Only linux-x86_64 was affected. linux-aarch64 and both macOS builds ask for
the same 8192 and are not refused, because there is no comparable register
state to save.

`install.sh` now keeps the failing binary's stderr and prints it above the
failure, so the next thing that cannot start says why.

No language changes. Every wand program behaves as it did in 0.66.0.

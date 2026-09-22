# Building and testing

This document describes how to build the library, regenerate committed
artifacts and run tests, in a way that works the same on a developer machine
and in CI. No step here requires `sudo`; if you find yourself reaching for
it, stop and read on.

## Pinned versions

Versions are pinned in exactly one place each. Scripts fail early with a
readable message when the environment drifts.

| What | Pinned in | Current |
| --- | --- | --- |
| Go (minimum) | `go.mod` (`go` directive) | 1.25 |
| clang / llvm for ELFs | `Makefile` (`CLANG`, `STRIP`, `OBJCOPY`) | clang-22 (also 14, 17) |
| bpftool, clang-format | builder image `testdata/docker/{IMAGE,VERSION}` | see files |
| Oldest clang for bpf2go tests | `scripts/versions.env` (`CI_MIN_CLANG_VERSION`) | 14 |
| Newest kernel / efw for tests | `scripts/versions.env` | see file |
| Go modules | `go.mod` / `go.sum` (enforced by `-mod=readonly`) | — |

Run `make check-toolchain` to verify a local setup against these pins. It is
also the first step of `make all`, so a mismatched toolchain fails before
producing any output.

## Generated artifacts are committed

Testdata ELFs, bpf2go output, stringer tables and generated syscall types
are **checked into the repository**. There is exactly one way to regenerate
them:

```
make container-all
```

This runs the full pipeline (clang-format, ELF builds, `go generate`,
external dep updates) inside the pinned builder image, so the output does
not depend on the host's clang, headers or bpf2go version. Do not regenerate
with a host toolchain and commit the result, and never edit generated files
by hand.

CI enforces the policy with:

```
make container-check-generated
```

which regenerates everything and fails if the working tree changes. If it
fails, run `make container-all` locally and commit the diff.

## Tests: unprivileged vs. privileged

The test suite has two tiers:

- **Hermetic tests** don't issue `bpf()` syscalls and don't read kernel
  state (assembly, ELF/BTF parsing of committed testdata, bpf2go
  compilation, pure internal packages). They pass as an unprivileged user
  in a clean container. The package list lives in the Makefile as
  `UNPRIVILEGED_TEST_PACKAGES`.
- **Privileged tests** create maps, load programs or attach to hooks. They
  need `CAP_BPF`/`CAP_SYS_ADMIN`, a mounted bpffs and tracefs, and in some
  cases a real cgroup or network interface. They are expected to *fail* as
  an unprivileged user — that is not a regression. Upstream runs them in
  VMs on pinned kernels (`CI_MAX_KERNEL_VERSION`).

Don't `sudo go test` to make the second tier pass on a laptop: setuid
binaries, hardcoded `/sys/fs/bpf` paths and root-owned bpffs mounts are
exactly the failure modes this setup exists to avoid. If a privileged test
needs to run locally, use a VM (e.g. `vimto`, see `.vimto.toml`).

## Minimal clean-container job

The smallest useful CI job — build the library and run the hermetic tests
with no host toolchain and no privileges:

```
make container-test-unprivileged
```

It runs in the pinned builder image as uid 65534, with the repository
mounted read-only and empty Go caches. If this is green, the library
compiles and its unprivileged tests pass, reproducibly, on any machine with
a container runtime.

To run the same tests against the host toolchain instead (Linux hosts only,
the library doesn't build on other desktop OSes):

```
make test-unprivileged
```

## Updating pinned versions

- **Builder image** (clang, bpftool, Go for containers): see
  `testdata/docker/README.md`. Bumping it updates `testdata/docker/VERSION`;
  expect ELF diffs from a new clang.
- **Kernel / efw / min clang**: edit `scripts/versions.env`, then run
  `make container-all` and commit the result.
- **Go**: bump the `go` directive in `go.mod` and the `FROM` line in
  `testdata/docker/Dockerfile` together.

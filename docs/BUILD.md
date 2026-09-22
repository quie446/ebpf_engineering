# Build, generation and test policy

This document is the single source of truth for how this repo is built, how
bpf2go artifacts are handled, and which tests run where. Read it before
adding scripts or CI jobs.

## 1. Pinned toolchain

| Tool | Pin | Where |
| --- | --- | --- |
| Go | `go 1.25` directive | `go.mod`; CI image `golang:1.25-bookworm` |
| bpf2go, stringer, gentypes | Go module version | `tool` block in `go.mod`, invoked as `go tool bpf2go` |
| clang / llvm-strip | major 22 | `tools.versions`; shipped by the builder image |
| bpftool | major >= 7 | `tools.versions`; shipped by the builder image |
| Full C toolchain image | `ghcr.io/cilium/ebpf-builder:1777990914` | `testdata/docker/IMAGE` + `VERSION` |

Never `go install` a floating bpf2go for generating code in this repo, and
never hard-code absolute paths like `/Users/.../clang` into scripts. All
overrides go through `make` variables (`CLANG=...`) or the container targets.

`scripts/check-tools.sh go` (run automatically by every test/generate
target) verifies the Go version and that `go tool bpf2go` resolves.
`scripts/check-tools.sh elf` additionally verifies clang-22 /
llvm-strip-22 / bpftool. On mismatch it exits non-zero with the exact fix
(which image to use, which package to install) instead of letting the build
fail later with a cryptic compiler error.

## 2. Generated artifacts: committed, CI verifies

The strategy is **generate once with the pinned image, commit the output**:

- `*_bpfel.go` / `*_bpfeb.go` and their embedded `*_bpfel.o` / `*_bpfeb.o`
  (examples, `docs/examples`, `cmd/bpf2go/test`),
- `testdata/**.elf` and `btf/testdata/**.elf`,
- `*_string.go` and `elf_sections.go`.

Reasons: a clean clone builds and runs with only Go installed; review diffs
show generated-code changes; there is a single artifact set instead of two
copies racing each other.

CI never overwrites the committed copy. The `generated-artifacts` job
regenerates everything inside the pinned builder image and runs
`git diff --exit-code`: a diff means the artifacts were produced with a
drifted toolchain and the job is red.

Regenerate only when C sources or generators change:

```shell
make container-generate-check   # verify the tree is up to date (read-only)
make container-generate         # regenerate in the pinned image, then commit
```

`make all` / `make generate` on a bare host still work, but require the
exact clang-22 toolchain and are guarded by `check-tools.sh elf`.

## 3. Test tiers and privileges

Tests are split by what kernel resources they need. There is no "run with
sudo and hope" tier; privileges are a property of the environment, not of
the developer's machine.

| Tier | Command | Environment | What runs |
| --- | --- | --- | --- |
| unprivileged unit | `make unit-test` | Linux, any user, no caps | `UNIT_TEST_PACKAGES` in the Makefile: pure logic (`asm`, encoding, `btf` parsing helpers, `internal/...` syscall-free packages, `bpf2go` frontend) |
| unprivileged, clean container | `make container-unit-test` | throwaway `golang:1.25-bookworm`, `--cap-drop=ALL`, source mounted read-only | same as above |
| privileged integration | `go test ./...` | root or `CAP_BPF`+`CAP_PERFMON`+`CAP_NET_ADMIN`, bpffs mounted, recent kernel | loader, map/prog syscall tests, `perf`, `ringbuf`, `pin`, `link`, `netns`, cgroup attach tests |
| kernel-dependent | same as above, CI kernel image | `bpf_testmod` loaded, BTF in `/sys/kernel/btf/vmlinux` | CO-RE, kfunc, struct_ops, ksym tests |

Why the package allowlist instead of running everything in the unprivileged
container and treating failures as "skips": the bpf(2) syscall returns
`EPERM` which the test suite cannot distinguish from a genuine bug, so
those tests **fail**, they do not skip. The allowlist contains exactly the
packages whose tests never issue bpf(2) syscalls, mount bpffs, or create
netns/cgroups. It was verified by running the full suite under
`--cap-drop=ALL` and keeping only green packages. When adding a new package
there, prove it stays green in `make container-unit-test` first.

Inside the privileged tier, individual tests skip themselves with a reason
when the kernel is too old (`testutils.SkipOnOldKernel`), a feature probe
fails (`SkipIfNotSupported`), or `bpf_testmod` is absent. Skips print the
reason in test output. `-short` skips tests that shell out to clang
(`testutils.ClangBin`), so no C toolchain is needed for tier 1-2.

Tier 1-2 targets are Linux-oriented; on macOS the full `go build ./...`
works, but a couple of tests assume Linux errno values. Use the container
target on macOS (it runs Linux regardless of host OS).

## 4. Reproducing CI from a clean clone

Requirements: a container engine (`docker` or `podman`). Nothing else.

```shell
# Green on any machine, no clang, no privileges:
make container-unit-test

# Verifies committed artifacts (pulls ~builder image, needs network):
make container-generate-check

# Full privileged suite, on a Linux dev box or CI runner with caps:
go test ./...
```

The same two targets back the GitHub Actions jobs in
`.github/workflows/ci.yml`.

## 5. Adding new bpf2go-generated code

1. Add `//go:generate go tool bpf2go ...` (never a bare `bpf2go` binary).
2. Run `make container-generate`, commit both the `.go` files and the
   embedded `.o` files in the same change.
3. The `generated-artifacts` CI job confirms they match the pinned image.

Do not gitignore generated files to "generate in CI instead": that would
create the two-sources-of-truth setup this policy exists to prevent.

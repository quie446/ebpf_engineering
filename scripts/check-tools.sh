#!/usr/bin/env bash
#
# check-tools.sh - fail early, with a human-readable message, when the local
# or CI toolchain drifts from the versions pinned in tools.versions.
#
# Usage:
#   scripts/check-tools.sh go        # check Go toolchain only (build / short tests)
#   scripts/check-tools.sh elf       # additionally check clang/llvm-strip/bpftool
#                                     # (regenerating committed artifacts)

set -euo pipefail

mode="${1:-go}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
versions_file="$repo_root/tools.versions"
if [[ ! -f "$versions_file" ]]; then
	echo "error: $versions_file not found; run this script from a checkout of the repo" >&2
	exit 2
fi
# shellcheck source=/dev/null
source "$versions_file"

fatal() {
	echo "error: $*" >&2
	exit 1
}

need() {
	command -v "$1" >/dev/null 2>&1 || fatal "'$1' not found in PATH. $2"
}

# --- Go ---------------------------------------------------------------------

need go "install Go $(grep -m1 '^go ' "$repo_root/go.mod" | awk '{print $2}') or newer, then retry."

go_mod_version="$(awk '/^go [0-9]/ {print $2; exit}' "$repo_root/go.mod")"
go_mod_majmin="${go_mod_version%.*}"
go_installed="$(go env GOVERSION 2>/dev/null | sed 's/^go//')"
go_installed_majmin="${go_installed%.*}"
if [[ "$go_installed_majmin" != "$go_mod_majmin" ]] && \
   ! printf '%s\n%s\n' "$go_mod_majmin" "$go_installed_majmin" | sort -VC 2>/dev/null; then
	cat >&2 <<-EOF
	error: Go toolchain drift.
	  go.mod requires >= $go_mod_majmin, this shell has go$go_installed ($(command -v go)).
	  In CI use the $GO_DOCKER_IMAGE image (see .github/workflows/ci.yml).
	  Locally, install Go $go_mod_majmin or let GOTOOLCHAIN fetch it (unset GOTOOLCHAIN=local).
	EOF
	exit 1
fi

# go build / go test must not silently edit go.mod.
if [[ "${GOFLAGS:-}" != *"-mod=mod"* ]]; then
	export GOFLAGS="${GOFLAGS:+$GOFLAGS }-mod=readonly"
fi

# The tool directives pin bpf2go/stringer/etc. Verify they resolve, so a
# missing go.sum entry fails here instead of deep inside `go generate`.
# Populate the module cache first (on a clean clone GOMODCACHE is empty).
go mod download
if ! go tool bpf2go --help >/dev/null 2>&1; then
	fatal "pinned 'go tool bpf2go' does not resolve; run 'go mod download' / check go.sum. Do not use a globally installed bpf2go."
fi

if [[ "$mode" == "go" ]]; then
	echo "ok: go$go_installed, Go tools pinned via go.mod tool directives"
	exit 0
fi

[[ "$mode" == "elf" ]] || fatal "unknown mode '$mode' (expected 'go' or 'elf')"

# --- C toolchain (only needed for artifact regeneration) --------------------

clang_bin="${CLANG:-clang-$CLANG_MAJOR_VERSION}"
if ! command -v "$clang_bin" >/dev/null 2>&1; then
	if command -v "clang-$CLANG_MAJOR_VERSION" >/dev/null 2>&1; then
		clang_bin="clang-$CLANG_MAJOR_VERSION"
	else
		cat >&2 <<-EOF
		error: clang-$CLANG_MAJOR_VERSION not found (needed to regenerate committed *.o/*.elf artifacts).
		  - CI/clean environment: run 'make container-generate' using
		    $ELF_BUILDER_IMAGE
		  - Debian/Ubuntu: install the clang-$CLANG_MAJOR_VERSION / llvm-$CLANG_MAJOR_VERSION packages
		    (see testdata/docker/Dockerfile for the apt.llvm.org setup)
		  - Short tests and builds do NOT need clang: run 'make unit-test' instead.
	EOF
		exit 1
	fi
fi

clang_version="$("$clang_bin" --version | sed -n 's/.*version \([0-9]*\).*/\1/p' | head -1)"
[[ -n "$clang_version" ]] || fatal "could not parse '$clang_bin --version' output"
if [[ "$clang_version" != "$CLANG_MAJOR_VERSION" ]]; then
	cat >&2 <<-EOF
	error: clang drift. tools.versions pins clang $CLANG_MAJOR_VERSION, found clang $clang_version ($clang_bin).
	  Different clang versions produce different (but committed) object files, which is exactly
	  the 'works on my machine' failure this check guards against.
	  Override only explicitly: CLANG=clang-$CLANG_MAJOR_VERSION, or use 'make container-generate'.
	EOF
	exit 1
fi

strip_bin="${STRIP:-llvm-strip-$LLVM_STRIP_MAJOR_VERSION}"
need "$strip_bin" "install llvm-$LLVM_STRIP_MAJOR_VERSION (llvm-strip), or regenerate via 'make container-generate'."

if ! command -v bpftool >/dev/null 2>&1; then
	cat >&2 <<-EOF
	error: bpftool not found. It is only required to link testdata/linked*.elf.
	  Install the 'bpftool' (or linux-tools) package, or run 'make container-generate'.
	  If you only regenerate other artifacts, set BPFTOOL=true to skip this check knowingly.
	EOF
	[[ "${BPFTOOL:-}" == "true" ]] && exit 0 || exit 1
fi
bpftool_major="$(bpftool version 2>/dev/null | sed -n 's/.*v\([0-9][0-9]*\)\..*/\1/p' | head -1)"
if [[ -n "$bpftool_major" && "$bpftool_major" -lt "$BPFTOOL_MIN_MAJOR_VERSION" ]]; then
	fatal "bpftool v$bpftool_major is older than the pinned v$BPFTOOL_MIN_MAJOR_VERSION; install a newer linux-tools package or use 'make container-generate'."
fi

echo "ok: go$go_installed, $clang_bin $clang_version, $strip_bin, bpftool ${bpftool_major:-?}"

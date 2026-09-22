#!/bin/bash

# Fail fast if the local toolchain doesn't match what this repository pins.
#
# Invoked by `make check-toolchain` (and indirectly by `make all`). Override
# the binaries to check via the CLANG, STRIP and OBJCOPY environment
# variables, e.g. CLANG=clang-17 ./scripts/check-toolchain.sh.

set -euo pipefail

repodir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Pinned versions live in scripts/versions.env (make-compatible syntax).
# shellcheck source=versions.env
source "$repodir/scripts/versions.env"

CLANG=${CLANG:-clang-22}
STRIP=${STRIP:-llvm-strip-22}
OBJCOPY=${OBJCOPY:-llvm-objcopy-22}

failures=0

fail() {
	echo "error: $*" >&2
	failures=$((failures + 1))
}

hint() {
	echo "  -> $*" >&2
}

# clang_major <binary> prints the clang major version or nothing.
clang_major() {
	"$1" --version 2>/dev/null | sed -n 's/.*clang version \([0-9][0-9]*\).*/\1/p' | head -n1
}

echo "Checking toolchain against pinned versions (scripts/versions.env, go.mod, Makefile)"

# --- Go ---------------------------------------------------------------------

want_go=$(awk '$1 == "go" { print $2 }' "$repodir/go.mod")
if ! command -v go >/dev/null; then
	fail "go not found in PATH"
	hint "install Go >= $want_go: https://go.dev/dl/"
else
	got_go=$(go env GOVERSION)
	got_go=${got_go#go}
	if [ "$(printf '%s\n%s\n' "$want_go" "$got_go" | sort -V | head -n1)" != "$want_go" ]; then
		fail "go $got_go is older than the $want_go required by go.mod"
		hint "upgrade Go: https://go.dev/dl/"
	else
		echo "ok: go $got_go (go.mod requires >= $want_go)"
	fi
fi

# --- clang / LLVM -----------------------------------------------------------

if ! command -v "$CLANG" >/dev/null; then
	fail "$CLANG not found in PATH"
	hint "install LLVM from https://apt.llvm.org/ or use 'make container-all'"
else
	clang_ver=$(clang_major "$CLANG")
	case "$CLANG" in
	*-[0-9]*)
		want_clang=${CLANG##*-}
		if [ "$clang_ver" != "$want_clang" ]; then
			fail "$CLANG reports major version $clang_ver, expected $want_clang"
			hint "a clang binary that lies about its version will silently drift generated ELFs"
		fi
		;;
	*)
		echo "warning: CLANG=$CLANG is a floating binary (reports major $clang_ver);" >&2
		echo "warning: generated ELFs differ between clang releases. Pin CLANG=clang-<major>" >&2
		echo "warning: or use 'make container-all' for reproducible output." >&2
		;;
	esac
	echo "ok: $CLANG (major $clang_ver)"
fi

for tool in "$STRIP" "$OBJCOPY"; do
	if ! command -v "$tool" >/dev/null; then
		fail "$tool not found in PATH"
		hint "install the llvm package matching $CLANG or use 'make container-all'"
	else
		echo "ok: $tool"
	fi
done

if ! command -v clang-format >/dev/null; then
	fail "clang-format not found in PATH (needed by 'make format')"
	hint "install clang-format or use 'make container-all'"
else
	echo "ok: clang-format"
fi

# --- bpftool ----------------------------------------------------------------

if ! command -v bpftool >/dev/null; then
	fail "bpftool not found in PATH (needed to link testdata/linked-*.elf)"
	hint "install bpftool or use 'make container-all'"
else
	echo "ok: bpftool ($(bpftool version 2>/dev/null | head -n1))"
fi

# --- go modules -------------------------------------------------------------

if command -v go >/dev/null && ! (cd "$repodir" && go mod verify) >/dev/null; then
	fail "go mod verify failed: module cache doesn't match go.sum"
	hint "run 'go mod download' and investigate any 'mismatch' lines"
fi

if [ "$failures" -gt 0 ]; then
	echo >&2
	echo "$failures toolchain problem(s) found. The pinned builder image has them all:" >&2
	echo "  make container-all    # regenerate everything inside the container" >&2
	exit 1
fi

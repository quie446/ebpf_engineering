#!/bin/bash

set -euo pipefail

# Pinned versions live in scripts/versions.env.
# shellcheck source=versions.env
source "$(dirname "${BASH_SOURCE[0]}")/versions.env"

efw_version="$CI_MAX_EFW_VERSION"

echo "Using EFW version: $efw_version"

tmp=$(mktemp -d)

cleanup() {
	rm -r "$tmp"
}

trap cleanup EXIT

# Download and process ebpf_structs.h
curl -fL "https://github.com/microsoft/ebpf-for-windows/raw/refs/tags/Release-v${efw_version}/include/ebpf_structs.h" -o "$tmp/ebpf_structs.h"
"./internal/cmd/genwinfunctions.awk" "$tmp/ebpf_structs.h" | gofmt > "./asm/func_win.go"

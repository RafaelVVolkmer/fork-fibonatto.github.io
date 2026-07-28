#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Sergio Bonatto
# SPDX-License-Identifier: MIT

set -Eeuo pipefail

project_root="$(
	cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." > /dev/null 2>&1
	pwd
)"
readonly project_root
readonly manifest="${VERSION_MANIFEST:-$project_root/toolchain-versions.yml}"
readonly key="${1:-}"

[[ "$#" -eq 1 ]] || {
	echo "Usage: scripts/read-version.sh <tool>" >&2
	exit 2
}

case "$key" in
	brotli | cosign | emscripten | syft | terser)
		;;
	*)
		echo "Unknown version key: $key" >&2
		exit 2
		;;
esac

[[ -f "$manifest" ]] || {
	echo "Version manifest not found: $manifest" >&2
	exit 1
}

value="$(
	sed -n \
		"s/^  ${key}: \"\\([0-9][0-9A-Za-z.+-]*\\)\"\$/\\1/p" \
		"$manifest"
)"

[[ -n "$value" && "$value" != *$'\n'* ]] || {
	echo "Expected exactly one version for $key in $manifest" >&2
	exit 1
}

printf '%s\n' "$value"

# EOF

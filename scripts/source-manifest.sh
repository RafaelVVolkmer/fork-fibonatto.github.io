#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Sergio Bonatto
# SPDX-License-Identifier: MIT

# ==============================================================================
# source-manifest.sh — generate and verify the project-owned C/H inventory
# ==============================================================================

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
action="${1:-}"
manifest="${2:-$project_root/core/sources.sha256}"
temporary_manifest=""

if [[ "$manifest" != /* ]]; then
	manifest="$project_root/$manifest"
fi

cleanup() {
	if [[ -n "$temporary_manifest" ]]; then
		rm -f -- "$temporary_manifest"
	fi
}
trap cleanup EXIT

render_manifest() {
	(
		cd "$project_root"
		find core tools/packer -type f \
			\( -name '*.c' -o -name '*.h' \) -print \
			| LC_ALL=C sort \
			| while IFS= read -r path; do
				shasum -a 256 "$path"
			done
	)
}

generate_manifest() {
	local manifest_dir

	manifest_dir="$(dirname "$manifest")"
	[[ -d "$manifest_dir" ]] || {
		echo "Manifest directory does not exist: $manifest_dir" >&2
		exit 1
	}
	temporary_manifest="$(mktemp "$manifest.tmp.XXXXXX")"
	render_manifest > "$temporary_manifest"
	chmod 0644 "$temporary_manifest"
	mv "$temporary_manifest" "$manifest"
	temporary_manifest=""
	echo "Source manifest updated: ${manifest#"$project_root/"}"
}

check_manifest() {
	local display_path="${manifest#"$project_root/"}"

	[[ -f "$manifest" ]] || {
		echo "Missing source manifest: $display_path" >&2
		exit 1
	}
	temporary_manifest="$(mktemp "${TMPDIR:-/tmp}/sources.sha256.XXXXXX")"
	render_manifest > "$temporary_manifest"
	if ! cmp -s "$manifest" "$temporary_manifest"; then
		echo "Source manifest is stale: $display_path" >&2
		echo "Run 'make update-sources' and commit the result." >&2
		diff -u \
			--label "$display_path (committed)" \
			--label "$display_path (generated)" \
			"$manifest" "$temporary_manifest" || true
		exit 1
	fi
	echo "Source manifest verified: $display_path"
}

case "$action" in
	generate)
		generate_manifest
		;;
	check)
		check_manifest
		;;
	*)
		echo "Usage: $0 {generate|check} [manifest]" >&2
		exit 2
		;;
esac

# EOF

#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Sergio Bonatto
# SPDX-License-Identifier: MIT

# ==============================================================================
# source-manifest.sh — generate and verify the project-owned C/H inventory
# ==============================================================================

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
action="${1:-}"
manifest="${2:-$project_root/dist/.metadata/sources.sha256}"
temporary_manifest=""
temporary_directory=""

if [[ "$manifest" != /* ]]; then
	manifest="$project_root/$manifest"
fi

cleanup() {
	if [[ -n "$temporary_manifest" ]]; then
		rm -f -- "$temporary_manifest"
	fi
	if [[ -n "$temporary_directory" ]]; then
		rm -rf -- "$temporary_directory"
	fi
}
trap cleanup EXIT

render_paths() {
	(
		cd "$project_root"
		find core tools/packer -type f \
			\( -name '*.c' -o -name '*.h' \) -print \
			| LC_ALL=C sort
	)
}

render_tracked_paths() {
	(
		cd "$project_root"
		git ls-files -- core tools/packer \
			| LC_ALL=C sort \
			| while IFS= read -r path; do
				case "$path" in
					*.c | *.h)
						printf '%s\n' "$path"
						;;
				esac
			done
	)
}

render_manifest() {
	(
		cd "$project_root"
		while IFS= read -r path; do
			shasum -a 256 "$path"
		done < <(render_paths)
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
		echo "Regenerate it from the current source worktree." >&2
		diff -u \
			--label "$display_path (existing)" \
			--label "$display_path (generated)" \
			"$manifest" "$temporary_manifest" || true
		exit 1
	fi
	echo "Source manifest verified: $display_path"
}

audit_inventory() {
	local actual_paths tracked_paths

	command -v git > /dev/null 2>&1 || {
		echo "Git is required to audit the source inventory." >&2
		exit 1
	}
	git -C "$project_root" rev-parse --is-inside-work-tree \
		> /dev/null 2>&1 || {
		echo "Source inventory audit requires a Git worktree." >&2
		exit 1
	}
	temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/sources-audit.XXXXXX")"
	actual_paths="$temporary_directory/actual"
	tracked_paths="$temporary_directory/tracked"
	render_paths > "$actual_paths"
	render_tracked_paths > "$tracked_paths"
	if ! cmp -s "$tracked_paths" "$actual_paths"; then
		echo "Project-owned C/H files must be tracked exactly by Git." >&2
		diff -u "$tracked_paths" "$actual_paths" || true
		exit 1
	fi
	render_manifest > /dev/null
	echo "Source inventory verified against tracked Git paths."
}

case "$action" in
	generate)
		generate_manifest
		;;
	check)
		check_manifest
		;;
	audit)
		audit_inventory
		;;
	*)
		echo "Usage: $0 {generate|check|audit} [manifest]" >&2
		exit 2
		;;
esac

# EOF

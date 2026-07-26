#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Sergio Bonatto
# SPDX-License-Identifier: MIT

# ==============================================================================
# maintenance.sh — scoped cleanup operations for generated project state
#
# - Removes build and distribution artifacts without touching persistent caches.
# - Removes tool caches, Make logs, or emsdk-managed downloads independently.
# - Validates every destructive path against the absolute repository root.
# - Selects one cleanup scope through the build, cache, logs, or sdk argument.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Repository root and requested cleanup scope
# ------------------------------------------------------------------------------
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
action="${1:-}"

# ------------------------------------------------------------------------------
# Build and distribution cleanup
# ------------------------------------------------------------------------------
clean_build() {
	local build_dir="$project_root/.build"
	local dist_dir="$project_root/dist"

	[[ "$build_dir" == "$project_root/.build" ]]
	[[ "$dist_dir" == "$project_root/dist" ]]
	rm -rf "$build_dir" "$dist_dir"
	rm -f \
		"$project_root/compile_commands.json" \
		"$project_root/tags" \
		"$project_root/.tags" \
		"$project_root/.vscode-ctags"
	find "$project_root" -maxdepth 1 -type f -name '*.plist' -delete
	echo "Build artifacts removed."
}

# ------------------------------------------------------------------------------
# Persistent tool cache cleanup
# ------------------------------------------------------------------------------
clean_cache() {
	local cache_dir="$project_root/.cache"

	[[ "$cache_dir" == "$project_root/.cache" ]]
	rm -rf "$cache_dir"
	echo "Persistent project caches removed."
}

# ------------------------------------------------------------------------------
# Make and test log cleanup
# ------------------------------------------------------------------------------
clean_logs() {
	local logs_dir="$project_root/logs"

	[[ "$logs_dir" == "$project_root/logs" ]]
	rm -rf "$logs_dir"
	echo "Make invocation logs removed."
}

# ------------------------------------------------------------------------------
# Emscripten SDK-managed state cleanup
# ------------------------------------------------------------------------------
clean_sdk() {
	local emsdk_dir="$project_root/tools/emsdk"

	[[ -d "$emsdk_dir" ]] || return 0
	git -C "$emsdk_dir" clean -fdX
	echo "emsdk-managed downloads and toolchains removed."
}

# ------------------------------------------------------------------------------
# Cleanup scope dispatch
# ------------------------------------------------------------------------------
case "$action" in
	build)
		clean_build
		;;
	cache)
		clean_cache
		;;
	logs)
		clean_logs
		;;
	sdk)
		clean_sdk
		;;
	*)
		echo "Usage: $0 {build|cache|logs|sdk}" >&2
		exit 2
		;;
esac

# EOF

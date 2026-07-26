#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Sergio Bonatto
# SPDX-License-Identifier: MIT

# ==============================================================================
# toolchain.sh — repository-local compiler and optimization tool manager
#
# - Initializes the pinned Emscripten and Brotli submodules when required.
# - Builds and caches the pinned Brotli command-line tool.
# - Installs the exact Terser dependency graph from package-lock.json.
# - Executes emcc, wasm-opt, Brotli, or Terser through one argument-driven API.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Repository root and requested component action
# ------------------------------------------------------------------------------
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
action="${1:-}"
component="${2:-}"

# ------------------------------------------------------------------------------
# Safe third-party submodule initialization
# ------------------------------------------------------------------------------
ensure_submodule() {
	local submodule="${1:?submodule path was not provided}"
	local marker="${2:?submodule marker was not provided}"

	case "$submodule" in
		tools/*)
			;;
		*)
			echo "Refusing to initialize a submodule outside tools/: $submodule" >&2
			exit 1
			;;
	esac

	if [[ ! -e "$project_root/$submodule/$marker" ]]; then
		echo "Initializing the $submodule submodule..."
		git -C "$project_root" submodule update \
			--init --recursive --depth 1 -- "$submodule"
	fi

	[[ -e "$project_root/$submodule/$marker" ]] || {
		echo "Submodule initialization did not produce $submodule/$marker" >&2
		exit 1
	}
}

# ------------------------------------------------------------------------------
# Pinned Emscripten SDK installation
# ------------------------------------------------------------------------------
ensure_emsdk() {
	local emsdk_dir="$project_root/tools/emsdk"
	local version="${EMSDK_VERSION:-$(sed -n '1p' "$project_root/.emscripten-version")}"
	local stamp_dir="$project_root/.cache/toolchains"
	local stamp="$stamp_dir/emsdk-$version.stamp"
	local sdk_ready=0

	mkdir -p "$stamp_dir"
	ensure_submodule tools/emsdk emsdk

	if [[ -x "$emsdk_dir/upstream/emscripten/emcc" ]] \
		&& "$emsdk_dir/upstream/emscripten/emcc" --version 2> /dev/null \
		| grep -Fq " $version"; then
		sdk_ready=1
	fi

	if [[ "$sdk_ready" -eq 0 ]]; then
		echo "Installing Emscripten SDK $version in tools/emsdk..."
		(
			cd "$emsdk_dir"
			./emsdk install "$version"
			./emsdk activate "$version"
		)
	else
		(
			cd "$emsdk_dir"
			./emsdk activate "$version" > /dev/null
		)
	fi

	touch "$stamp"
	[[ -x "$emsdk_dir/upstream/emscripten/emcc" ]] || {
		echo "emsdk did not install emcc." >&2
		exit 1
	}
	[[ -x "$emsdk_dir/upstream/bin/wasm-opt" ]] || {
		echo "emsdk did not install wasm-opt." >&2
		exit 1
	}
}

# ------------------------------------------------------------------------------
# Brotli version discovery and repository-local build
# ------------------------------------------------------------------------------
read_brotli_version_component() {
	local source_dir="$1"
	local component="$2"

	sed -n \
		"s/^#define BROTLI_VERSION_${component} \\([0-9][0-9]*\\)$/\\1/p" \
		"$source_dir/c/common/version.h"
}

get_brotli_version() {
	local source_dir="$1"

	printf '%s.%s.%s' \
		"$(read_brotli_version_component "$source_dir" MAJOR)" \
		"$(read_brotli_version_component "$source_dir" MINOR)" \
		"$(read_brotli_version_component "$source_dir" PATCH)"
}

ensure_brotli() {
	local source_dir="$project_root/tools/brotli"
	local build_dir="$project_root/.cache/toolchains/brotli"
	local binary="$build_dir/brotli"
	local host_cc="${HOST_CC:-cc}"
	local expected_version
	local actual_version source_revision expected_stamp current_stamp
	local stamp="$build_dir/.source-revision"

	expected_version="${BROTLI_VERSION:-$(sed -n '1p' "$project_root/.brotli-version")}"
	ensure_submodule tools/brotli CMakeLists.txt
	actual_version="$(get_brotli_version "$source_dir")"

	if [[ "$actual_version" != "$expected_version" ]]; then
		echo "Updating tools/brotli to its pinned gitlink..."
		git -C "$project_root" submodule update \
			--init --recursive --depth 1 -- tools/brotli
		actual_version="$(get_brotli_version "$source_dir")"
	fi

	[[ "$actual_version" == "$expected_version" ]] || {
		echo "Brotli version mismatch: expected $expected_version, found $actual_version" >&2
		exit 1
	}
	command -v cmake > /dev/null 2>&1 || {
		echo "Missing tool required to build bundled Brotli: cmake" >&2
		exit 1
	}
	command -v "$host_cc" > /dev/null 2>&1 || {
		echo "Missing host C compiler: $host_cc" >&2
		exit 1
	}

	source_revision="$(git -C "$source_dir" rev-parse HEAD)"
	expected_stamp="$expected_version $source_revision"
	current_stamp="$(sed -n '1p' "$stamp" 2> /dev/null || true)"

	if [[ ! -x "$binary" || "$current_stamp" != "$expected_stamp" ]]; then
		echo "Building repository-local Brotli $expected_version..."
		cmake \
			-S "$source_dir" \
			-B "$build_dir" \
			-DCMAKE_BUILD_TYPE=Release \
			-DCMAKE_C_COMPILER="$host_cc" \
			-DBUILD_SHARED_LIBS=OFF \
			-DBROTLI_BUILD_TOOLS=ON \
			-DBROTLI_DISABLE_TESTS=ON
		cmake --build "$build_dir" --config Release --target brotli --parallel 2
		printf '%s\n' "$expected_stamp" > "$stamp"
	fi

	[[ -x "$binary" ]] || {
		echo "The Brotli CLI was not produced at $binary" >&2
		exit 1
	}
}

# ------------------------------------------------------------------------------
# Lockfile-backed repository-local Terser installation
# ------------------------------------------------------------------------------
ensure_terser() {
	local source_dir="$project_root/docker/terser"
	local install_dir="$project_root/.cache/toolchains/terser"
	local binary="$install_dir/node_modules/.bin/terser"
	local expected_version
	local expected_lock current_lock
	local stamp="$install_dir/.package-lock.sha256"

	expected_version="${TERSER_VERSION:-$(sed -n '1p' "$project_root/.terser-version")}"
	expected_lock="$(shasum -a 256 "$source_dir/package-lock.json" | awk '{ print $1 }')"
	current_lock="$(sed -n '1p' "$stamp" 2> /dev/null || true)"

	command -v npm > /dev/null 2>&1 || {
		echo "Missing tool required to install repository-local Terser: npm" >&2
		exit 1
	}

	if [[ ! -x "$binary" || "$current_lock" != "$expected_lock" ]]; then
		echo "Installing repository-local Terser $expected_version..."
		mkdir -p "$install_dir"
		install -m 0644 "$source_dir/package.json" "$install_dir/package.json"
		install -m 0644 "$source_dir/package-lock.json" "$install_dir/package-lock.json"
		npm ci \
			--prefix "$install_dir" \
			--omit=dev \
			--no-audit \
			--no-fund
		printf '%s\n' "$expected_lock" > "$stamp"
	fi

	[[ "$("$binary" --version | awk '{ print $NF }')" == "$expected_version" ]] || {
		echo "Repository-local Terser version does not match $expected_version." >&2
		exit 1
	}
}

# ------------------------------------------------------------------------------
# Unified tool execution
# ------------------------------------------------------------------------------
run_tool() {
	local tool="$1"
	shift

	case "$tool" in
		emcc)
			local executable="$project_root/tools/emsdk/upstream/emscripten/emcc"
			[[ -x "$executable" ]] || ensure_emsdk
			exec "$executable" "$@"
			;;
		wasm-opt)
			local executable="$project_root/tools/emsdk/upstream/bin/wasm-opt"
			[[ -x "$executable" ]] || ensure_emsdk
			exec "$executable" "$@"
			;;
		brotli)
			ensure_brotli
			exec "$project_root/.cache/toolchains/brotli/brotli" "$@"
			;;
		terser)
			ensure_terser
			exec "$project_root/.cache/toolchains/terser/node_modules/.bin/terser" "$@"
			;;
		*)
			echo "Unknown tool: $tool" >&2
			exit 2
			;;
	esac
}

# ------------------------------------------------------------------------------
# Toolchain action dispatch
# ------------------------------------------------------------------------------
case "$action:$component" in
	ensure:emsdk)
		ensure_emsdk
		;;
	ensure:brotli)
		ensure_brotli
		;;
	ensure:terser)
		ensure_terser
		;;
	run:emcc | run:wasm-opt | run:brotli | run:terser)
		shift 2
		run_tool "$component" "$@"
		;;
	*)
		echo "Usage: $0 {ensure {emsdk|brotli|terser}|run {emcc|wasm-opt|brotli|terser} [ARG...]}" >&2
		exit 2
		;;
esac

# EOF

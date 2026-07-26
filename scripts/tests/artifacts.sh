#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Sergio Bonatto
# SPDX-License-Identifier: MIT

# ==============================================================================
# artifacts.sh — audit content-addressed JavaScript and WebAssembly artifacts
#
# - Verifies that published filenames contain the correct SHA-256 prefix.
# - Audits the release WASM with Binaryen and LLVM structural inspectors.
# - Rejects WASI/OS imports, mutable memory limits, debug data, and allocators.
# - Selects the hash-names or binary test through one argument-driven module.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Absolute paths and requested artifact-test action
# ------------------------------------------------------------------------------
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
action="${1:-}"
shift || true
app_dir="${1:-"$project_root/dist/assets/app"}"

[[ -d "$app_dir" ]] || {
	echo "Application artifact directory does not exist: $app_dir" >&2
	exit 1
}

# ------------------------------------------------------------------------------
# Shared content-address verification
# ------------------------------------------------------------------------------
verify_hash_name() {
	local file="$1"
	local filename embedded_hash full_hash actual_hash

	filename="$(basename "$file")"
	if [[ ! "$filename" =~ ^app\.([0-9a-f]{8,64})\.(js|wasm)$ ]]; then
		echo "Invalid content-addressed application filename: $file" >&2
		return 1
	fi

	embedded_hash="${BASH_REMATCH[1]}"
	full_hash="$(shasum -a 256 "$file" | awk '{ print $1 }')"
	actual_hash="${full_hash:0:${#embedded_hash}}"
	if [[ "$embedded_hash" != "$actual_hash" ]]; then
		echo "Invalid content hash: $file" >&2
		echo "Filename: $embedded_hash" >&2
		echo "Content:  $actual_hash" >&2
		return 1
	fi
	printf 'Verified: %s -> %s\n' "${file#"$project_root/"}" "$embedded_hash"
}

discover_artifacts() {
	shopt -s nullglob
	javascript_files=("$app_dir"/app.*.js)
	wasm_files=("$app_dir"/app.*.wasm)
	shopt -u nullglob

	[[ "${#javascript_files[@]}" -eq 1 ]] || {
		echo "Expected exactly one app.<hash>.js, found ${#javascript_files[@]}." >&2
		exit 1
	}
	[[ "${#wasm_files[@]}" -eq 1 ]] || {
		echo "Expected exactly one app.<hash>.wasm, found ${#wasm_files[@]}." >&2
		exit 1
	}
}

test_hash_names() {
	discover_artifacts
	verify_hash_name "${javascript_files[0]}"
	verify_hash_name "${wasm_files[0]}"
	echo "Application artifact names match their SHA-256 content."
}

# ------------------------------------------------------------------------------
# Inspector discovery
# ------------------------------------------------------------------------------
find_inspector() {
	local name="$1"
	local bundled="$project_root/tools/emsdk/upstream/bin/$name"

	if command -v "$name" > /dev/null 2>&1; then
		command -v "$name"
	elif [[ -x "$bundled" ]]; then
		printf '%s\n' "$bundled"
	else
		return 1
	fi
}

# ------------------------------------------------------------------------------
# WebAssembly binary audit
# ------------------------------------------------------------------------------
test_binary() {
	local wasm_file magic temporary_dir wat_file readobj_report
	local imports_file import_modules memory_line initial_pages maximum_pages
	local llvm_readobj llvm_objdump wasm_dis readelf_report objdump_report
	local wasm_opt="${WASM_OPT:-wasm-opt}"
	local -a wasm_opt_args wasm_opt_cmd

	discover_artifacts
	wasm_file="${wasm_files[0]}"
	verify_hash_name "$wasm_file"
	magic="$(od -An -tx1 -N8 "$wasm_file" | tr -d '[:space:]')"
	[[ "$magic" == "0061736d01000000" ]] || {
		echo "Invalid WebAssembly magic or version: $magic" >&2
		exit 1
	}

	read -r -a wasm_opt_args <<< "${EHS_WASM_OPT_ARGS:-}"
	wasm_opt_cmd=("$wasm_opt" "${wasm_opt_args[@]}")
	"${wasm_opt_cmd[@]}" --version

	temporary_dir="$(mktemp -d)"
	trap 'rm -rf "$temporary_dir"' RETURN
	wat_file="$temporary_dir/module.wat"
	readobj_report="$temporary_dir/llvm-readobj.txt"
	imports_file="$temporary_dir/imports.txt"
	readelf_report="$temporary_dir/readelf.txt"
	objdump_report="$temporary_dir/llvm-objdump.txt"

	echo
	echo "== Binaryen validation and metrics =="
	"${wasm_opt_cmd[@]}" "$wasm_file" --all-features -o "$temporary_dir/validated.wasm"
	"${wasm_opt_cmd[@]}" "$wasm_file" --all-features --metrics
	[[ -s "$temporary_dir/validated.wasm" ]]

	wasm_dis="$(find_inspector wasm-dis)" || {
		echo "Missing required WebAssembly inspector: wasm-dis" >&2
		exit 1
	}
	"$wasm_dis" "$wasm_file" -o "$wat_file"
	[[ -s "$wat_file" ]]

	llvm_readobj="$(find_inspector llvm-readobj)" || {
		echo "Missing required WebAssembly inspector: llvm-readobj" >&2
		exit 1
	}
	echo
	echo "== LLVM file header, sections, symbols, and relocations =="
	"$llvm_readobj" \
		--file-headers \
		--sections \
		--symbols \
		--relocations \
		"$wasm_file" | tee "$readobj_report"
	grep -Fq 'Format: WASM' "$readobj_report"
	grep -Eq 'Arch: wasm32|Arch: wasm64' "$readobj_report"

	if llvm_objdump="$(find_inspector llvm-objdump)"; then
		echo
		echo "== LLVM object headers and symbols =="
		if "$llvm_objdump" \
			--file-headers \
			--section-headers \
			--syms \
			"$wasm_file" > "$objdump_report" 2>&1; then
			cat "$objdump_report"
		else
			cat "$objdump_report"
			echo "WARNING: llvm-objdump recognized WASM but cannot decode this object; llvm-readobj remains authoritative." >&2
		fi
	else
		echo "WARNING: llvm-objdump unavailable; llvm-readobj audit remains authoritative." >&2
	fi

	echo
	echo "== WebAssembly imports, exports, tables, and memory =="
	grep -E '^[[:space:]]+\((import|export|table|memory) ' "$wat_file" || true
	grep -E '^[[:space:]]+\(import ' "$wat_file" > "$imports_file" || true
	import_modules="$(
		sed -n 's/^[[:space:]]*(import "\([^"]*\)".*/\1/p' "$imports_file" \
			| LC_ALL=C sort -u
	)"
	if [[ "$(printf '%s\n' "$import_modules" | sed '/^$/d' | wc -l)" -gt 1 ]]; then
		echo "WebAssembly imports bypass a single HAL module:" >&2
		printf '%s\n' "$import_modules" >&2
		exit 1
	fi
	if grep -Eiq \
		'wasi|fd_|path_|sock|environ_|clock_|random_get|system|popen|fork|exec' \
		"$imports_file"; then
		echo "A forbidden OS, filesystem, network, or process import was found:" >&2
		grep -Ei \
			'wasi|fd_|path_|sock|environ_|clock_|random_get|system|popen|fork|exec' \
			"$imports_file" >&2
		exit 1
	fi
	if grep -Eq \
		'\(export "(malloc|calloc|realloc|free|sbrk|emscripten_resize_heap)"' \
		"$wat_file"; then
		echo "A heap allocator was exported by the release WebAssembly module." >&2
		exit 1
	fi
	if grep -Eq '\(memory\.grow([[:space:])])' "$wat_file"; then
		echo "The release WebAssembly module contains memory.grow." >&2
		exit 1
	fi

	memory_line="$(
		grep -E \
			'^[[:space:]]+\(memory \$[0-9]+ [0-9]+ [0-9]+\)' \
			"$wat_file" \
			| head -1
	)"
	[[ -n "$memory_line" ]] || {
		echo "The module does not declare fixed initial and maximum memory." >&2
		exit 1
	}
	read -r initial_pages maximum_pages < <(
		printf '%s\n' "$memory_line" \
			| sed -E 's/.*\$[0-9]+ ([0-9]+) ([0-9]+)\).*/\1 \2/'
	)
	[[ "$initial_pages" == "$maximum_pages" ]] || {
		echo "WebAssembly memory is growable: $memory_line" >&2
		exit 1
	}

	if grep -Fq 'Type: CUSTOM' "$readobj_report"; then
		echo "Release WebAssembly contains debug or toolchain custom sections." >&2
		exit 1
	fi

	echo
	echo "== ELF rejection check =="
	if readelf -h "$wasm_file" > "$readelf_report" 2>&1; then
		echo "readelf unexpectedly classified the WebAssembly module as ELF." >&2
		cat "$readelf_report" >&2
		exit 1
	fi
	cat "$readelf_report"
	echo "Expected result: WebAssembly is not an ELF binary; LLVM/Binaryen reports are authoritative."

	printf '\nSHA-256: %s\n' "$(shasum -a 256 "$wasm_file" | awk '{ print $1 }')"
	printf 'Size: %s bytes\n' "$(wc -c < "$wasm_file" | tr -d '[:space:]')"
	printf 'Memory: %s fixed pages (%s bytes)\n' \
		"$initial_pages" "$((initial_pages * 65536))"
	echo "WebAssembly binary audit passed."
}

# ------------------------------------------------------------------------------
# Module action dispatch
# ------------------------------------------------------------------------------
case "$action" in
	hash-names)
		test_hash_names
		;;
	binary)
		test_binary
		;;
	*)
		echo "Usage: $0 {hash-names|binary} [dist/assets/app]" >&2
		exit 2
		;;
esac

# EOF

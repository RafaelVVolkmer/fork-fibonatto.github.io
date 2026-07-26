#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Sergio Bonatto
# SPDX-License-Identifier: MIT

# ==============================================================================
# build.sh — build-flag audit and compilation-database helper
#
# - Probes every configured host, Emscripten, linker, and Binaryen flag.
# - Audits release and sanitizer-enabled debug profiles independently.
# - Records the exact pinned tool versions used by the build pipeline.
# - Generates compile_commands.json from the canonical Makefile configuration.
# - Selects the operation through the audit-flags or compile-commands argument.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Repository root and requested module action
# ------------------------------------------------------------------------------
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
action="${1:-}"
shift || true

# ------------------------------------------------------------------------------
# Build-profile flag and toolchain audit
# ------------------------------------------------------------------------------
audit_flags() {
	local report="${1:?report path was not provided}"
	local audit_dir probe_c probe_o probe_host probe_js probe_wasm
	local build_profile="${EHS_BUILD_PROFILE:-release}"
	local emcc="${EMCC:?EMCC was not provided}"
	local wasm_opt="${WASM_OPT:?WASM_OPT was not provided}"
	local flag
	local -a emcc_args wasm_opt_args brotli_args terser_args
	local -a emcc_cmd wasm_opt_cmd brotli_cmd terser_cmd
	local -a host_flags host_link_flags compile_flags link_flags
	local -a emscripten_settings wasm_opt_flags

	read -r -a emcc_args <<< "${EHS_EMCC_ARGS:-}"
	read -r -a wasm_opt_args <<< "${EHS_WASM_OPT_ARGS:-}"
	read -r -a brotli_args <<< "${EHS_BROTLI_ARGS:-}"
	read -r -a terser_args <<< "${EHS_TERSER_ARGS:-}"
	emcc_cmd=("$emcc" "${emcc_args[@]}")
	wasm_opt_cmd=("$wasm_opt" "${wasm_opt_args[@]}")
	brotli_cmd=("${BROTLI:-brotli}" "${brotli_args[@]}")
	terser_cmd=("${TERSER:-terser}" "${terser_args[@]}")
	read -r -a host_flags <<< "${EHS_HOST_FLAGS:?host compiler flags were not provided}"
	read -r -a host_link_flags <<< "${EHS_HOST_LINK_FLAGS:?host linker flags were not provided}"
	read -r -a compile_flags <<< "${EHS_COMPILE_FLAGS:?C compiler flags were not provided}"
	read -r -a link_flags <<< "${EHS_LINK_FLAGS:?linker flags were not provided}"
	read -r -a emscripten_settings <<< "${EHS_EMSCRIPTEN_SETTINGS:?Emscripten settings were not provided}"
	read -r -a wasm_opt_flags <<< "${EHS_WASM_OPT_FLAGS:?wasm-opt flags were not provided}"

	audit_dir="$(dirname "$report")"
	probe_c="$audit_dir/flag-probe.c"
	probe_o="$audit_dir/flag-probe.o"
	probe_host="$audit_dir/flag-probe-host"
	probe_js="$audit_dir/flag-probe.js"
	probe_wasm="$audit_dir/flag-probe.wasm"

	mkdir -p "$audit_dir"
	printf '%s\n' \
		'#include <stddef.h>' \
		'int main(void) {' \
		'	return (int)sizeof(size_t) == 0;' \
		'}' > "$probe_c"

	{
		printf 'EHS %s flag audit\n' "$build_profile"
		echo "===================="
		echo
		echo "Pinned emsdk: ${EMSDK_VERSION:-unknown}"
		echo "Pinned Brotli: ${BROTLI_VERSION:-unknown}"
		echo "Pinned Terser: ${TERSER_VERSION:-unknown}"
		echo "emcc: $("${emcc_cmd[@]}" --version | sed -n '1p')"
		echo "wasm-opt: $("${wasm_opt_cmd[@]}" --version | sed -n '1p')"
		echo "host cc: $(${HOST_CC:-cc} --version | sed -n '1p')"
		echo "terser: $("${terser_cmd[@]}" --version | sed -n '1p')"
		echo "brotli: $("${brotli_cmd[@]}" --version 2>&1 | sed -n '1p')"
		echo
	} > "$report"

	for flag in "${host_flags[@]}"; do
		"${HOST_CC:-cc}" -Werror "$flag" -c "$probe_c" -o "$probe_o" > /dev/null 2>&1
		printf 'host     PASS  %s\n' "$flag" >> "$report"
	done
	for flag in "${host_link_flags[@]}"; do
		"${HOST_CC:-cc}" -O2 "$probe_c" "$flag" -o "$probe_host" > /dev/null 2>&1
		printf 'host-link PASS  %s\n' "$flag" >> "$report"
	done
	for flag in "${compile_flags[@]}"; do
		"${emcc_cmd[@]}" \
			-Werror \
			-Werror=unknown-warning-option \
			-Werror=unused-command-line-argument \
			"$flag" -c "$probe_c" -o "$probe_o" > /dev/null 2>&1
		printf 'compile  PASS  %s\n' "$flag" >> "$report"
	done
	for flag in "${link_flags[@]}"; do
		"${emcc_cmd[@]}" -Oz "$probe_c" "$flag" -o "$probe_js" > /dev/null 2>&1
		printf 'link     PASS  %s\n' "$flag" >> "$report"
	done
	for flag in "${emscripten_settings[@]}"; do
		"${emcc_cmd[@]}" -Oz "$probe_c" "$flag" -o "$probe_js" > /dev/null 2>&1
		printf 'setting  PASS  %s\n' "$flag" >> "$report"
	done

	"${emcc_cmd[@]}" -Oz "$probe_c" -o "$probe_js" > /dev/null 2>&1
	"${wasm_opt_cmd[@]}" "${wasm_opt_flags[@]}" "$probe_wasm" \
		-o "$audit_dir/flag-probe.optimized.wasm" > /dev/null 2>&1
	for flag in "${wasm_opt_flags[@]}"; do
		printf 'wasm-opt PASS  %s\n' "$flag" >> "$report"
	done
	printf '\nAll configured %s flags passed.\n' "$build_profile" >> "$report"

	rm -f \
		"$probe_c" \
		"$probe_o" \
		"$probe_host" \
		"$probe_js" \
		"$probe_wasm" \
		"$audit_dir/flag-probe.optimized.wasm"
	printf '%s flags audited successfully.\n' \
		"${build_profile^}"
}

# ------------------------------------------------------------------------------
# Compilation database generation
# ------------------------------------------------------------------------------
compile_commands() {
	local build_dir="$project_root/.build"
	local object_dir="$build_dir/obj"
	local output="$project_root/compile_commands.json"
	local emcc="${EMCC:-emcc}"
	local source base fragment
	local first=1
	local -a emcc_args emcc_cmd sources cppflags compile_flags

	read -r -a emcc_args <<< "${EHS_EMCC_ARGS:-}"
	emcc_cmd=("$emcc" "${emcc_args[@]}")
	read -r -a sources <<< "${EHS_SOURCES:?runtime sources were not provided}"
	read -r -a cppflags <<< "${EHS_CPPFLAGS:?preprocessor flags were not provided}"
	read -r -a compile_flags <<< "${EHS_COMPILE_FLAGS:?compile flags were not provided}"

	mkdir -p "$object_dir"
	printf '[\n' > "$output"

	for source in "${sources[@]}"; do
		source="$project_root/$source"
		base="$(basename "$source" .c)"
		fragment="$object_dir/$base.json"
		"${emcc_cmd[@]}" "$source" \
			"${cppflags[@]}" \
			"${compile_flags[@]}" \
			-MJ "$fragment" \
			-c \
			-o "$object_dir/$base.o"
		if [[ "$first" -eq 0 ]]; then
			printf ',\n' >> "$output"
		fi
		sed '$s/,$//' "$fragment" >> "$output"
		first=0
		rm -f "$fragment"
	done
	printf '\n]\n' >> "$output"
}

# ------------------------------------------------------------------------------
# Module action dispatch
# ------------------------------------------------------------------------------
case "$action" in
	audit-flags)
		audit_flags "$@"
		;;
	compile-commands)
		compile_commands "$@"
		;;
	*)
		echo "Usage: $0 {audit-flags REPORT|compile-commands}" >&2
		exit 2
		;;
esac

# EOF

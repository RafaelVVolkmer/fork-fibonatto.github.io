#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Sergio Bonatto
# SPDX-License-Identifier: MIT

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cc="${SANITIZER_CC:-clang}"
build_dir="$project_root/.build/native-sanitizers"
test_binary="$build_dir/test-core"

command -v "$cc" > /dev/null 2>&1 || {
	echo "Missing sanitizer compiler: $cc" >&2
	exit 1
}

rm -rf "$build_dir"
mkdir -p "$build_dir"

"$cc" \
	-std=c11 \
	-O1 \
	-g3 \
	-fno-omit-frame-pointer \
	-fno-optimize-sibling-calls \
	-fsanitize=address,undefined,leak,alignment \
	-fno-sanitize-recover=all \
	-Wall \
	-Wextra \
	-Wpedantic \
	-Werror \
	-I"$project_root/tests/include" \
	-I"$project_root/core/inc" \
	"$project_root/core/src/buffer.c" \
	"$project_root/core/src/math.c" \
	"$project_root/core/src/markdown.c" \
	"$project_root/tests/unit/test_core.c" \
	-o "$test_binary"

ASAN_OPTIONS="detect_leaks=1:halt_on_error=1:strict_string_checks=1" \
	UBSAN_OPTIONS="halt_on_error=1:print_stacktrace=1" \
	LSAN_OPTIONS="exitcode=23" \
	"$test_binary"

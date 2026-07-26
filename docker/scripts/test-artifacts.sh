#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Sergio Bonatto
# SPDX-License-Identifier: MIT

# ==============================================================================
# test-artifacts.sh — validate and export final container website artifacts
#
# - Requires exactly one content-addressed JavaScript and WebAssembly artifact.
# - Validates JavaScript syntax, WebAssembly structure, hashes, and references.
# - Round-trips Brotli sidecars and rejects placeholders or unexpected empties.
# - Copies only the verified release tree into the next Docker build stage.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Required release files and primary application artifact discovery
# ------------------------------------------------------------------------------
test -s dist/index.html
test -s dist/assets/icons/favicon.svg
test -d dist/assets/app

js_file="$(
	find dist/assets/app \
		-maxdepth 1 \
		-type f \
		-name 'app.*.js'
)"
wasm_file="$(
	find dist/assets/app \
		-maxdepth 1 \
		-type f \
		-name 'app.*.wasm'
)"

test -n "$js_file"
test -n "$wasm_file"
test "$(printf '%s\n' "$js_file" | wc -l)" -eq 1
test "$(printf '%s\n' "$wasm_file" | wc -l)" -eq 1

# ------------------------------------------------------------------------------
# Syntax, structure, template, and content-address assertions
# ------------------------------------------------------------------------------
node --check "$js_file"
wasm-validate "$wasm_file"

if grep -R -n -E '\{\{[A-Z_][A-Z0-9_]*\}\}' dist; then
	echo "Unreplaced template placeholder"
	exit 1
fi

js_name="$(basename "$js_file")"
wasm_name="$(basename "$wasm_file")"
grep -Fq "assets/app/${js_name}" dist/index.html
grep -Fq "$wasm_name" "$js_file"

./scripts/tests/artifacts.sh hash-names dist/assets/app

# ------------------------------------------------------------------------------
# Brotli round-trip and empty-file checks
# ------------------------------------------------------------------------------
for compressed in dist/assets/app/*.br; do
	original="${compressed%.br}"
	temporary="$(mktemp)"
	brotli --decompress --stdout "$compressed" > "$temporary"
	cmp "$original" "$temporary"
	rm -f "$temporary"
done

if find dist \
	-type f \
	-empty \
	! -name '.nojekyll' \
	| grep -q .; then
	echo "Unexpected empty artifact"
	exit 1
fi

# ------------------------------------------------------------------------------
# Verified-stage export
# ------------------------------------------------------------------------------
mkdir -p /verified
cp -a dist/. /verified/

echo "Final container artifacts verified."

# EOF

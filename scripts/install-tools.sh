#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Sergio Bonatto
# SPDX-License-Identifier: MIT

# ==============================================================================
# install-tools.sh — install pinned standalone lint executables
#
# - Reads versions, URLs, archive formats and SHA-256 digests from versions.json.
# - Installs selected tools into LINT_BIN_DIR or .cache/lint/bin.
# - Verifies every download before extracting or installing it.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Absolute paths, destination, and temporary workspace
# ------------------------------------------------------------------------------
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
versions_file="$project_root/lint/json/versions.json"
destination="${LINT_BIN_DIR:-$project_root/.cache/lint/bin}"
temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT

# ------------------------------------------------------------------------------
# Supported platform and bootstrap dependency checks
# ------------------------------------------------------------------------------
[[ "$(uname -s)" == "Linux" && "$(uname -m)" == "x86_64" ]] || {
	echo "lint/json/versions.json pins Linux x86-64 executables." >&2
	exit 1
}

for tool in curl jq; do
	command -v "$tool" > /dev/null 2>&1 || {
		echo "Missing tool required to install linters: $tool" >&2
		exit 1
	}
done

# ------------------------------------------------------------------------------
# Portable SHA-256 verification
# ------------------------------------------------------------------------------
verify_sha256() {
	local expected="$1"
	local path="$2"

	if command -v sha256sum > /dev/null 2>&1; then
		printf '%s  %s\n' "$expected" "$path" \
			| sha256sum --check --status
	elif command -v shasum > /dev/null 2>&1; then
		printf '%s  %s\n' "$expected" "$path" \
			| shasum -a 256 --check --status
	else
		echo "Missing SHA-256 verification tool: sha256sum or shasum" >&2
		return 1
	fi
}

mkdir -p "$destination"

# ------------------------------------------------------------------------------
# Manifest-driven download, extraction, and installation
# ------------------------------------------------------------------------------
install_tool() {
	local name="$1"
	local version
	local url
	local expected_sha256
	local archive_type
	local binary_name
	local archive
	local extract_dir
	local extracted_binary

	version="$(jq -er --arg name "$name" \
		'.[$name].version' "$versions_file")"
	url="$(jq -er --arg name "$name" \
		'.[$name].url' "$versions_file")"
	expected_sha256="$(jq -er --arg name "$name" \
		'.[$name].sha256' "$versions_file")"
	archive_type="$(jq -er --arg name "$name" \
		'.[$name].archive' "$versions_file")"
	binary_name="$(jq -er --arg name "$name" \
		'.[$name].binary' "$versions_file")"
	archive="$temporary_dir/$name.download"
	extract_dir="$temporary_dir/$name"

	echo "Installing $name $version..."
	curl --fail --location --silent --show-error \
		"$url" --output "$archive"
	verify_sha256 "$expected_sha256" "$archive"

	mkdir -p "$extract_dir"
	case "$archive_type" in
		binary)
			extracted_binary="$archive"
			;;
		gz)
			extracted_binary="$extract_dir/$binary_name"
			gzip --decompress --stdout "$archive" > "$extracted_binary"
			;;
		tar.gz)
			tar --extract --gzip --file "$archive" \
				--directory "$extract_dir"
			extracted_binary="$(
				find "$extract_dir" -type f \
					-name "$binary_name" -print -quit
			)"
			;;
		*)
			echo "Unsupported archive type: $archive_type" >&2
			return 1
			;;
	esac

	[[ -n "$extracted_binary" && -f "$extracted_binary" ]]
	install -m 0755 "$extracted_binary" "$destination/$binary_name"
}

# ------------------------------------------------------------------------------
# Pinned lint tool inventory and optional explicit selection
# ------------------------------------------------------------------------------
default_tools=(
	actionlint
	conftest
	hadolint
	lychee
	rumdl
	shfmt
	taplo
	typos
)

requested_tools=("$@")
if [[ "${#requested_tools[@]}" -eq 0 ]]; then
	requested_tools=("${default_tools[@]}")
fi

for tool in "${requested_tools[@]}"; do
	jq -e --arg name "$tool" 'has($name)' "$versions_file" > /dev/null || {
		echo "Unknown pinned tool: $tool" >&2
		exit 2
	}
	install_tool "$tool"
done

echo "Pinned lint tools installed in $destination"

# EOF

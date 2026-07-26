#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Sergio Bonatto
# SPDX-License-Identifier: MIT

# ==============================================================================
# reproducibility.sh — compare two clean releases of the same source tree
#
# - Uses the already-built release as the first comparison sample.
# - Produces one more clean artifact without recursively running lint or tests.
# - Compares SHA-256 manifests for every deterministic deployable file.
# - Excludes SBOMs because their standards require per-generation identifiers
#   and timestamps; each generated SBOM is still validated by the release.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Absolute paths and disposable comparison manifests
# ------------------------------------------------------------------------------
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
make_bin="${MAKE:-make}"
temporary_dir="$(mktemp -d)"
first_manifest="$temporary_dir/first.sha256"
second_manifest="$temporary_dir/second.sha256"
trap 'rm -rf "$temporary_dir"' EXIT

# ------------------------------------------------------------------------------
# Deterministic release manifest generation
# ------------------------------------------------------------------------------
create_manifest() {
	local output="$1"
	(
		cd "$project_root"
		find dist -type f \
			! -name 'sbom.cyclonedx.json' \
			! -name 'sbom.spdx.json' \
			-print0 \
			| LC_ALL=C sort -z \
			| xargs -0 shasum -a 256
	) > "$output"
}

[[ -d "$project_root/dist" ]] || {
	echo "dist/ does not exist; build the reference release first." >&2
	exit 1
}

# ------------------------------------------------------------------------------
# Reference capture and clean rebuild
# ------------------------------------------------------------------------------
echo "Reproducibility check: recording the reference release..."
create_manifest "$first_manifest"

echo "Reproducibility check: rebuilding the release once..."
EHS_LOGGED_MAKE=1 "$make_bin" --no-print-directory \
	-C "$project_root" _clean
EHS_LOGGED_MAKE=1 "$make_bin" --no-print-directory \
	-C "$project_root" _release
create_manifest "$second_manifest"

# ------------------------------------------------------------------------------
# Byte-for-byte digest comparison
# ------------------------------------------------------------------------------
if ! cmp -s "$first_manifest" "$second_manifest"; then
	echo "The two clean releases produced different file hashes:" >&2
	diff -u "$first_manifest" "$second_manifest" >&2 || true
	exit 1
fi

echo "Reproducibility verified for deterministic dist/ artifacts."

# EOF

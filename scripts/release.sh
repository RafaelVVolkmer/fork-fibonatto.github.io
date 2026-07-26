#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Sergio Bonatto
# SPDX-License-Identifier: MIT

# ==============================================================================
# release.sh — package, inventory, sign, and validate release artifacts
#
# - Materializes the complete static site and its content-addressed assets.
# - Generates formatted CycloneDX and SPDX inventories when Syft is available.
# - Copies build/test evidence and signs the release manifest with Cosign.
# - Validates every public asset, metadata contract, hash, and internal link.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Repository root and requested release action
# ------------------------------------------------------------------------------
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
action="${1:-}"
shift || true

# ------------------------------------------------------------------------------
# Sitemap materialization
# ------------------------------------------------------------------------------
generate_sitemap() {
	local posts_dir="${1:?posts directory was not provided}"
	local output="${2:?output file was not provided}"
	local site_url="${SITE_URL:?public site URL was not provided}"
	local post filename slug

	site_url="${site_url%/}"
	{
		printf '%s\n' \
			'<?xml version="1.0" encoding="UTF-8"?>' \
			'<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">' \
			'  <url>' \
			"    <loc>$site_url/#/</loc>" \
			'    <changefreq>monthly</changefreq>' \
			'    <priority>1.0</priority>' \
			'  </url>' \
			'  <url>' \
			"    <loc>$site_url/#/blog</loc>" \
			'    <changefreq>weekly</changefreq>' \
			'    <priority>0.8</priority>' \
			'  </url>'
		for post in "$posts_dir"/*.md; do
			filename="$(basename "$post" .md)"
			slug="$(printf '%s' "$filename" | LC_ALL=C sed 's/[^[:alnum:]]/_/g')"
			printf '%s\n' \
				'  <url>' \
				"    <loc>$site_url/#/post/$slug</loc>" \
				'    <priority>0.6</priority>' \
				'  </url>'
		done
		printf '%s\n' '</urlset>'
	} > "$output"
}

# ------------------------------------------------------------------------------
# Static release packaging and content-addressed assets
# ------------------------------------------------------------------------------
package_dist() {
	local build_dir="$project_root/.build"
	local dist_dir="$project_root/dist"
	local assets_dir="$project_root/assets"
	local site_dir="$project_root/site"
	local brotli="${BROTLI:-brotli}"
	local site_url pfp_hash font_regular_hash font_bold_hash
	local font_italic_hash font_bolditalic_hash pfp_path
	local font_regular_path font_bold_path font_italic_path
	local font_bolditalic_path wasm_hash wasm_name js_hash js_name
	local -a brotli_args brotli_cmd

	read -r -a brotli_args <<< "${EHS_BROTLI_ARGS:-}"
	brotli_cmd=("$brotli" "${brotli_args[@]}")
	site_url="$(
		sed -n \
			'/^[[:space:]]*#/d; /^[[:space:]]*$/d; p; q' \
			"$site_dir/url.txt"
	)"
	site_url="${site_url%/}"
	[[ "$site_url" == https://* ]] || {
		echo "site/url.txt must contain an HTTPS origin." >&2
		exit 1
	}
	[[ -f "$build_dir/app.js" && -f "$build_dir/app.wasm" ]] || {
		echo "The WebAssembly artifacts have not been compiled yet." >&2
		exit 1
	}

	rm -rf "$dist_dir"
	mkdir -p \
		"$dist_dir/LICENSES" \
		"$dist_dir/.metadata" \
		"$dist_dir/assets/app" \
		"$dist_dir/assets/fonts" \
		"$dist_dir/assets/icons" \
		"$dist_dir/assets/images/posts"
	cp -R "$site_dir/static/." "$dist_dir/"
	sed "s|{{SITE_URL}}|$site_url|g" \
		"$site_dir/static/robots.txt" > "$dist_dir/robots.txt"
	cp "$site_dir/dist.REUSE.toml" "$dist_dir/REUSE.toml"
	cp "$project_root/compile_commands.json" \
		"$dist_dir/.metadata/compile_commands.json"
	cp "$project_root/LICENSES/MIT.txt" "$dist_dir/LICENSES/MIT.txt"
	cp "$assets_dir/icons/favicon.svg" "$dist_dir/assets/icons/favicon.svg"
	cp "$assets_dir/images/seo.png" "$dist_dir/assets/images/seo.png"
	cp -R "$assets_dir/images/posts/." "$dist_dir/assets/images/posts/"

	pfp_hash="$(shasum -a 256 "$assets_dir/images/profile.avif" | cut -c 1-8)"
	font_regular_hash="$(shasum -a 256 "$assets_dir/fonts/lmroman10-regular.otf" | cut -c 1-8)"
	font_bold_hash="$(shasum -a 256 "$assets_dir/fonts/lmroman10-bold.otf" | cut -c 1-8)"
	font_italic_hash="$(shasum -a 256 "$assets_dir/fonts/lmroman10-italic.otf" | cut -c 1-8)"
	font_bolditalic_hash="$(shasum -a 256 "$assets_dir/fonts/lmroman10-bolditalic.otf" | cut -c 1-8)"
	pfp_path="assets/images/profile.$pfp_hash.avif"
	font_regular_path="assets/fonts/lmroman10-regular.$font_regular_hash.otf"
	font_bold_path="assets/fonts/lmroman10-bold.$font_bold_hash.otf"
	font_italic_path="assets/fonts/lmroman10-italic.$font_italic_hash.otf"
	font_bolditalic_path="assets/fonts/lmroman10-bolditalic.$font_bolditalic_hash.otf"
	cp "$assets_dir/images/profile.avif" "$dist_dir/$pfp_path"
	cp "$assets_dir/fonts/lmroman10-regular.otf" "$dist_dir/$font_regular_path"
	cp "$assets_dir/fonts/lmroman10-bold.otf" "$dist_dir/$font_bold_path"
	cp "$assets_dir/fonts/lmroman10-italic.otf" "$dist_dir/$font_italic_path"
	cp "$assets_dir/fonts/lmroman10-bolditalic.otf" "$dist_dir/$font_bolditalic_path"

	wasm_hash="$(shasum -a 256 "$build_dir/app.wasm" | cut -c 1-8)"
	wasm_name="app.$wasm_hash.wasm"
	cp "$build_dir/app.wasm" "$dist_dir/assets/app/$wasm_name"
	grep -Fq 'app.wasm' "$build_dir/app.js" || {
		echo "The compiled JavaScript does not reference app.wasm." >&2
		exit 1
	}
	sed "s/app\\.wasm/$wasm_name/g" \
		"$build_dir/app.js" > "$build_dir/app.final.js"
	grep -Fq "$wasm_name" "$build_dir/app.final.js" || {
		echo "Failed to inject the content-addressed WebAssembly filename." >&2
		exit 1
	}
	js_hash="$(shasum -a 256 "$build_dir/app.final.js" | cut -c 1-8)"
	js_name="app.$js_hash.js"
	cp "$build_dir/app.final.js" "$dist_dir/assets/app/$js_name"

	sed \
		-e "s|{{SITE_URL}}|$site_url|g" \
		-e "s|{{PFP}}|$pfp_path|g" \
		-e "s|{{FONT_REGULAR}}|$font_regular_path|g" \
		-e "s|{{FONT_BOLD}}|$font_bold_path|g" \
		-e "s|{{FONT_ITALIC}}|$font_italic_path|g" \
		-e "s|{{FONT_BOLDITALIC}}|$font_bolditalic_path|g" \
		-e "s|{{JS}}|assets/app/$js_name|g" \
		"$site_dir/index.html.tmpl" > "$dist_dir/index.html"

	SITE_URL="$site_url" generate_sitemap \
		"$project_root/content/posts" \
		"$dist_dir/sitemap.xml"
	"${brotli_cmd[@]}" -f -Z "$dist_dir/assets/app/$js_name"
	"${brotli_cmd[@]}" -f -Z "$dist_dir/assets/app/$wasm_name"
}

# ------------------------------------------------------------------------------
# CycloneDX and SPDX SBOM generation
# ------------------------------------------------------------------------------
generate_sboms() {
	local dist_dir="$project_root/dist"
	local work_dir="$project_root/.build/sbom"
	local scan_dir="$work_dir/input"
	local metadata_dir="$dist_dir/.metadata"
	local cyclonedx_sbom="$metadata_dir/sbom.cyclonedx.json"
	local spdx_sbom="$metadata_dir/sbom.spdx.json"
	local syft="${SYFT:-syft}"
	local expected_version actual_version source_name source_version
	local cyclonedx_tmp="$work_dir/sbom.cyclonedx.json"
	local spdx_tmp="$work_dir/sbom.spdx.json"
	local output

	expected_version="${SYFT_VERSION:-$(sed -n '1p' "$project_root/.syft-version")}"
	[[ -d "$dist_dir" ]] || {
		echo "dist/ does not exist; build the site before generating SBOMs." >&2
		exit 1
	}
	rm -f "$cyclonedx_sbom" "$spdx_sbom"
	if ! command -v "$syft" > /dev/null 2>&1; then
		if [[ "${REQUIRE_SBOM:-0}" == "1" ]]; then
			echo "Syft is required because REQUIRE_SBOM=1." >&2
			exit 1
		fi
		echo "WARNING: Syft was not found; skipping CycloneDX and SPDX SBOMs." >&2
		return 0
	fi

	actual_version="$("$syft" version | sed -n 's/^Version:[[:space:]]*v\{0,1\}//p')"
	if [[ -n "$expected_version" && "$actual_version" != "$expected_version" ]]; then
		if [[ "${REQUIRE_SBOM:-0}" == "1" ]]; then
			echo "Expected Syft $expected_version, found ${actual_version:-unknown}." >&2
			exit 1
		fi
		echo "WARNING: expected Syft $expected_version, found ${actual_version:-unknown}." >&2
	fi
	source_name="${SBOM_SOURCE_NAME:-${GITHUB_REPOSITORY:-RafaelVVolkmer/fork-fibonatto.github.io}}"
	source_version="${SBOM_SOURCE_VERSION:-${GITHUB_SHA:-}}"
	if [[ -z "$source_version" ]]; then
		source_version="$(git -C "$project_root" rev-parse HEAD 2> /dev/null || true)"
	fi
	source_version="${source_version:-unknown}"

	mkdir -p "$work_dir"
	rm -f "$cyclonedx_tmp" "$spdx_tmp"
	rm -rf "$scan_dir"
	mkdir -p "$scan_dir"
	cp -R "$dist_dir/." "$scan_dir/"
	rm -rf "$scan_dir/.metadata"
	SYFT_CACHE_DIR="$project_root/.cache/syft" "$syft" \
		--config "$project_root/lint/syft.yml" \
		scan "dir:$scan_dir" \
		--source-name "$source_name" \
		--source-version "$source_version" \
		--output "cyclonedx-json=$cyclonedx_tmp" \
		--output "spdx-json=$spdx_tmp"

	for output in "$cyclonedx_tmp" "$spdx_tmp"; do
		[[ -s "$output" && "$(wc -l < "$output")" -gt 1 ]] || {
			echo "Syft did not generate a formatted $(basename "$output")." >&2
			exit 1
		}
	done
	grep -q '"bomFormat": "CycloneDX"' "$cyclonedx_tmp"
	grep -q '"spdxVersion": "SPDX-' "$spdx_tmp"
	mkdir -p "$metadata_dir"
	mv "$cyclonedx_tmp" "$cyclonedx_sbom"
	mv "$spdx_tmp" "$spdx_sbom"
	echo "Formatted CycloneDX and SPDX SBOMs generated in dist/.metadata/."
}

# ------------------------------------------------------------------------------
# Build/test evidence, checksum manifest, and Cosign metadata
# ------------------------------------------------------------------------------
finalize_metadata() {
	local release_log="${1:?release log path was not provided}"
	local release_id="${2:?release identifier was not provided}"
	local dist_dir="$project_root/dist"
	local metadata_dir="$dist_dir/.metadata"
	local logs_dir="$metadata_dir/logs"
	local test_logs_source="$project_root/logs/tests/$release_id"
	local manifest="$metadata_dir/release.sha256"
	local bundle="$metadata_dir/release.cosign.bundle.json"
	local status_file="$metadata_dir/cosign.status.json"
	local cosign="${COSIGN:-cosign}"
	local expected_version actual_version=""

	expected_version="$(sed -n '1p' "$project_root/.cosign-version")"
	[[ -d "$dist_dir" && -f "$release_log" ]] || {
		echo "Release output or its build log is missing." >&2
		exit 1
	}
	rm -rf "$logs_dir"
	mkdir -p "$logs_dir/build" "$logs_dir/tests"
	cp "$release_log" "$logs_dir/build/"
	if [[ -d "$test_logs_source" ]]; then
		cp -R "$test_logs_source/." "$logs_dir/tests/"
	fi
	rm -f "$manifest" "$bundle" "$status_file"
	(
		cd "$dist_dir"
		find . -type f \
			! -path './.metadata/release.sha256' \
			! -path './.metadata/release.cosign.bundle.json' \
			! -path './.metadata/cosign.status.json' \
			-print0 \
			| LC_ALL=C sort -z \
			| xargs -0 shasum -a 256
	) > "$manifest"

	write_status() {
		local signed="$1"
		local mode="$2"
		local reason="$3"
		local bundle_value="null"

		[[ "$signed" == "true" ]] && bundle_value='"release.cosign.bundle.json"'
		printf '%s\n' \
			'{' \
			"  \"cosignVersion\": \"${actual_version:-unavailable}\"," \
			"  \"signed\": $signed," \
			"  \"mode\": \"$mode\"," \
			'  "subject": "release.sha256",' \
			"  \"bundle\": $bundle_value," \
			"  \"reason\": \"$reason\"" \
			'}' > "$status_file"
	}

	if ! command -v "$cosign" > /dev/null 2>&1; then
		write_status false unavailable "cosign executable not found"
		if [[ "${REQUIRE_SIGNATURE:-0}" == "1" ]]; then
			echo "Cosign is required because REQUIRE_SIGNATURE=1." >&2
			exit 1
		fi
		echo "WARNING: Cosign was not found; release manifest remains unsigned." >&2
		return 0
	fi
	actual_version="$("$cosign" version 2> /dev/null \
		| sed -n 's/^[[:space:]]*GitVersion:[[:space:]]*v\{0,1\}//p' \
		| sed -n '1p')"
	if [[ -n "$actual_version" && "$actual_version" != "$expected_version" ]]; then
		if [[ "${REQUIRE_SIGNATURE:-0}" == "1" ]]; then
			echo "Expected Cosign $expected_version, found $actual_version." >&2
			exit 1
		fi
		echo "WARNING: expected Cosign $expected_version, found $actual_version." >&2
	fi

	if [[ -n "${COSIGN_KEY:-}" ]]; then
		"$cosign" sign-blob --yes --key "$COSIGN_KEY" --bundle "$bundle" "$manifest"
		[[ -s "$bundle" ]]
		write_status true key "signed with COSIGN_KEY"
	elif [[ "${GITHUB_ACTIONS:-false}" == "true" &&
		-n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" &&
		-n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]]; then
		"$cosign" sign-blob --yes --bundle "$bundle" "$manifest"
		[[ -s "$bundle" ]]
		write_status true keyless-github-oidc "signed with GitHub Actions OIDC"
	else
		write_status false unavailable "set COSIGN_KEY or use GitHub Actions OIDC"
		if [[ "${REQUIRE_SIGNATURE:-0}" == "1" ]]; then
			echo "A Cosign key or GitHub Actions OIDC identity is required." >&2
			exit 1
		fi
		echo "WARNING: Cosign has no key or OIDC identity; release manifest remains unsigned." >&2
	fi
}

# ------------------------------------------------------------------------------
# Final distribution contract validation
# ------------------------------------------------------------------------------
validate_dist() {
	local dist_dir="$project_root/dist"
	local cyclonedx_sbom="$dist_dir/.metadata/sbom.cyclonedx.json"
	local spdx_sbom="$dist_dir/.metadata/sbom.spdx.json"
	local release_manifest="$dist_dir/.metadata/release.sha256"
	local cosign_status="$dist_dir/.metadata/cosign.status.json"
	local cosign_bundle="$dist_dir/.metadata/release.cosign.bundle.json"
	local compile_database="$dist_dir/.metadata/compile_commands.json"
	local path asset js_path wasm_path wasm_name
	local -a required=(
		"$dist_dir/index.html"
		"$dist_dir/REUSE.toml"
		"$dist_dir/LICENSES/MIT.txt"
		"$dist_dir/.nojekyll"
		"$compile_database"
		"$dist_dir/robots.txt"
		"$dist_dir/sitemap.xml"
		"$dist_dir/google0d6f4c8219a52398.html"
		"$dist_dir/assets/icons/favicon.svg"
		"$dist_dir/assets/images/seo.png"
	)

	if [[ "${REQUIRE_SBOM:-0}" == "1" ]]; then
		required+=("$cyclonedx_sbom" "$spdx_sbom")
	elif [[ -e "$cyclonedx_sbom" || -e "$spdx_sbom" ]]; then
		required+=("$cyclonedx_sbom" "$spdx_sbom")
	fi
	if [[ "${REQUIRE_SIGNATURE:-0}" == "1" ]]; then
		required+=("$release_manifest" "$cosign_status" "$cosign_bundle")
	fi
	for path in "${required[@]}"; do
		[[ -f "$path" ]] || {
			echo "Missing required file: ${path#"$project_root/"}" >&2
			exit 1
		}
	done
	if [[ "$(sed -n '/[^[:space:]]/ { p; q; }' "$compile_database")" != "[" ]] \
		|| [[ "$(tail -n 1 "$compile_database")" != "]" ]] \
		|| ! grep -q '"file":' "$compile_database"; then
		echo "The published compile_commands.json is malformed or empty." >&2
		exit 1
	fi
	! grep -q '{{[A-Z_]*}}' "$dist_dir/index.html" || {
		echo "The final HTML still contains template placeholders." >&2
		exit 1
	}
	grep -q '^Sitemap: https://.*/sitemap\.xml$' "$dist_dir/robots.txt" || {
		echo "robots.txt contains an invalid sitemap URL." >&2
		exit 1
	}

	if [[ -e "$cyclonedx_sbom" || -e "$spdx_sbom" ]]; then
		[[ "$(wc -l < "$cyclonedx_sbom")" -gt 1 ]]
		[[ "$(wc -l < "$spdx_sbom")" -gt 1 ]]
		grep -q '"bomFormat": "CycloneDX"' "$cyclonedx_sbom"
		grep -q '"components": \[' "$cyclonedx_sbom"
		grep -q '"spdxVersion": "SPDX-' "$spdx_sbom"
		grep -q '"files": \[' "$spdx_sbom"
	fi

	if [[ -e "$release_manifest" || -e "$cosign_status" ]]; then
		[[ -s "$release_manifest" && -s "$cosign_status" ]]
		find "$dist_dir/.metadata/logs/build" -type f -name '*.log' \
			-print -quit | grep -q .
		find "$dist_dir/.metadata/logs/tests" -type f -name '*.log' \
			-print -quit | grep -q .
		(cd "$dist_dir" && shasum -a 256 --check ".metadata/release.sha256" > /dev/null)
		grep -q '"subject": "release.sha256"' "$cosign_status"
		if grep -q '"signed": true' "$cosign_status"; then
			[[ -s "$cosign_bundle" ]]
		elif [[ "${REQUIRE_SIGNATURE:-0}" == "1" ]]; then
			echo "The strict release contract forbids an unsigned manifest." >&2
			exit 1
		fi
	fi

	while IFS= read -r asset; do
		[[ -f "$dist_dir/$asset" ]] || {
			echo "HTML references a missing asset: $asset" >&2
			exit 1
		}
	done < <(grep -oE 'assets/[A-Za-z0-9._/-]+' "$dist_dir/index.html" | sort -u)

	js_path="$(find "$dist_dir/assets/app" -maxdepth 1 -name 'app.*.js' -print -quit)"
	wasm_path="$(find "$dist_dir/assets/app" -maxdepth 1 -name 'app.*.wasm' -print -quit)"
	[[ -n "$js_path" && -n "$wasm_path" ]] || {
		echo "The final JavaScript or WebAssembly artifact is missing." >&2
		exit 1
	}
	wasm_name="$(basename "$wasm_path")"
	grep -q "$wasm_name" "$js_path" || {
		echo "The JavaScript does not reference the published WebAssembly file." >&2
		exit 1
	}
	echo "dist/ validated successfully."
}

# ------------------------------------------------------------------------------
# Release action dispatch
# ------------------------------------------------------------------------------
case "$action" in
	package)
		package_dist "$@"
		;;
	sbom)
		generate_sboms "$@"
		;;
	finalize)
		finalize_metadata "$@"
		;;
	validate)
		validate_dist "$@"
		;;
	*)
		echo "Usage: $0 {package|sbom|finalize RELEASE_LOG RELEASE_ID|validate}" >&2
		exit 2
		;;
esac

# EOF

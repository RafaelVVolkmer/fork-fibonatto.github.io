#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Sergio Bonatto
# SPDX-License-Identifier: MIT

# ==============================================================================
# docker_test.sh — pre-build Docker definition and post-build image gates
#
# - Lints the Dockerfile and Compose model before any project image is built.
# - Applies project-specific OPA policies through Conftest.
# - Audits local images for vulnerabilities, hardening, waste, and structure.
# ==============================================================================

set -Eeuo pipefail

project_root="$(
	cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." > /dev/null 2>&1
	pwd
)"
readonly project_root
readonly dockerfile="$project_root/docker/Dockerfile"
readonly compose_file="$project_root/docker/compose.yml"
readonly analysis_dir="$project_root/static_analysis"
readonly docker_analysis_dir="$analysis_dir/docker"
readonly audit_cache="$project_root/.cache/container-audit"
readonly checkov_image="bridgecrew/checkov:3.3.8@sha256:c64ffb6d6fc8087c896341a2c697770a04a1cf558db04fa7b8129d8ca6bce336"

usage() {
	cat << 'EOF'
Usage:
  ./scripts/tests/docker_test.sh lint
  ./scripts/tests/docker_test.sh image <runtime|edge> <image>
  ./scripts/tests/docker_test.sh images [runtime-image] [edge-image]
  ./scripts/tests/docker_test.sh all [runtime-image] [edge-image]
EOF
}

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	return 1
}

pass() {
	printf 'PASS: %s\n' "$*"
}

require_command() {
	command -v "$1" > /dev/null 2>&1 \
		|| fail "missing required command: $1"
}

require_docker() {
	require_command docker
	docker info > /dev/null \
		|| fail "Docker daemon is unavailable"
}

lint_definitions() {
	require_docker
	require_command conftest
	require_command hadolint

	hadolint \
		--config "$docker_analysis_dir/hadolint.yml" \
		"$dockerfile"
	pass "Hadolint Dockerfile policy"

	docker buildx build \
		--check \
		--build-arg BUILDKIT_DOCKERFILE_CHECK=error=true \
		--file "$dockerfile" \
		"$project_root"
	pass "Docker Buildx checks"

	# Checkov cannot resolve digest-pinned FROM arguments (CKV_DOCKER_7), and
	# its blanket APT prohibition (CKV_DOCKER_9) applies only to the discarded
	# compiler stage. Conftest verifies the image arguments independently.
	docker run \
		--rm \
		--volume "$project_root:/workspace:ro" \
		--workdir /workspace \
		"$checkov_image" \
		--config-file static_analysis/docker/checkov.yml
	pass "Checkov Dockerfile policies"

	conftest test \
		--all-namespaces \
		--parser dockerfile \
		--policy "$docker_analysis_dir/policies/dockerfile" \
		"$dockerfile"
	conftest test \
		--all-namespaces \
		--parser yaml \
		--policy "$docker_analysis_dir/policies/compose" \
		"$compose_file"
	pass "Conftest OPA policies"
}

require_image_tools() {
	require_docker
	require_command container-structure-test
	require_command dive
	require_command dockle
	require_command grype
	require_command trivy
}

scan_vulnerabilities() {
	local image="$1"

	trivy image \
		--cache-dir "$audit_cache/trivy" \
		--scanners vuln,secret,misconfig \
		--severity HIGH,CRITICAL \
		--ignore-unfixed \
		--exit-code 1 \
		--no-progress \
		"$image"
	pass "Trivy vulnerability, secret, and misconfiguration scan"

	GRYPE_DB_CACHE_DIR="$audit_cache/grype/db" \
		grype "docker:$image" \
		--only-fixed \
		--fail-on high \
		--output table
	pass "Grype independent vulnerability scan"
}

scan_hardening() {
	local image="$1"

	# The upstream NGINX history names its public-key checksum KEY_SHA512.
	# Dockle otherwise misclassifies that non-secret digest as a credential.
	dockle \
		--accept-key KEY_SHA512 \
		--exit-code 1 \
		--exit-level warn \
		--no-color \
		--timeout 5m \
		"$image"
	pass "Dockle image hardening audit"

	dive \
		--ci \
		--ci-config "$docker_analysis_dir/dive-ci.yml" \
		--source docker \
		"$image"
	pass "Dive layer efficiency audit"
}

test_structure() {
	local target="$1"
	local image="$2"
	local config="$docker_analysis_dir/container-structure-$target.yml"

	container-structure-test test \
		--image "$image" \
		--config "$config" \
		--no-color
	pass "Container Structure Test ($target)"
}

audit_image() {
	local target="$1"
	local image="$2"

	[[ "$target" == runtime || "$target" == edge ]] \
		|| fail "unknown image target: $target"
	docker image inspect "$image" > /dev/null \
		|| fail "local image not found: $image"

	mkdir -p "$audit_cache"
	printf '\n==> Auditing %s image: %s\n' "$target" "$image"
	scan_vulnerabilities "$image"
	scan_hardening "$image"
	test_structure "$target" "$image"
}

audit_images() {
	local runtime_image="${1:-ehs-runtime:local}"
	local edge_image="${2:-ehs-edge:local}"

	require_image_tools
	audit_image runtime "$runtime_image"
	audit_image edge "$edge_image"
}

main() {
	local command="${1:-}"

	cd "$project_root"
	case "$command" in
		lint)
			[[ "$#" -eq 1 ]] || {
				usage >&2
				return 2
			}
			lint_definitions
			;;
		image)
			[[ "$#" -eq 3 ]] || {
				usage >&2
				return 2
			}
			require_image_tools
			audit_image "$2" "$3"
			;;
		images)
			[[ "$#" -le 3 ]] || {
				usage >&2
				return 2
			}
			audit_images "${2:-}" "${3:-}"
			;;
		all)
			[[ "$#" -le 3 ]] || {
				usage >&2
				return 2
			}
			lint_definitions
			audit_images "${2:-}" "${3:-}"
			;;
		*)
			usage >&2
			return 2
			;;
	esac
}

main "$@"

# EOF

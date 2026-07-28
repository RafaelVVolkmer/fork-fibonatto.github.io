#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Sergio Bonatto
# SPDX-License-Identifier: MIT

# ==============================================================================
# lint.sh — unified source and repository lint pipeline for EHS
#
# - Runs native system tools for shell, data, documentation and workflow checks.
# - Provides optional C formatting and static-analysis checks for explicit use.
# - Accepts "all" or one or more named checks and reports an aggregate result.
# - Reads policies from static_analysis/ without changing tools.
# ==============================================================================

# The runner intentionally omits errexit so independent checks continue after a
# failure. Each result is captured by run_check and reflected in the final status.
set -uo pipefail

# ------------------------------------------------------------------------------
# Repository root and static-analysis configuration directory
# ------------------------------------------------------------------------------
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
analysis_dir="$project_root/static_analysis"
cd "$project_root" || exit 1

# ------------------------------------------------------------------------------
# Public check names accepted by the command-line interface
# ------------------------------------------------------------------------------
available_checks=(
	shellcheck
	shell-format
	yamllint
	tomllint
	jsonlint
	markdownlint
	actionlint
	dockerfile
	lychee
	typos
	clang-format
	clang-tidy
	cppcheck
)

# ------------------------------------------------------------------------------
# Command-line helpers
# ------------------------------------------------------------------------------
usage() {
	echo "Usage: ./scripts/lint.sh [all|check ...]"
	echo
	echo "Checks:"
	printf '  %s\n' "${available_checks[@]}"
}

is_known_check() {
	local candidate="$1"
	local known

	for known in "${available_checks[@]}"; do
		[[ "$candidate" == "$known" ]] && return 0
	done
	return 1
}

# ------------------------------------------------------------------------------
# Help, list and selector processing
# ------------------------------------------------------------------------------
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
	usage
	exit 0
fi

if [[ "${1:-}" == "--list" ]]; then
	printf '%s\n' "${available_checks[@]}"
	exit 0
fi

requested_checks=("$@")
if [[ "${#requested_checks[@]}" -eq 0 || "${requested_checks[0]}" == "all" ]]; then
	if [[ "${#requested_checks[@]}" -gt 1 ]]; then
		echo "The all selector cannot be combined with individual checks." >&2
		exit 2
	fi
	requested_checks=("${available_checks[@]}")
fi

for check in "${requested_checks[@]}"; do
	is_known_check "$check" || {
		echo "Unknown lint check: $check" >&2
		usage >&2
		exit 2
	}
done

# ------------------------------------------------------------------------------
# Deterministic file inventories
# ------------------------------------------------------------------------------
mapfile -d '' shell_files < <(
	find scripts "$analysis_dir" docker -type f -name '*.sh' -print0 | sort -z
)
mapfile -d '' yaml_files < <(
	find .github "$analysis_dir" -type f \
		\( -name '*.yaml' -o -name '*.yml' \) -print0 | sort -z
)
mapfile -d '' toml_files < <(
	find "$analysis_dir" -type f -name '*.toml' -print0 | sort -z
)
mapfile -d '' json_files < <(
	find "$analysis_dir" -type f -name '*.json' -print0 | sort -z
)
mapfile -d '' workflow_files < <(
	find .github/workflows -type f \( -name '*.yaml' -o -name '*.yml' \) -print0 | sort -z
)
mapfile -d '' c_files < <(
	find core tests tools/packer -type f \( -name '*.c' -o -name '*.h' \) -print0 | sort -z
)
mapfile -d '' link_files < <(
	find README.md content "$analysis_dir" site -type f \
		\( -name '*.md' -o -name '*.html' -o -name '*.tmpl' \) \
		-print0 | sort -z
)

# ------------------------------------------------------------------------------
# Shell formatter policy
# ------------------------------------------------------------------------------
shfmt_flags=()
while IFS= read -r flag; do
	[[ -n "$flag" && "$flag" != \#* ]] && shfmt_flags+=("$flag")
done < "$analysis_dir/shell/shfmt.args"

# ------------------------------------------------------------------------------
# JSON parser policy
# ------------------------------------------------------------------------------
jq_flags=()
while IFS= read -r flag; do
	[[ -n "$flag" && "$flag" != \#* ]] && jq_flags+=("$flag")
done < "$analysis_dir/json/jq.args"

# ------------------------------------------------------------------------------
# Shell checks
# ------------------------------------------------------------------------------
check_shellcheck() {
	local severity

	severity="$(
		sed -n 's/^severity=//p' "$analysis_dir/shell/shellcheckrc"
	)"
	shellcheck \
		--severity="$severity" \
		--external-sources \
		--source-path=SCRIPTDIR \
		"${shell_files[@]}"
}

check_shell_format() {
	shfmt "${shfmt_flags[@]}" --diff "${shell_files[@]}"
}

# ------------------------------------------------------------------------------
# YAML, TOML and JSON checks
# ------------------------------------------------------------------------------
check_yaml() {
	yamllint \
		--strict \
		--config-file "$analysis_dir/yml/yamllint.yml" \
		"${yaml_files[@]}"
}

check_toml() {
	taplo lint \
		--config "$analysis_dir/toml/taplo.toml" \
		--no-auto-config \
		"${toml_files[@]}"
}

check_json() {
	local path

	for path in "${json_files[@]}"; do
		jq "${jq_flags[@]}" . "$path" > /dev/null
	done
}

# ------------------------------------------------------------------------------
# Documentation, workflow, link and spelling checks
# ------------------------------------------------------------------------------
check_markdown() {
	local legacy_rules

	legacy_rules="$(
		printf '%s' \
			'MD011,MD018,MD020,MD021,MD037,MD038,MD039,' \
			'MD042,MD045,MD051,MD053,MD061,MD062,MD066,MD068,MD069'
	)"

	rumdl check \
		--config "$analysis_dir/md/rumdl.toml" \
		README.md \
		static_analysis/README.md || return

	# Published posts retain their existing typography. Audit only rules that
	# detect malformed Markdown without mechanically rewriting article prose.
	rumdl check \
		--no-config \
		--enable "$legacy_rules" \
		content/posts
}

check_actions() {
	actionlint \
		-config-file "$analysis_dir/compliance/actionlint.yaml" \
		-shellcheck shellcheck \
		"${workflow_files[@]}"
}

check_dockerfile() {
	"$project_root/scripts/tests/docker_test.sh" lint
}

check_links() {
	lychee --config "$analysis_dir/md/lychee.toml" "${link_files[@]}"
}

check_typos() {
	typos \
		--config "$analysis_dir/compliance/typos.toml" \
		--isolated \
		--force-exclude \
		.
}

# ------------------------------------------------------------------------------
# Optional C formatting and static-analysis checks
# ------------------------------------------------------------------------------
check_clang_format() {
	clang-format \
		--dry-run \
		--Werror \
		--style="file:$analysis_dir/c/clang-format.yml" \
		"${c_files[@]}"
}

check_clang_tidy() {
	local compile_database="$project_root/compile_commands.json"
	local runtime_sources=(
		core/src/buffer.c
		core/src/config.c
		core/src/js_api.c
		core/src/main.c
		core/src/markdown.c
		core/src/math.c
		core/src/pages.c
		core/src/router.c
		core/src/ui.c
	)

	[[ -f "$compile_database" ]] || {
		echo "Missing compile_commands.json; run make compile-commands first." >&2
		return 1
	}

	# clang-tidy can use an older Clang driver than the pinned Emscripten
	# compiler. Keep the canonical WASM flags while ignoring only driver-version
	# differences in warning-option recognition during this secondary analysis.
	clang-tidy \
		--quiet \
		--config-file="$analysis_dir/c/clang-tidy.yml" \
		-p "$project_root" \
		--extra-arg=-Wno-unknown-warning-option \
		--extra-arg=-Wno-unused-command-line-argument \
		"${runtime_sources[@]}" || return

	clang-tidy \
		--quiet \
		--config-file="$analysis_dir/c/clang-tidy.yml" \
		core/src/heart.c \
		-- -std=c11 || return

	clang-tidy \
		--quiet \
		--config-file="$analysis_dir/c/clang-tidy.yml" \
		tools/packer/src/packer.c \
		-- -std=c11 -Itools/packer/inc
}

check_cppcheck() {
	cppcheck \
		--check-level=exhaustive \
		--enable=warning,performance,portability \
		--error-exitcode=1 \
		--inline-suppr \
		--language=c \
		--std=c11 \
		--suppress=missingIncludeSystem \
		--suppressions-list="$analysis_dir/c/cppcheck-suppressions.txt" \
		-I"$analysis_dir/c" \
		-Icore/inc \
		-I.build/generated \
		-Itools/packer/inc \
		core/src \
		tools/packer/src
}

# ------------------------------------------------------------------------------
# Aggregate-result counters and individual check execution
# ------------------------------------------------------------------------------
failures=0
passed=0

run_check() {
	local name="$1"
	local executable="$2"
	local function_name="$3"

	echo
	echo "==> $name"
	if ! command -v "$executable" > /dev/null 2>&1; then
		echo "FAIL: missing system tool: $executable" >&2
		failures=$((failures + 1))
		return
	fi

	if "$function_name"; then
		echo "PASS: $name"
		passed=$((passed + 1))
	else
		echo "FAIL: $name" >&2
		failures=$((failures + 1))
	fi
}

# ------------------------------------------------------------------------------
# Dispatch the requested checks
# ------------------------------------------------------------------------------
for check in "${requested_checks[@]}"; do
	case "$check" in
		shellcheck)
			run_check "$check" shellcheck check_shellcheck
			;;
		shell-format)
			run_check "$check" shfmt check_shell_format
			;;
		yamllint)
			run_check "$check" yamllint check_yaml
			;;
		tomllint)
			run_check "$check" taplo check_toml
			;;
		jsonlint)
			run_check "$check" jq check_json
			;;
		markdownlint)
			run_check "$check" rumdl check_markdown
			;;
		actionlint)
			run_check "$check" actionlint check_actions
			;;
		dockerfile)
			run_check "$check" docker check_dockerfile
			;;
		lychee)
			run_check "$check" lychee check_links
			;;
		typos)
			run_check "$check" typos check_typos
			;;
		clang-format)
			run_check "$check" clang-format check_clang_format
			;;
		clang-tidy)
			run_check "$check" clang-tidy check_clang_tidy
			;;
		cppcheck)
			run_check "$check" cppcheck check_cppcheck
			;;
	esac
done

# ------------------------------------------------------------------------------
# Final summary and process status
# ------------------------------------------------------------------------------
echo
echo "Lint summary: $passed passed, $failures failed."
[[ "$failures" -eq 0 ]]

# EOF

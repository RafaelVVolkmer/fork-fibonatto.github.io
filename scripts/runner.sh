#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Sergio Bonatto
# SPDX-License-Identifier: MIT

# ==============================================================================
# runner.sh — timestamped Make and release-test log dispatcher
#
# - Streams command output to the terminal while preserving the complete log.
# - Stores Make logs under logs/make-<goals>/ using UTC ISO-style timestamps.
# - Stores named test logs beneath the active release identifier.
# - Finalizes and validates release metadata after a successful make release.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Repository root and requested runner action
# ------------------------------------------------------------------------------
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
action="${1:-}"
shift || true

# ------------------------------------------------------------------------------
# Logged Make invocation
# ------------------------------------------------------------------------------
run_make() {
	local make_bin="${1:?Make executable was not provided}"
	local goal_name profile log_dir started filename_timestamp release_id
	local log_file temporary_log make_status tee_status completed
	local -a goals pipeline_status

	shift
	goals=("$@")
	if [[ "${#goals[@]}" -eq 0 ]]; then
		goals=(release)
	fi

	goal_name="$(
		IFS=-
		printf '%s' "${goals[*]}"
	)"
	profile="make-${goal_name//[^A-Za-z0-9._-]/-}"
	log_dir="$project_root/logs/$profile"
	started="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
	filename_timestamp="${started/T/-}"
	release_id="$filename_timestamp-$profile"
	log_file="$log_dir/$filename_timestamp-$profile.log"
	temporary_log="$(mktemp)"
	trap 'rm -f "$temporary_log"' EXIT

	command -v tee > /dev/null 2>&1 || {
		echo "Missing tool required for Make logging: tee" >&2
		exit 1
	}

	set +e
	{
		printf 'Command: make %s\n' "${goals[*]}"
		printf 'Profile: %s\n' "$profile"
		printf 'Started: %s\n\n' "$started"

		EHS_ACTIVE_LOG="$temporary_log" \
			EHS_LOGGED_MAKE=1 \
			EHS_LOG_PROFILE="$profile" \
			EHS_RELEASE_ID="$release_id" \
			"$make_bin" --no-print-directory \
			-C "$project_root" "${goals[@]}"
		make_status="$?"

		completed="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
		printf '\nCompleted: %s\n' "$completed"
		printf 'Exit status: %d\n' "$make_status"
		exit "$make_status"
	} 2>&1 | tee "$temporary_log"
	pipeline_status=("${PIPESTATUS[@]}")
	make_status="${pipeline_status[0]}"
	tee_status="${pipeline_status[1]}"
	set -e

	if [[ "$tee_status" -ne 0 ]]; then
		echo "Failed to capture the Make invocation log." >&2
		exit "$tee_status"
	fi

	mkdir -p "$log_dir"
	mv "$temporary_log" "$log_file"
	trap - EXIT

	if [[ "$make_status" -eq 0 && "$profile" == "make-release" ]]; then
		"$project_root/scripts/release.sh" finalize "$log_file" "$release_id"
		"$project_root/scripts/release.sh" validate
	fi

	printf 'Make log: %s\n' "${log_file#"$project_root/"}"
	exit "$make_status"
}

# ------------------------------------------------------------------------------
# Logged named test invocation
# ------------------------------------------------------------------------------
run_test() {
	local test_name="${1:?test name was not provided}"
	local profile release_id log_dir started filename_timestamp
	local log_file temporary_log test_status tee_status completed
	local -a pipeline_status

	shift
	[[ "$#" -gt 0 ]] || {
		echo "test command was not provided" >&2
		exit 2
	}

	profile="test-${test_name//[^A-Za-z0-9._-]/-}"
	release_id="${EHS_RELEASE_ID:-standalone}"
	log_dir="$project_root/logs/tests/$release_id/$profile"
	started="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
	filename_timestamp="${started/T/-}"
	log_file="$log_dir/$filename_timestamp-$profile.log"
	temporary_log="$(mktemp)"
	trap 'rm -f "$temporary_log"' EXIT

	set +e
	{
		printf 'Test: %s\n' "$test_name"
		printf 'Started: %s\n\n' "$started"
		"$@"
		test_status="$?"
		completed="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
		printf '\nCompleted: %s\n' "$completed"
		printf 'Exit status: %d\n' "$test_status"
		exit "$test_status"
	} 2>&1 | tee "$temporary_log"
	pipeline_status=("${PIPESTATUS[@]}")
	test_status="${pipeline_status[0]}"
	tee_status="${pipeline_status[1]}"
	set -e

	[[ "$tee_status" -eq 0 ]] || {
		echo "Failed to capture the test log." >&2
		exit "$tee_status"
	}

	mkdir -p "$log_dir"
	mv "$temporary_log" "$log_file"
	trap - EXIT

	printf 'Test log: %s\n' "${log_file#"$project_root/"}"
	exit "$test_status"
}

# ------------------------------------------------------------------------------
# Runner action dispatch
# ------------------------------------------------------------------------------
case "$action" in
	make)
		run_make "$@"
		;;
	test)
		run_test "$@"
		;;
	*)
		echo "Usage: $0 {make MAKE [GOAL...]|test NAME COMMAND [ARG...]}" >&2
		exit 2
		;;
esac

# EOF

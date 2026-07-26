#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Sergio Bonatto
# SPDX-License-Identifier: MIT

# ==============================================================================
# test_con.sh — bounded local container connectivity and resilience suite
#
# - Builds an isolated Compose stack bound only to 127.0.0.1:8080 and :8443.
# - Verifies HTTP redirects, HTTP/2, TLS 1.3, security policy, and artifact links.
# - Measures and enforces P90/P99 latency for both published ports.
# - Exercises malformed inputs, rate limiting, load balancing, and failover.
# ==============================================================================

set -Eeuo pipefail

# ------------------------------------------------------------------------------
# Absolute paths, isolated Compose identity, and configurable test limits
# ------------------------------------------------------------------------------
project_root="$(
	cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." > /dev/null 2>&1
	pwd
)"
readonly project_root
readonly compose_file="$project_root/docker/compose.yml"
readonly project_name="ehs-connection-test-$$"
readonly http_origin="http://127.0.0.1:8080"
readonly https_origin="https://127.0.0.1:8443"
temporary_directory="$(mktemp -d)"
readonly temporary_directory

requests="${EHS_TEST_REQUESTS:-120}"
concurrency="${EHS_TEST_CONCURRENCY:-12}"
latency_samples="${EHS_TEST_LATENCY_SAMPLES:-100}"
p90_limit_ms="${EHS_TEST_P90_MS:-250}"
p99_limit_ms="${EHS_TEST_P99_MS:-500}"
keep_stack="${EHS_TEST_KEEP_STACK:-0}"
skip_build="${EHS_TEST_SKIP_BUILD:-0}"

# ------------------------------------------------------------------------------
# Compose lifecycle and unconditional cleanup
# ------------------------------------------------------------------------------
compose() {
	docker compose \
		--project-name "$project_name" \
		--file "$compose_file" \
		"$@"
}

cleanup() {
	status=$?
	trap - EXIT HUP INT TERM

	if [[ "$keep_stack" == 1 ]]; then
		printf 'Stack preserved for inspection: project %s\n' "$project_name" >&2
	else
		compose down --volumes --remove-orphans > /dev/null 2>&1 || true
	fi

	rm -rf -- "$temporary_directory"
	exit "$status"
}

trap cleanup EXIT HUP INT TERM

# ------------------------------------------------------------------------------
# Assertions, command checks, and bounded HTTP helpers
# ------------------------------------------------------------------------------
fail() {
	printf 'FAIL: %s\n' "$*" >&2
	return 1
}

pass() {
	printf 'PASS: %s\n' "$*"
}

require_command() {
	command -v "$1" > /dev/null 2>&1 || fail "missing required command: $1"
}

require_integer_in_range() {
	name=$1
	value=$2
	minimum=$3
	maximum=$4

	[[ "$value" =~ ^[0-9]+$ ]] \
		|| fail "$name must be an integer"
	((value >= minimum && value <= maximum)) \
		|| fail "$name must be between $minimum and $maximum"
}

curl_local() {
	curl \
		--silent \
		--show-error \
		--insecure \
		--connect-timeout 3 \
		--max-time 10 \
		"$@"
}

http_status() {
	output=$1
	shift
	curl_local --output "$output" --write-out '%{http_code}' "$@"
}

assert_status() {
	expected=$1
	url=$2
	output="$temporary_directory/response-body"
	actual="$(http_status "$output" "$url")"
	[[ "$actual" == "$expected" ]] \
		|| fail "$url returned $actual; expected $expected"
}

wait_for_url() {
	url=$1
	attempt=0

	while ((attempt < 60)); do
		if [[ "$(http_status "$temporary_directory/wait-body" "$url" 2> /dev/null || true)" == 200 ]] \
			&& grep -qx 'ok' "$temporary_directory/wait-body"; then
			return 0
		fi
		attempt=$((attempt + 1))
		sleep 1
	done

	fail "timed out waiting for $url"
}

wait_for_container_health() {
	container=$1
	attempt=0

	while ((attempt < 30)); do
		if [[ "$(docker inspect --format '{{.State.Health.Status}}' "$container" 2> /dev/null || true)" == healthy ]]; then
			return 0
		fi
		attempt=$((attempt + 1))
		sleep 1
	done

	fail "container did not become healthy: $container"
}

# ------------------------------------------------------------------------------
# Container runtime hardening assertions
# ------------------------------------------------------------------------------
assert_hardened_container() {
	container=$1
	service=$2

	[[ "$(docker inspect --format '{{.Config.User}}' "$container")" == 101:101 ]] \
		|| fail "$service does not run as UID/GID 101:101"
	[[ "$(docker inspect --format '{{.HostConfig.ReadonlyRootfs}}' "$container")" == true ]] \
		|| fail "$service root filesystem is writable"
	docker inspect --format '{{json .HostConfig.CapDrop}}' "$container" \
		| grep -q '"ALL"' \
		|| fail "$service does not drop every Linux capability"
	docker inspect --format '{{json .HostConfig.SecurityOpt}}' "$container" \
		| grep -q 'no-new-privileges:true' \
		|| fail "$service lacks no-new-privileges"
}

# ------------------------------------------------------------------------------
# Prerequisite validation and stack startup
# ------------------------------------------------------------------------------
run_prerequisites() {
	require_command awk
	require_command curl
	require_command docker
	require_command git
	require_command grep
	require_command openssl

	docker compose version > /dev/null
	docker info > /dev/null
	curl --version | grep -q 'HTTP2' \
		|| fail "the local curl build lacks HTTP/2 support"

	require_integer_in_range EHS_TEST_REQUESTS "$requests" 40 1000
	require_integer_in_range EHS_TEST_CONCURRENCY "$concurrency" 2 64
	require_integer_in_range EHS_TEST_LATENCY_SAMPLES "$latency_samples" 20 500
	require_integer_in_range EHS_TEST_P90_MS "$p90_limit_ms" 1 10000
	require_integer_in_range EHS_TEST_P99_MS "$p99_limit_ms" 1 10000
	((p99_limit_ms >= p90_limit_ms)) \
		|| fail "EHS_TEST_P99_MS must be greater than or equal to EHS_TEST_P90_MS"
	[[ "$keep_stack" == 0 || "$keep_stack" == 1 ]] \
		|| fail "EHS_TEST_KEEP_STACK must be 0 or 1"
	[[ "$skip_build" == 0 || "$skip_build" == 1 ]] \
		|| fail "EHS_TEST_SKIP_BUILD must be 0 or 1"

	pass "local-only test prerequisites"
}

start_stack() {
	cd "$project_root"

	export VERSION
	export VCS_REF
	export BUILD_DATE
	VERSION="$(git describe --tags --always --dirty 2> /dev/null || printf '0.0.0-local')"
	VCS_REF="$(git rev-parse HEAD 2> /dev/null || printf 'unknown')"
	BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

	if [[ "$skip_build" == 0 ]]; then
		compose build --pull
	fi

	compose up --detach --no-build
	wait_for_url "$https_origin/healthz"

	app_a="$(compose ps --quiet app-a)"
	app_b="$(compose ps --quiet app-b)"
	edge="$(compose ps --quiet edge)"

	[[ -n "$app_a" && -n "$app_b" && -n "$edge" ]] \
		|| fail "Compose did not create all three long-running services"

	wait_for_container_health "$app_a"
	wait_for_container_health "$app_b"
	wait_for_container_health "$edge"
	pass "Compose build, startup, and container health checks"
}

# ------------------------------------------------------------------------------
# Published-port protocol and latency tests
# ------------------------------------------------------------------------------
test_ports_and_protocols() {
	printf 'ok\n' > "$temporary_directory/expected-health"

	assert_status 200 "$http_origin/healthz"
	cmp "$temporary_directory/expected-health" "$temporary_directory/response-body" > /dev/null \
		|| fail "HTTP health endpoint returned an unexpected body"

	redirect_status="$(
		curl_local \
			--output /dev/null \
			--write-out '%{http_code}' \
			"$http_origin/"
	)"
	[[ "$redirect_status" == 308 ]] \
		|| fail "plain HTTP root returned $redirect_status; expected 308"

	location="$(
		curl_local \
			--head \
			"$http_origin/" \
			| awk 'BEGIN { IGNORECASE=1 } /^Location:/ { sub(/\r$/, ""); print $2 }'
	)"
	[[ "$location" == "$https_origin/" ]] \
		|| fail "unexpected HTTPS redirect location: $location"

	assert_status 200 "$https_origin/healthz"
	cmp "$temporary_directory/expected-health" "$temporary_directory/response-body" > /dev/null \
		|| fail "HTTPS health endpoint returned an unexpected body"
	assert_status 200 "$https_origin/"

	http_version="$(
		curl_local \
			--http2 \
			--output /dev/null \
			--write-out '%{http_version}' \
			"$https_origin/"
	)"
	[[ "$http_version" == 2 || "$http_version" == 2.0 ]] \
		|| fail "HTTPS endpoint negotiated HTTP/$http_version instead of HTTP/2"

	openssl s_client \
		-connect 127.0.0.1:8443 \
		-servername localhost \
		-tls1_3 \
		< /dev/null 2>&1 \
		| grep -q 'TLSv1.3' \
		|| fail "TLS 1.3 negotiation failed"

	pass "ports 8080/8443, redirect, health body, HTTP/2, and TLS 1.3"
}

measure_port_latency() {
	label=$1
	url=$2
	samples_file="$temporary_directory/latency-$label"

	for ((index = 1; index <= latency_samples; index++)); do
		measurement="$(
			curl_local \
				--output /dev/null \
				--write-out '%{http_code} %{time_total}' \
				"$url"
		)"
		read -r code seconds <<< "$measurement"
		[[ "$code" == 200 ]] \
			|| fail "$label latency sample returned HTTP $code"
		awk -v seconds="$seconds" 'BEGIN { printf "%.3f\n", seconds * 1000 }' \
			>> "$samples_file"
	done

	LC_ALL=C sort -n "$samples_file" -o "$samples_file"
	p90_index=$(((latency_samples * 90 + 99) / 100))
	p99_index=$(((latency_samples * 99 + 99) / 100))
	p90_ms="$(sed -n "${p90_index}p" "$samples_file")"
	p99_ms="$(sed -n "${p99_index}p" "$samples_file")"

	awk -v actual="$p90_ms" -v limit="$p90_limit_ms" \
		'BEGIN { exit !(actual <= limit) }' \
		|| fail "$label P90 ${p90_ms}ms exceeds ${p90_limit_ms}ms"
	awk -v actual="$p99_ms" -v limit="$p99_limit_ms" \
		'BEGIN { exit !(actual <= limit) }' \
		|| fail "$label P99 ${p99_ms}ms exceeds ${p99_limit_ms}ms"

	pass "$label latency P90=${p90_ms}ms P99=${p99_ms}ms ($latency_samples samples)"
}

test_port_latency_percentiles() {
	measure_port_latency port-8080 "$http_origin/healthz"
	measure_port_latency port-8443 "$https_origin/healthz"
}

# ------------------------------------------------------------------------------
# Headers, methods, ownership, and deployable artifact connections
# ------------------------------------------------------------------------------
test_security_headers_and_methods() {
	headers="$temporary_directory/headers"
	curl_local --dump-header "$headers" --output /dev/null "$https_origin/"

	grep -Eiq '^Strict-Transport-Security:[[:space:]]*max-age=31536000' "$headers" \
		|| fail "HSTS header missing"
	grep -Eiq '^Content-Security-Policy:' "$headers" \
		|| fail "Content-Security-Policy header missing"
	grep -Eiq '^X-Content-Type-Options:[[:space:]]*nosniff' "$headers" \
		|| fail "X-Content-Type-Options header missing"
	grep -Eiq '^X-Frame-Options:[[:space:]]*DENY' "$headers" \
		|| fail "X-Frame-Options header missing"
	grep -Eiq '^Permissions-Policy:' "$headers" \
		|| fail "Permissions-Policy header missing"

	for method in POST PUT PATCH DELETE TRACE OPTIONS; do
		code="$(
			curl_local \
				--request "$method" \
				--output /dev/null \
				--write-out '%{http_code}' \
				"$https_origin/"
		)"
		[[ "$code" == 403 || "$code" == 405 ]] \
			|| fail "$method returned $code; expected a 403/405 rejection"
	done

	hidden_code="$(
		curl_local \
			--path-as-is \
			--output "$temporary_directory/hidden-body" \
			--write-out '%{http_code}' \
			"$https_origin/.git/config"
	)"
	[[ "$hidden_code" == 403 || "$hidden_code" == 404 ]] \
		|| fail "dotfile probe returned unexpected status $hidden_code"

	app_a_bindings="$(docker inspect --format '{{json .HostConfig.PortBindings}}' "$app_a")"
	app_b_bindings="$(docker inspect --format '{{json .HostConfig.PortBindings}}' "$app_b")"
	edge_bindings="$(docker inspect --format '{{json .HostConfig.PortBindings}}' "$edge")"
	[[ "$app_a_bindings" == '{}' || "$app_a_bindings" == null ]] \
		|| fail "app-a unexpectedly publishes a backend port: $app_a_bindings"
	[[ "$app_b_bindings" == '{}' || "$app_b_bindings" == null ]] \
		|| fail "app-b unexpectedly publishes a backend port: $app_b_bindings"
	grep -Fq '"8080/tcp":[{"HostIp":"127.0.0.1","HostPort":"8080"' <<< "$edge_bindings" \
		|| fail "edge port 8080 is not bound exclusively to loopback"
	grep -Fq '"8443/tcp":[{"HostIp":"127.0.0.1","HostPort":"8443"' <<< "$edge_bindings" \
		|| fail "edge port 8443 is not bound exclusively to loopback"

	assert_hardened_container "$app_a" app-a
	assert_hardened_container "$app_b" app-b
	assert_hardened_container "$edge" edge

	for container in "$app_a" "$app_b"; do
		docker exec "$container" sh -eu -c '
			find /usr/share/nginx/html -type d -exec stat -c "%u:%g %a" {} \; |
				while read -r owner mode; do
					test "$owner" = "0:0" && test "$mode" = "555"
				done
			find /usr/share/nginx/html -type f -exec stat -c "%u:%g %a" {} \; |
				while read -r owner mode; do
					test "$owner" = "0:0" && test "$mode" = "444"
				done
		' || fail "static files are not immutable root:root content"
	done

	pass "headers, methods, port isolation, hardening, and immutable root-owned content"
}

test_content_artifacts() {
	index="$temporary_directory/index.html"
	assert_status 200 "$https_origin/"
	cp "$temporary_directory/response-body" "$index"

	js_path="$(
		grep -Eo 'assets/app/app\.[0-9a-f]{8,64}\.js' "$index" \
			| head -n 1
	)"
	[[ -n "$js_path" ]] || fail "index.html does not name a hashed JavaScript artifact"
	assert_status 200 "$https_origin/$js_path"

	wasm_name="$(
		grep -Eo 'app\.[0-9a-f]{8,64}\.wasm' "$temporary_directory/response-body" \
			| head -n 1
	)"
	[[ -n "$wasm_name" ]] || fail "JavaScript does not name a hashed WebAssembly artifact"
	assert_status 200 "$https_origin/assets/app/$wasm_name"

	pass "content-addressed HTML, JavaScript, and WebAssembly connections"
}

# ------------------------------------------------------------------------------
# Injection and malformed-request corpora
# ------------------------------------------------------------------------------
test_sql_injection_resistance() {
	readonly sql_error_pattern='SQL syntax|SQLSTATE|sqlite|postgres|mysql|ORA-[0-9]+|database error'
	payloads=(
		"' OR '1'='1"
		"1 UNION SELECT NULL--"
		"'; DROP TABLE posts;--"
		"1 AND SLEEP(5)"
		"1; WAITFOR DELAY '00:00:05'--"
		"\${jndi:ldap://127.0.0.1/a}"
	)

	for payload in "${payloads[@]}"; do
		code="$(
			curl_local \
				--get \
				--data-urlencode "q=$payload" \
				--output "$temporary_directory/injection-body" \
				--write-out '%{http_code}' \
				"$https_origin/"
		)"
		[[ "$code" != 000 && "$code" != 5?? ]] \
			|| fail "injection corpus caused HTTP $code"
		if grep -Eiq "$sql_error_pattern" "$temporary_directory/injection-body"; then
			fail "injection corpus exposed a database-style error"
		fi
	done

	wait_for_url "$https_origin/healthz"
	pass "static endpoint rejects SQL-style effects and leaks no database errors"
}

test_http_fuzz_corpus() {
	paths=(
		'/%00'
		'/%2e%2e/%2e%2e/etc/passwd'
		'/..%2f..%2fetc%2fpasswd'
		'/%252e%252e/%252e%252e/etc/passwd'
		'//etc/passwd'
		'/assets/app/../../../../etc/passwd'
		'/.metadata/../.git/config'
		'/nonexistent?x=%ff%fe'
		'/<script>alert(1)</script>'
		'/?q=%0d%0aX-Fuzz:true'
	)

	for path in "${paths[@]}"; do
		code="$(
			curl_local \
				--path-as-is \
				--output "$temporary_directory/fuzz-body" \
				--write-out '%{http_code}' \
				"$https_origin$path" || true
		)"
		[[ "$code" != 000 && "$code" != 5?? ]] \
			|| fail "HTTP fuzz corpus caused status ${code:-000} for $path"
		if grep -q 'root:.*:0:0:' "$temporary_directory/fuzz-body"; then
			fail "path fuzzing exposed passwd-like content"
		fi
	done

	long_header="$(printf '%020000d' 0)"
	code="$(
		curl_local \
			--http1.1 \
			--header "X-Fuzz: $long_header" \
			--output /dev/null \
			--write-out '%{http_code}' \
			"$https_origin/" || true
	)"
	[[ "$code" == 400 || "$code" == 431 ]] \
		|| fail "oversized header returned ${code:-000}; expected 400 or 431"

	wait_for_url "$https_origin/healthz"
	pass "bounded path, encoding, traversal, request-line, and header fuzz corpus"
}

# ------------------------------------------------------------------------------
# Load distribution, backend failure, and bounded stress tests
# ------------------------------------------------------------------------------
test_load_balancing() {
	token="lb_probe_$$"
	sleep 4

	for index in $(seq 1 24); do
		code="$(
			curl_local \
				--output /dev/null \
				--write-out '%{http_code}' \
				"$https_origin/?${token}=$index"
		)"
		[[ "$code" == 200 ]] \
			|| fail "load-balancing probe returned HTTP $code"
		sleep 0.12
	done

	count_a="$(docker logs "$app_a" 2>&1 | grep -c "$token" || true)"
	count_b="$(docker logs "$app_b" 2>&1 | grep -c "$token" || true)"
	((count_a > 0 && count_b > 0)) \
		|| fail "traffic did not reach both backends (app-a=$count_a, app-b=$count_b)"

	pass "least-connections balancing reached app-a=$count_a and app-b=$count_b"
}

test_backend_failover() {
	compose stop app-a > /dev/null
	assert_status 200 "$https_origin/?failover=app-a-down-$$"
	compose start app-a > /dev/null
	wait_for_container_health "$app_a"

	compose stop app-b > /dev/null
	assert_status 200 "$https_origin/?failover=app-b-down-$$"
	compose start app-b > /dev/null
	wait_for_container_health "$app_b"

	wait_for_url "$https_origin/healthz"
	pass "controlled backend teardown, retry, and recovery"
}

test_bounded_stress_and_rate_limit() {
	status_directory="$temporary_directory/stress"
	mkdir -p "$status_directory"

	for ((index = 1; index <= requests; index++)); do
		(
			code="$(
				curl_local \
					--max-time 15 \
					--output /dev/null \
					--write-out '%{http_code}' \
					"$https_origin/?stress=$$-$index" || printf '000'
			)"
			printf '%s\n' "$code" > "$status_directory/$index"
		) &

		if ((index % concurrency == 0)); then
			wait
		fi
	done
	wait

	successes="$(grep -c '^200$' "$status_directory"/* || true)"
	limited="$(grep -c '^429$' "$status_directory"/* || true)"
	failures="$(grep -Evc '^(200|429)$' "$status_directory"/* || true)"

	# grep reports one count per file when given multiple files; sum those counts.
	successes="$(printf '%s\n' "$successes" | awk -F: '{ sum += $NF } END { print sum + 0 }')"
	limited="$(printf '%s\n' "$limited" | awk -F: '{ sum += $NF } END { print sum + 0 }')"
	failures="$(printf '%s\n' "$failures" | awk -F: '{ sum += $NF } END { print sum + 0 }')"

	((failures == 0)) \
		|| fail "bounded stress produced $failures transport/HTTP failures"
	((successes > 0)) \
		|| fail "bounded stress produced no successful response"
	((limited > 0)) \
		|| fail "rate limiter did not return HTTP 429 during the local burst"

	wait_for_url "$https_origin/healthz"
	pass "local stress/DDoS simulation ($requests requests, concurrency $concurrency; 200=$successes, 429=$limited)"
}

# ------------------------------------------------------------------------------
# Ordered suite execution
# ------------------------------------------------------------------------------
main() {
	printf '%s\n' \
		'Running a bounded integration/security test against local ports only:' \
		"  $http_origin" \
		"  $https_origin"

	run_prerequisites
	start_stack
	test_ports_and_protocols
	test_port_latency_percentiles
	test_security_headers_and_methods
	test_content_artifacts
	test_sql_injection_resistance
	test_http_fuzz_corpus
	test_load_balancing
	test_backend_failover
	test_bounded_stress_and_rate_limit

	compose ps
	printf 'All local connection and resilience tests passed.\n'
}

main "$@"

# EOF

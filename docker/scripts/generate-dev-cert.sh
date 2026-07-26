#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Sergio Bonatto
# SPDX-License-Identifier: MIT

# ==============================================================================
# generate-dev-cert.sh — one-shot local TLS certificate materializer
#
# - Reuses an existing certificate/key pair when both files are non-empty.
# - Generates a 30-day localhost certificate with DNS and loopback IP SANs.
# - Publishes staged files atomically with least-privilege ownership and modes.
# - Runs only in the disposable certgen image; Bash never enters the runtime.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Fixed certificate volume paths
# ------------------------------------------------------------------------------
certificate=/certs/tls.crt
private_key=/certs/tls.key
certificate_staging=/certs/.tls.crt.tmp
private_key_staging=/certs/.tls.key.tmp

# ------------------------------------------------------------------------------
# Existing certificate short-circuit
# ------------------------------------------------------------------------------
if [ -s "$certificate" ] && [ -s "$private_key" ]; then
	echo "Reusing the existing local TLS certificate."
	exit 0
fi

temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM

# ------------------------------------------------------------------------------
# Temporary key and self-signed certificate generation
# ------------------------------------------------------------------------------
if ! openssl req \
	-x509 \
	-newkey rsa:3072 \
	-sha256 \
	-days 30 \
	-nodes \
	-subj '/CN=localhost' \
	-addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' \
	-keyout "$temporary_directory/tls.key" \
	-out "$temporary_directory/tls.crt" \
	2> "$temporary_directory/openssl.log"; then
	cat "$temporary_directory/openssl.log" >&2
	exit 1
fi

# ------------------------------------------------------------------------------
# Atomic publication and runtime-readable permissions
# ------------------------------------------------------------------------------
rm -f "$certificate_staging" "$private_key_staging"
cp "$temporary_directory/tls.key" "$private_key_staging"
cp "$temporary_directory/tls.crt" "$certificate_staging"
chmod 0400 "$private_key_staging"
chmod 0444 "$certificate_staging"
chown 101:101 "$private_key_staging" "$certificate_staging"
mv -f "$private_key_staging" "$private_key"
mv -f "$certificate_staging" "$certificate"

echo "Generated a 30-day development certificate for localhost."

# EOF

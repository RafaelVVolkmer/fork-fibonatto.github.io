# syntax=docker/dockerfile:1.8

# SPDX-FileCopyrightText: 2026 Sergio Bonatto
# SPDX-License-Identifier: MIT

# Multi-architecture manifest digests observed for the pinned releases. Override
# these arguments deliberately when updating a base image.
ARG EMSDK_IMAGE="emscripten/emsdk:6.0.4@sha256:3a0d11e50f072dc2c4bc92e3b05ab1340fb7d4dd152f80b8af35fc1c6f15e644"
ARG ALPINE_IMAGE="alpine:3.23@sha256:fd791d74b68913cbb027c6546007b3f0d3bc45125f797758156952bc2d6daf40"
ARG NGINX_IMAGE="nginxinc/nginx-unprivileged:1.30.4-alpine-slim@sha256:e88d990b349df8cf4aa82f16642d7a23375016638c9ace4e5c6ca25028e62e65"

# ==============================================================================
# 1. Compile the current Make-based release artifact
# ==============================================================================

FROM --platform=$BUILDPLATFORM ${EMSDK_IMAGE} AS build

USER root
WORKDIR /workspace

ENV DEBIAN_FRONTEND=noninteractive
ENV EM_CACHE=/workspace/.cache/emscripten

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
	--mount=type=cache,target=/var/lib/apt,sharing=locked \
	apt-get update \
	&& apt-get install --yes --no-install-recommends \
		brotli \
		build-essential \
		ca-certificates \
		libdigest-sha-perl \
		wabt

COPY --link docker/terser/package.json docker/terser/package-lock.json /opt/terser/
RUN --mount=type=cache,target=/root/.npm,sharing=locked \
	npm ci \
		--prefix /opt/terser \
		--omit=dev \
		--no-audit \
		--no-fund
ENV PATH="/opt/terser/node_modules/.bin:${PATH}"

COPY --link . .

# Exercise the host-side content packer under ASan and UBSan before using it.
RUN cc \
		-std=c17 \
		-O1 \
		-g \
		-Wall \
		-Wextra \
		-Wpedantic \
		-Wconversion \
		-Wshadow \
		-Wformat=2 \
		-fsanitize=address,undefined \
		-fno-omit-frame-pointer \
		-fstack-protector-strong \
		-fno-common \
		-D_FORTIFY_SOURCE=2 \
		-Itools/packer/inc \
		tools/packer/src/packer.c \
		-o /tmp/packer-test \
	&& ASAN_OPTIONS="detect_leaks=1:halt_on_error=1" \
		UBSAN_OPTIONS="halt_on_error=1:print_stacktrace=1" \
		/tmp/packer-test content/posts > /dev/null

RUN --mount=type=cache,target=/workspace/.cache/emscripten,sharing=locked \
	make build \
		EMCC=emcc \
		WASM_OPT=/emsdk/upstream/bin/wasm-opt \
		BROTLI=brotli \
		TERSER=terser

# ==============================================================================
# 2. Validate and normalize the bytes that enter runtime images
# ==============================================================================

FROM build AS artifact-test

RUN ./docker/scripts/test-artifacts.sh \
	&& test -d /verified \
	&& test -z "$(find /verified -type l -print -quit)" \
	&& find /verified -type d -exec chmod 0555 {} + \
	&& find /verified -type f -exec chmod 0444 {} +

# ==============================================================================
# 3. Build the dependency-free HTTP health probe
# ==============================================================================

FROM ${ALPINE_IMAGE} AS healthcheck-build

RUN --mount=type=cache,target=/var/cache/apk,sharing=locked \
	apk add build-base

COPY --link docker/scripts/healthcheck.c /tmp/ehs-healthcheck.c

RUN cc \
		-std=c17 \
		-Os \
		-static \
		-Wall \
		-Wextra \
		-Wpedantic \
		-Werror \
		-fstack-protector-strong \
		-fno-common \
		-D_FORTIFY_SOURCE=2 \
		/tmp/ehs-healthcheck.c \
		-Wl,-s \
		-o /healthcheck

# ==============================================================================
# 4. One-shot local TLS certificate generator
#
# This precedes runtime so a target-less docker build never produces certgen.
# ==============================================================================

FROM ${ALPINE_IMAGE} AS certgen

RUN --mount=type=cache,target=/var/cache/apk,sharing=locked \
	apk add bash openssl

COPY --link --chmod=0555 \
	docker/scripts/generate-dev-cert.sh \
	/usr/local/bin/generate-dev-cert

ENTRYPOINT ["/usr/local/bin/generate-dev-cert"]

# ==============================================================================
# 5. Common unprivileged NGINX base
# ==============================================================================

FROM ${NGINX_IMAGE} AS nginx-common

ARG BUILD_DATE="unknown"
ARG VCS_REF="unknown"
ARG VERSION="0.0.0"

LABEL org.opencontainers.image.title="EHS" \
	org.opencontainers.image.description="Executable Hypermedia System" \
	org.opencontainers.image.source="https://github.com/RafaelVVolkmer/fork-fibonatto.github.io" \
	org.opencontainers.image.licenses="MIT" \
	org.opencontainers.image.version="${VERSION}" \
	org.opencontainers.image.revision="${VCS_REF}" \
	org.opencontainers.image.created="${BUILD_DATE}"

COPY --from=healthcheck-build --chmod=0555 /healthcheck /usr/local/bin/healthcheck

USER 101:101

HEALTHCHECK \
	--interval=30s \
	--timeout=3s \
	--start-period=5s \
	--retries=3 \
	CMD ["/usr/local/bin/healthcheck"]

STOPSIGNAL SIGQUIT

# Intentional upstream-entrypoint replacement: this image has immutable
# configuration and does not execute envsubst or dynamic entrypoint hooks.
ENTRYPOINT ["/usr/sbin/nginx"]

# ==============================================================================
# 6. TLS reverse proxy and load-balancing edge
# ==============================================================================

FROM nginx-common AS edge

COPY --link --chmod=0444 docker/nginx.edge.conf /etc/nginx/nginx.conf

EXPOSE 8080 8443
CMD ["-c", "/etc/nginx/nginx.conf", "-e", "/dev/stderr", "-g", "daemon off;"]

# ==============================================================================
# 7. Non-root static application runtime
#
# This stage is deliberately last and is therefore docker build's default.
# ==============================================================================

FROM nginx-common AS runtime

USER root
RUN rm -rf /usr/share/nginx/html \
	&& mkdir -p /usr/share/nginx/html \
	&& chown 0:0 /usr/share/nginx/html \
	&& chmod 0555 /usr/share/nginx/html

COPY --link --chmod=0444 docker/nginx.runtime.conf /etc/nginx/nginx.conf
COPY --from=artifact-test /verified/ /usr/share/nginx/html/

USER 101:101

EXPOSE 8080
CMD ["-c", "/etc/nginx/nginx.conf", "-e", "/dev/stderr", "-g", "daemon off;"]

# EOF

# SPDX-FileCopyrightText: 2026 Sergio Bonatto
# SPDX-License-Identifier: MIT

# -----------------------------------------------------------------------------
# 6. Public targets
# -----------------------------------------------------------------------------

.PHONY: \
	all \
	audit \
	audit-sources \
	brotli \
	build \
	cache-clean \
	check-compile-tools \
	check-tools \
	clean \
	compile-commands \
	debug \
	dist-clean \
	distclean \
	help \
	hash-names \
	lint \
	logs-clean \
	packer \
	release \
	reproducible \
	sbom \
	sdk \
	sdk-clean \
	test-con \
	test-binary \
	test-linters \
	test-release \
	test-sanitizers \
	tests \
	update-sources \
	validate \
	_clean \
	_release

all: release

# A release is always produced from a clean tree of generated artifacts.
ifeq ($(PACKER_REQUESTED),)
release:
	@$(MAKE) --no-print-directory _clean
	@if [[ "$(RUN_LINT)" == "1" ]]; then \
		echo "[1/5] Lint"; \
		$(MAKE) --no-print-directory test-linters; \
	else \
		echo "[1/5] Lint already satisfied by the CI dependency gate"; \
	fi
	@echo "[2/5] Sanitizer build and native execution"
	@$(MAKE) --no-print-directory test-sanitizers
	@echo "[3/5] Compilation and packaging"
	@$(MAKE) --no-print-directory _release
	@echo "[4/5] Artifact and reproducibility tests"
	@$(MAKE) --no-print-directory test-release
	@echo "[5/5] Container connection and resilience tests"
	@$(MAKE) --no-print-directory test-con
	@echo "Release pipeline completed successfully."
else
release:
	@:
endif

ifneq ($(PACKER_REQUESTED),)
debug:
	@:
else
debug: $(DEBUG_WASM_STAMP)
	@echo "Debug WebAssembly build completed in $(DEBUG_DIR)/"
endif

packer:
	@$(MAKE) --no-print-directory -C "$(PACKER_DIR)" "$(PACKER_MODE)" \
		BUILD_DIR="$(PACKER_BUILD_DIR)" \
		CC="$(HOST_CC)"

# Incremental release build for development.
build: _release

_release: check-tools sbom
	@./scripts/release.sh validate-package
	@echo "Release completed in $(DIST_DIR)/"

audit: check-tools $(SOURCE_AUDIT_STAMP) $(AUDIT_STAMP)
	@echo "Audit completed: $(AUDIT_DIR)/release-flags.txt"

audit-sources: $(SOURCE_AUDIT_STAMP)
	@echo "C/H integrity verified against $(SOURCE_MANIFEST)"

update-sources:
	@./$(SOURCE_MANIFEST_TOOL) generate "$(SOURCE_MANIFEST)"

validate: build

lint:
	@$(MAKE) --no-print-directory compile-commands
	@./scripts/lint.sh

sdk:
	@EMSDK_VERSION="$(EMSDK_VERSION)" ./scripts/toolchain.sh ensure emsdk

brotli:
	@BROTLI_VERSION="$(BROTLI_VERSION)" \
	HOST_CC="$(HOST_CC)" \
	./scripts/toolchain.sh ensure brotli

check-compile-tools: $(if $(NEEDS_BUNDLED_EMCC),sdk)
	@command -v "$(HOST_CC)" >/dev/null 2>&1 || { echo "Missing tool: $(HOST_CC)" >&2; exit 1; }
	@command -v shasum >/dev/null 2>&1 || { echo "Missing tool: shasum" >&2; exit 1; }
	@$(EMCC) $(EMCC_ARGS) --version >/dev/null

check-tools: check-compile-tools \
		$(if $(NEEDS_BUNDLED_WASM_OPT),sdk) \
		$(if $(NEEDS_BUNDLED_BROTLI),brotli)
	@command -v "$(TERSER)" >/dev/null 2>&1 || { echo "Missing tool: $(TERSER)" >&2; exit 1; }
	@command -v "$(BROTLI)" >/dev/null 2>&1 || { echo "Missing tool: $(BROTLI)" >&2; exit 1; }
	@$(WASM_OPT) $(WASM_OPT_ARGS) --version >/dev/null
	@$(BROTLI) $(BROTLI_ARGS) --version >/dev/null
	@actual_version="$$("$(TERSER)" $(TERSER_ARGS) --version \
		| awk 'NF { version = $$NF } END { print version }')"; \
	[[ "$$actual_version" == "$(TERSER_VERSION)" ]] || { \
		echo "Expected Terser $(TERSER_VERSION), found $$actual_version." >&2; \
		exit 1; \
	}

sbom: $(DIST_STAMP)
	@SYFT="$(SYFT)" \
	SYFT_VERSION="$(SYFT_VERSION)" \
	./scripts/release.sh sbom

hash-names: _release
	@./scripts/runner.sh test hash-names \
		./scripts/tests/artifacts.sh hash-names

test-binary: hash-names
	@WASM_OPT="$(WASM_OPT)" \
	EHS_WASM_OPT_ARGS='$(WASM_OPT_ARGS)' \
	./scripts/runner.sh test binary \
		./scripts/tests/artifacts.sh binary

reproducible: test-binary
	@./scripts/runner.sh test reproducibility \
		./scripts/tests/reproducibility.sh

test-sanitizers: debug
	@SANITIZER_CC="$(SANITIZER_CC)" \
	./scripts/runner.sh test sanitizers \
		./scripts/tests/sanitizers.sh

test-release: reproducible
	@echo "All release artifact tests passed."

tests: test-sanitizers test-release
	@echo "All sanitizer and release tests passed."

# Capture the complete lint suite as release-test evidence. During make release,
# EHS_RELEASE_ID places this log alongside the other tests copied to metadata.
test-linters:
	@./scripts/runner.sh test linters \
		$(MAKE) --no-print-directory lint

# This integration suite owns an isolated local Compose project. It is exposed
# independently and is also the final test stage of make release.
test-con:
	@./scripts/runner.sh test test-con \
		./scripts/tests/test_con.sh

_clean:
	@./scripts/maintenance.sh build
	@$(MAKE) --no-print-directory -C "$(PACKER_DIR)" clean

clean: _clean logs-clean

cache-clean:
	@./scripts/maintenance.sh cache

logs-clean:
	@./scripts/maintenance.sh logs

sdk-clean:
	@./scripts/maintenance.sh sdk

distclean: clean cache-clean sdk-clean

dist-clean: distclean

compile-commands: $(COMPILATION_DATABASE)
	@echo "Compilation database generated at $(COMPILATION_DATABASE)"

$(COMPILATION_DATABASE): \
		$(MAKE_CONFIG_FILES) \
		scripts/build.sh \
		$(SOURCES) \
		$(HEADERS) \
		$(CONTENTS_HEADER) \
		$(ASSETS_HEADER) | $(OBJECT_DIR) check-compile-tools
	@EMCC="$(EMCC)" \
	EHS_EMCC_ARGS='$(EMCC_ARGS)' \
	EHS_SOURCES='$(SOURCES)' \
	EHS_CPPFLAGS='$(CPPFLAGS)' \
	EHS_COMPILE_FLAGS='$(RELEASE_CFLAGS)' \
	./scripts/build.sh compile-commands

help:
	@echo "Available targets:"
	@echo "  make release           Clean + lint + sanitizer gate + build + tests"
	@echo "  make build             Incremental release build"
	@echo "  make debug             Audited sanitizer-enabled WebAssembly debug build"
	@echo "  make test-sanitizers   Build debug WASM and execute native ASan/UBSan tests"
	@echo "  make test-release      Run binary and reproducibility release tests"
	@echo "  make audit             Audit the toolchain and every release flag"
	@echo "  make audit-sources     Verify C/H files byte-for-byte"
	@echo "  make update-sources    Regenerate the tracked C/H source manifest"
	@echo "  make validate          Incremental build + dist/ validation"
	@echo "  make sbom              Generate optional CycloneDX and SPDX SBOMs"
	@echo "  make hash-names        Verify application content-addressed names"
	@echo "  make test-binary       Audit the published WebAssembly binary"
	@echo "  make reproducible      Compare two clean release builds"
	@echo "  make tests             Run the release test suite"
	@echo "  make test-linters      Run lint and capture test-linters evidence"
	@echo "  make test-con          Build/start Compose and test local ports/security"
	@echo "  make compile-commands  Generate the compiler database from Makefile flags"
	@echo "  make lint              Run every configured native linter"
	@echo "  make logs-clean        Remove previous Make invocation logs"
	@echo "  make packer release    Build the host packer in release mode"
	@echo "  make packer debug      Build the host packer with debug instrumentation"
	@echo "  make sdk               Install/activate the pinned emsdk"
	@echo "  make brotli            Build the repository-local Brotli CLI"
	@echo "  make clean             Remove disposable build artifacts and logs"
	@echo "  make cache-clean       Remove persistent project caches"
	@echo "  make distclean         Clean + remove caches and emsdk downloads"
	@echo "  make dist-clean        Alias for make distclean"
	@echo ""
	@echo "Variables:"
	@echo "  USE_BUNDLED_EMSDK=1    Force tools/emsdk"
	@echo "  USE_BUNDLED_BROTLI=1   Force tools/brotli"
	@echo "  EMCC=/path/to/emcc     Override the compiler"
	@echo "  WASM_OPT=/path/to      Override wasm-opt"
	@echo "  BROTLI=/path/to        Override the Brotli CLI"
	@echo "  SYFT=/path/to/syft     Override the SBOM generator"
	@echo "  RUN_LINT=0             Skip lint only when an external CI lint gate passed"
	@echo "  SANITIZER_CC=clang     Override the native sanitizer compiler"
	@echo "  REQUIRE_SBOM=1         Fail when either release SBOM is unavailable"
	@echo "  REQUIRE_SIGNATURE=1    Fail when the release manifest is unsigned"

# EOF

# SPDX-FileCopyrightText: 2026 Sergio Bonatto
# SPDX-License-Identifier: MIT

SHELL := /bin/bash

# Every user-facing invocation is replayed once through the logging wrapper.
# Recursive makes inherit EHS_LOGGED_MAKE=1 and therefore execute the real
# build graph without producing duplicate logs.
ifeq ($(EHS_LOGGED_MAKE),)

REQUESTED_GOALS := $(if $(MAKECMDGOALS),$(MAKECMDGOALS),release)
NO_LOG_GOALS := clean logs-clean distclean dist-clean

.DEFAULT_GOAL := _logged-dispatch
.PHONY: _logged-dispatch $(REQUESTED_GOALS)

$(REQUESTED_GOALS): _logged-dispatch

_logged-dispatch:
ifneq ($(filter $(NO_LOG_GOALS),$(REQUESTED_GOALS)),)
	@EHS_LOGGED_MAKE=1 "$(MAKE)" --no-print-directory \
		$(foreach goal,$(REQUESTED_GOALS),"$(goal)")
else
	@./scripts/runner.sh make "$(MAKE)" \
		$(foreach goal,$(REQUESTED_GOALS),"$(goal)")
endif

else

.DEFAULT_GOAL := release
.DELETE_ON_ERROR:
.SUFFIXES:

# -----------------------------------------------------------------------------
# 1. Project layout
# -----------------------------------------------------------------------------

PROJECT_ROOT := $(abspath .)
export PATH := $(PROJECT_ROOT)/.cache/lint/bin:$(PATH)
CORE_DIR := core
SRC_DIR := $(CORE_DIR)/src
INC_DIR := $(CORE_DIR)/inc
CONTENT_DIR := content/posts
ASSET_DIR := assets
SITE_DIR := site
BUILD_DIR := .build
GENERATED_DIR := $(BUILD_DIR)/generated
OBJECT_DIR := $(BUILD_DIR)/obj
AUDIT_DIR := $(BUILD_DIR)/audit
DEBUG_DIR := $(BUILD_DIR)/debug
DIST_DIR := dist
COMPILATION_DATABASE := compile_commands.json
CACHE_ROOT := .cache
EMSCRIPTEN_CACHE_DIR := $(CACHE_ROOT)/emscripten
TOOLCHAIN_CACHE_DIR := $(CACHE_ROOT)/toolchains

PACKER_DIR := tools/packer
PACKER_BUILD_DIR := $(PROJECT_ROOT)/$(BUILD_DIR)/packer
PACKER := $(PACKER_BUILD_DIR)/release/packer
PACKER_SOURCE := $(PACKER_DIR)/src/packer.c
PACKER_HEADER := $(PACKER_DIR)/inc/packer.h
SOURCE_MANIFEST := $(CORE_DIR)/sources.sha256
WASM_IMPORT_ALLOWLIST := $(CORE_DIR)/wasm-imports.allow
CONTENTS_HEADER := $(GENERATED_DIR)/contents_data.h
ASSETS_HEADER := $(GENERATED_DIR)/assets.h
SOURCE_AUDIT_STAMP := $(AUDIT_DIR)/sources.stamp
AUDIT_STAMP := $(AUDIT_DIR)/release-flags.stamp
DEBUG_AUDIT_STAMP := $(AUDIT_DIR)/debug-flags.stamp
WASM_STAMP := $(BUILD_DIR)/wasm.stamp
DEBUG_WASM_STAMP := $(DEBUG_DIR)/wasm.stamp
DIST_STAMP := $(BUILD_DIR)/dist.stamp

RUNTIME_SOURCE_NAMES := \
	buffer \
	config \
	js_api \
	main \
	markdown \
	math \
	pages \
	router \
	ui
SOURCES := $(addprefix $(SRC_DIR)/,$(addsuffix .c,$(RUNTIME_SOURCE_NAMES)))
ALL_C_SOURCES := $(sort $(wildcard $(SRC_DIR)/*.c))
HEADERS := $(sort $(wildcard $(INC_DIR)/*.h))
POSTS := $(sort $(wildcard $(CONTENT_DIR)/*.md))
ASSET_DIRS := $(sort $(shell find $(ASSET_DIR) -type d 2>/dev/null))
ASSET_SOURCES := $(sort $(shell find $(ASSET_DIR) -type f 2>/dev/null))
SITE_DIRS := $(sort $(shell find $(SITE_DIR) -type d 2>/dev/null))
SITE_SOURCES := $(sort $(shell find $(SITE_DIR) -type f 2>/dev/null))

# -----------------------------------------------------------------------------
# 2. Toolchain resolution
#
# System tools are preferred. The repository-managed Emscripten SDK and Brotli
# submodules are automatic fallbacks. USE_BUNDLED_EMSDK=1 and
# USE_BUNDLED_BROTLI=1 force reproducible repository-local toolchains.
# -----------------------------------------------------------------------------

EMSDK_VERSION := $(strip $(shell sed -n '1p' .emscripten-version))
BROTLI_VERSION := $(strip $(shell sed -n '1p' .brotli-version))
TERSER_VERSION := $(strip $(shell sed -n '1p' .terser-version))
SYFT_VERSION := $(strip $(shell sed -n '1p' .syft-version))
USE_BUNDLED_EMSDK ?= 0
USE_BUNDLED_BROTLI ?= 0
USE_BUNDLED_TERSER ?= 0
RUN_LINT ?= 1
SANITIZER_CC ?= clang

SYSTEM_EMCC := $(shell command -v emcc 2>/dev/null)
SYSTEM_WASM_OPT := $(shell command -v wasm-opt 2>/dev/null)
SYSTEM_BROTLI := $(shell command -v brotli 2>/dev/null)
SYSTEM_TERSER := $(shell command -v terser 2>/dev/null)
SYSTEM_TERSER_VERSION := $(if $(SYSTEM_TERSER),$(strip $(shell \
	$(SYSTEM_TERSER) --version 2>/dev/null | awk '{ print $$NF }')))

HOST_CC ?= cc
SYFT ?= syft
EMCC_ARGS ?=
WASM_OPT_ARGS ?=
BROTLI_ARGS ?=
TERSER_ARGS ?=

ifeq ($(origin EMCC), undefined)
  ifeq ($(USE_BUNDLED_EMSDK),1)
    EMCC := $(PROJECT_ROOT)/scripts/toolchain.sh
    EMCC_ARGS := run emcc
  else ifneq ($(SYSTEM_EMCC),)
    EMCC := $(SYSTEM_EMCC)
  else
    EMCC := $(PROJECT_ROOT)/scripts/toolchain.sh
    EMCC_ARGS := run emcc
  endif
endif

ifeq ($(origin TERSER), undefined)
  ifeq ($(USE_BUNDLED_TERSER),1)
    TERSER := $(PROJECT_ROOT)/scripts/toolchain.sh
    TERSER_ARGS := run terser
  else ifeq ($(SYSTEM_TERSER_VERSION),$(TERSER_VERSION))
    TERSER := $(SYSTEM_TERSER)
  else
    TERSER := $(PROJECT_ROOT)/scripts/toolchain.sh
    TERSER_ARGS := run terser
  endif
endif

ifeq ($(origin WASM_OPT), undefined)
  ifeq ($(USE_BUNDLED_EMSDK),1)
    WASM_OPT := $(PROJECT_ROOT)/scripts/toolchain.sh
    WASM_OPT_ARGS := run wasm-opt
  else ifneq ($(SYSTEM_WASM_OPT),)
    WASM_OPT := $(SYSTEM_WASM_OPT)
  else
    WASM_OPT := $(PROJECT_ROOT)/scripts/toolchain.sh
    WASM_OPT_ARGS := run wasm-opt
  endif
endif

ifeq ($(origin BROTLI), undefined)
  ifeq ($(USE_BUNDLED_BROTLI),1)
    BROTLI := $(PROJECT_ROOT)/scripts/toolchain.sh
    BROTLI_ARGS := run brotli
  else ifneq ($(SYSTEM_BROTLI),)
    BROTLI := $(SYSTEM_BROTLI)
  else
    BROTLI := $(PROJECT_ROOT)/scripts/toolchain.sh
    BROTLI_ARGS := run brotli
  endif
endif

NEEDS_BUNDLED_EMCC :=
ifneq ($(filter %/scripts/toolchain.sh,$(EMCC)),)
  NEEDS_BUNDLED_EMCC := 1
endif

NEEDS_BUNDLED_WASM_OPT :=
ifneq ($(filter %/scripts/toolchain.sh,$(WASM_OPT)),)
  NEEDS_BUNDLED_WASM_OPT := 1
endif

NEEDS_BUNDLED_BROTLI :=
ifneq ($(filter %/scripts/toolchain.sh,$(BROTLI)),)
  NEEDS_BUNDLED_BROTLI := 1
endif

# -----------------------------------------------------------------------------
# 3. Host packer flags
#
# The packer owns its compile and link flags. The root build imports those
# exact values for auditing so there is a single source of truth.
# -----------------------------------------------------------------------------

PACKER_RELEASE_FLAGS := $(strip $(shell \
	$(MAKE) --no-print-directory -s -C $(PACKER_DIR) print-release-flags))
PACKER_RELEASE_LINK_FLAGS := $(strip $(shell \
	$(MAKE) --no-print-directory -s -C $(PACKER_DIR) print-release-link-flags))
PACKER_DEBUG_FLAGS := $(strip $(shell \
	$(MAKE) --no-print-directory -s -C $(PACKER_DIR) print-debug-flags))
PACKER_DEBUG_LINK_FLAGS := $(strip $(shell \
	$(MAKE) --no-print-directory -s -C $(PACKER_DIR) print-debug-link-flags))

PACKER_REQUESTED := $(filter packer,$(MAKECMDGOALS))
PACKER_MODE_GOALS := $(filter release debug,$(MAKECMDGOALS))
ifneq ($(word 2,$(PACKER_MODE_GOALS)),)
  $(error Select only one packer mode: release or debug)
endif
PACKER_MODE := $(if $(PACKER_MODE_GOALS),$(firstword $(PACKER_MODE_GOALS)),release)

# -----------------------------------------------------------------------------
# 4. WebAssembly compile flags
#
# Native-only hardening such as ELF RELRO, PIE, CET, MTE, stack-clash
# protection and -march=<host> is intentionally excluded: WebAssembly has a
# different loader, ISA, sandbox and linear-memory model.
# -----------------------------------------------------------------------------

COMMON_CFLAGS := \
	-std=c11 \
	-U_FORTIFY_SOURCE \
	-D_FORTIFY_SOURCE=3 \
	-fstack-protector-strong \
	-fno-delete-null-pointer-checks \
	-fwrapv \
	-fsigned-bitfields \
	-fsigned-char \
	-fno-common

WASM_TARGET_FLAGS := \
	-mbulk-memory \
	-mnontrapping-fptoint \
	-msign-ext \
	-mmultivalue \
	-mreference-types

RELEASE_OPTIMIZATION_FLAGS := \
	-Oz \
	-flto \
	-funroll-loops

RELEASE_CODEGEN_FLAGS := \
	-DNDEBUG \
	-fomit-frame-pointer \
	-fno-exceptions \
	-fno-unwind-tables \
	-fno-asynchronous-unwind-tables \
	-ffunction-sections \
	-fdata-sections \
	-fvisibility=hidden \
	-fstrict-aliasing \
	-fno-strict-overflow \
	-g0 \
	-fno-ident

RELEASE_HARDENING_FLAGS := \
	-ftrivial-auto-var-init=zero

STRICT_WARNING_FLAGS := \
	-Wall \
	-Wextra \
	-Wpedantic \
	-Werror \
	-Werror=format-security \
	-Werror=unknown-warning-option \
	-Werror=unused-command-line-argument \
	-Wshadow-all \
	-Waddress-of-packed-member \
	-Wconversion \
	-Wsign-conversion \
	-Wuninitialized \
	-Winit-self \
	-Wunused-parameter \
	-Wunused-result \
	-Wcast-align \
	-Wcast-qual \
	-Wformat=2 \
	-Wformat-security \
	-Wformat-signedness \
	-Wformat-y2k \
	-Wmissing-format-attribute \
	-Wstrict-prototypes \
	-Wmissing-prototypes \
	-Wmissing-declarations \
	-Wmissing-variable-declarations \
	-Wnested-externs \
	-Wunused-function \
	-Wpointer-arith \
	-Waddress \
	-Wfree-nonheap-object \
	-Wnonnull \
	-Wundef \
	-Wvla \
	-Wwrite-strings \
	-Wdouble-promotion \
	-Wfloat-equal \
	-Wimplicit-fallthrough \
	-Wswitch-enum \
	-Wswitch-default \
	-Wunreachable-code \
	-Wsequence-point \
	-Wjump-misses-init \
	-Wcomma \
	-Wconditional-uninitialized \
	-Wnull-dereference \
	-Walloca \
	-Warray-bounds \
	-Wextra-semi \
	-Wnewline-eof \
	-Wdocumentation \
	-Wstrict-aliasing \
	-Wbad-function-cast \
	-Wcast-function-type \
	-Wcast-function-type-strict \
	-Wunused-macros \
	-Wreserved-id-macro \
	-Wredundant-decls \
	-Wempty-body \
	-Wdate-time \
	-Winvalid-pch \
	-Wtrigraphs \
	-Wdeprecated

RELEASE_CFLAGS := \
	$(COMMON_CFLAGS) \
	$(WASM_TARGET_FLAGS) \
	$(RELEASE_OPTIMIZATION_FLAGS) \
	$(RELEASE_CODEGEN_FLAGS) \
	$(RELEASE_HARDENING_FLAGS) \
	$(STRICT_WARNING_FLAGS)

DEBUG_CFLAGS := \
	$(COMMON_CFLAGS) \
	$(WASM_TARGET_FLAGS) \
	-O0 \
	-g3 \
	-ggdb \
	-DDEBUG \
	-fno-omit-frame-pointer \
	-fno-inline \
	-fno-inline-functions \
	-fno-strict-aliasing \
	-fdebug-prefix-map=$(PROJECT_ROOT)/=./ \
	-ftrivial-auto-var-init=pattern \
	-fsanitize=address,undefined,leak,alignment \
	-fno-sanitize-recover=all \
	$(STRICT_WARNING_FLAGS)

# wasm-ld already enables section GC and data merging by default. They remain
# explicit here so the release contract can be inspected and audited.
RELEASE_LINKER_FLAGS := \
	-Wl,--gc-sections \
	-Wl,--merge-data-segments \
	-Wl,--compress-relocations \
	-Wl,--allow-undefined-file=$(WASM_IMPORT_ALLOWLIST) \
	-Wl,--fatal-warnings \
	-Wl,--strip-all

DEBUG_LINKER_FLAGS := \
	-Wl,--gc-sections \
	-Wl,--merge-data-segments \
	-Wl,--allow-undefined-file=$(WASM_IMPORT_ALLOWLIST) \
	-Wl,--fatal-warnings \
	-fsanitize=address,undefined,leak,alignment \
	-fno-sanitize-recover=all

# -----------------------------------------------------------------------------
# 5. Emscripten release settings
# -----------------------------------------------------------------------------

EMSCRIPTEN_RELEASE_SETTINGS := \
	-sWASM=1 \
	-sASSERTIONS=0 \
	-sSAFE_HEAP=0 \
	-sSTACK_OVERFLOW_CHECK=0 \
	-sFILESYSTEM=0 \
	-sALLOW_MEMORY_GROWTH=0 \
	-sABORTING_MALLOC=1 \
	-sEXIT_RUNTIME=0 \
	-sSUPPORT_LONGJMP=0 \
	-sENVIRONMENT=web \
	-sDYNAMIC_EXECUTION=0 \
	-sSTRICT=1 \
	-sSTRICT_JS=1 \
	-sMALLOC=emmalloc \
	-sTEXTDECODER=2 \
	-sPOLYFILL=0 \
	-sINCOMING_MODULE_JS_API=[] \
	-sERROR_ON_UNDEFINED_SYMBOLS=1 \
	-sWARN_ON_UNDEFINED_SYMBOLS=1 \
	-sALLOW_TABLE_GROWTH=0 \
	-sWASM_BIGINT=1 \
	-sCHECK_NULL_WRITES=1 \
	-sIGNORE_MISSING_MAIN=0 \
	-sSTACK_SIZE=131072 \
	-sINITIAL_MEMORY=16777216

EMSCRIPTEN_DEBUG_SETTINGS := \
	-sWASM=1 \
	-sASSERTIONS=2 \
	-sSTACK_OVERFLOW_CHECK=2 \
	-sFILESYSTEM=0 \
	-sALLOW_MEMORY_GROWTH=0 \
	-sABORTING_MALLOC=1 \
	-sEXIT_RUNTIME=0 \
	-sSUPPORT_LONGJMP=0 \
	-sENVIRONMENT=web \
	-sDYNAMIC_EXECUTION=0 \
	-sSTRICT=1 \
	-sSTRICT_JS=1 \
	-sMALLOC=emmalloc \
	-sTEXTDECODER=2 \
	-sPOLYFILL=0 \
	-sINCOMING_MODULE_JS_API=[] \
	-sERROR_ON_UNDEFINED_SYMBOLS=1 \
	-sWARN_ON_UNDEFINED_SYMBOLS=1 \
	-sGL_ASSERTIONS=1 \
	-sRUNTIME_DEBUG=1 \
	-sALLOW_TABLE_GROWTH=0 \
	-sWASM_BIGINT=1 \
	-sCHECK_NULL_WRITES=1 \
	-sIGNORE_MISSING_MAIN=0 \
	-sSTACK_SIZE=131072 \
	-sINITIAL_MEMORY=16777216

# EM_JS functions are JavaScript imports rather than WebAssembly exports.
# Therefore draw_frame is intentionally absent from EXPORTED_FUNCTIONS.
APPLICATION_EXPORT_FLAGS := \
	-sEXPORTED_FUNCTIONS='["_main","_ui_toggle_theme","_switch_page","_render_markdown","_handle_route","_handle_current_route"]' \
	-sEXPORTED_RUNTIME_METHODS='["UTF8ToString","ccall","cwrap"]'

WASM_OPT_FLAGS := \
	-Oz \
	--all-features \
	--strip-debug \
	--strip-dwarf \
	--strip-producers \
	--strip-toolchain-annotations \
	--dce \
	--remove-unused-module-elements \
	--vacuum

DEBUG_WASM_OPT_FLAGS := \
	-O0 \
	--all-features \
	--debuginfo \
	--strip-producers

TERSER_FLAGS := \
	--compress passes=3 \
	--mangle \
	--ecma 2020 \
	--comments false

CPPFLAGS := -I$(INC_DIR) -I$(GENERATED_DIR)

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
		Makefile \
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

# -----------------------------------------------------------------------------
# 7. Directories and generated inputs
# -----------------------------------------------------------------------------

$(GENERATED_DIR) $(OBJECT_DIR) $(AUDIT_DIR) $(DEBUG_DIR) $(EMSCRIPTEN_CACHE_DIR) $(TOOLCHAIN_CACHE_DIR):
	@mkdir -p "$@"

$(PACKER): $(PACKER_SOURCE) $(PACKER_HEADER) $(PACKER_DIR)/Makefile
	@$(MAKE) --no-print-directory -C "$(PACKER_DIR)" release \
		BUILD_DIR="$(PACKER_BUILD_DIR)" \
		CC="$(HOST_CC)"

$(CONTENTS_HEADER): $(PACKER) $(CONTENT_DIR) $(POSTS) | $(GENERATED_DIR)
	@tmp="$@.tmp"; \
	"$(PACKER)" "$(CONTENT_DIR)" > "$$tmp"; \
	mv "$$tmp" "$@"

$(ASSETS_HEADER): Makefile \
		$(ASSET_DIR)/images/profile.avif \
		$(ASSET_DIR)/fonts/lmroman10-regular.otf | $(GENERATED_DIR)
	@pfp_hash="$$(shasum -a 256 "$(ASSET_DIR)/images/profile.avif" | cut -c 1-8)"; \
	font_hash="$$(shasum -a 256 "$(ASSET_DIR)/fonts/lmroman10-regular.otf" | cut -c 1-8)"; \
	tmp="$@.tmp"; \
	printf '%s\n' \
		"#define ASSET_PFP \"assets/images/profile.$$pfp_hash.avif\"" \
		"#define ASSET_FONT \"assets/fonts/lmroman10-regular.$$font_hash.otf\"" > "$$tmp"; \
	mv "$$tmp" "$@"

# -----------------------------------------------------------------------------
# 8. Audited release pipeline
# -----------------------------------------------------------------------------

$(SOURCE_AUDIT_STAMP): \
		$(SOURCE_MANIFEST) \
		$(ALL_C_SOURCES) \
		$(HEADERS) \
		$(PACKER_SOURCE) \
		$(PACKER_HEADER) | $(AUDIT_DIR)
	@shasum -a 256 --check "$(SOURCE_MANIFEST)"
	@touch "$@"

$(AUDIT_STAMP): \
		Makefile \
		.emscripten-version \
		.brotli-version \
		.terser-version \
		$(PACKER_DIR)/Makefile \
		scripts/build.sh \
		scripts/toolchain.sh \
		$(SOURCE_AUDIT_STAMP) | $(AUDIT_DIR) check-tools
	@EMCC="$(EMCC)" \
	EHS_EMCC_ARGS='$(EMCC_ARGS)' \
	WASM_OPT="$(WASM_OPT)" \
	EHS_WASM_OPT_ARGS='$(WASM_OPT_ARGS)' \
	HOST_CC="$(HOST_CC)" \
	TERSER="$(TERSER)" \
	EHS_TERSER_ARGS='$(TERSER_ARGS)' \
	BROTLI="$(BROTLI)" \
	EHS_BROTLI_ARGS='$(BROTLI_ARGS)' \
	EMSDK_VERSION="$(EMSDK_VERSION)" \
	BROTLI_VERSION="$(BROTLI_VERSION)" \
	TERSER_VERSION="$(TERSER_VERSION)" \
	EHS_HOST_FLAGS='$(PACKER_RELEASE_FLAGS)' \
	EHS_HOST_LINK_FLAGS='$(PACKER_RELEASE_LINK_FLAGS)' \
	EHS_COMPILE_FLAGS='$(RELEASE_CFLAGS)' \
	EHS_LINK_FLAGS='$(RELEASE_LINKER_FLAGS)' \
	EHS_EMSCRIPTEN_SETTINGS='$(EMSCRIPTEN_RELEASE_SETTINGS)' \
	EHS_WASM_OPT_FLAGS='$(WASM_OPT_FLAGS)' \
	./scripts/build.sh audit-flags "$(AUDIT_DIR)/release-flags.txt"
	@touch "$@"

$(DEBUG_AUDIT_STAMP): \
		Makefile \
		.emscripten-version \
		.brotli-version \
		.terser-version \
		$(PACKER_DIR)/Makefile \
		scripts/build.sh \
		scripts/toolchain.sh \
		$(SOURCE_AUDIT_STAMP) | $(AUDIT_DIR) check-tools
	@EMCC="$(EMCC)" \
	EHS_EMCC_ARGS='$(EMCC_ARGS)' \
	WASM_OPT="$(WASM_OPT)" \
	EHS_WASM_OPT_ARGS='$(WASM_OPT_ARGS)' \
	HOST_CC="$(HOST_CC)" \
	TERSER="$(TERSER)" \
	EHS_TERSER_ARGS='$(TERSER_ARGS)' \
	BROTLI="$(BROTLI)" \
	EHS_BROTLI_ARGS='$(BROTLI_ARGS)' \
	EMSDK_VERSION="$(EMSDK_VERSION)" \
	BROTLI_VERSION="$(BROTLI_VERSION)" \
	TERSER_VERSION="$(TERSER_VERSION)" \
	EHS_BUILD_PROFILE=debug \
	EHS_HOST_FLAGS='$(PACKER_DEBUG_FLAGS)' \
	EHS_HOST_LINK_FLAGS='$(PACKER_DEBUG_LINK_FLAGS)' \
	EHS_COMPILE_FLAGS='$(DEBUG_CFLAGS)' \
	EHS_LINK_FLAGS='$(DEBUG_LINKER_FLAGS)' \
	EHS_EMSCRIPTEN_SETTINGS='$(EMSCRIPTEN_DEBUG_SETTINGS)' \
	EHS_WASM_OPT_FLAGS='$(DEBUG_WASM_OPT_FLAGS)' \
	./scripts/build.sh audit-flags "$(AUDIT_DIR)/debug-flags.txt"
	@touch "$@"

$(WASM_STAMP): \
		$(SOURCES) \
		$(HEADERS) \
		$(CONTENTS_HEADER) \
		$(ASSETS_HEADER) \
		$(WASM_IMPORT_ALLOWLIST) \
		$(AUDIT_STAMP) \
		Makefile | $(OBJECT_DIR) $(EMSCRIPTEN_CACHE_DIR)
	EM_CACHE="$(PROJECT_ROOT)/$(EMSCRIPTEN_CACHE_DIR)" $(EMCC) $(EMCC_ARGS) \
		$(SOURCES) \
		$(CPPFLAGS) \
		$(RELEASE_CFLAGS) \
		$(RELEASE_LINKER_FLAGS) \
		$(EMSCRIPTEN_RELEASE_SETTINGS) \
		$(APPLICATION_EXPORT_FLAGS) \
		-o "$(BUILD_DIR)/app.js"
	$(WASM_OPT) $(WASM_OPT_ARGS) $(WASM_OPT_FLAGS) \
		"$(BUILD_DIR)/app.wasm" \
		-o "$(BUILD_DIR)/app.optimized.wasm"
	mv "$(BUILD_DIR)/app.optimized.wasm" "$(BUILD_DIR)/app.wasm"
	$(TERSER) $(TERSER_ARGS) "$(BUILD_DIR)/app.js" $(TERSER_FLAGS) \
		-o "$(BUILD_DIR)/app.min.js"
	mv "$(BUILD_DIR)/app.min.js" "$(BUILD_DIR)/app.js"
	@touch "$@"

$(DEBUG_WASM_STAMP): \
		$(SOURCES) \
		$(HEADERS) \
		$(CONTENTS_HEADER) \
		$(ASSETS_HEADER) \
		$(WASM_IMPORT_ALLOWLIST) \
		$(DEBUG_AUDIT_STAMP) \
		Makefile | $(DEBUG_DIR) $(EMSCRIPTEN_CACHE_DIR)
	EM_CACHE="$(PROJECT_ROOT)/$(EMSCRIPTEN_CACHE_DIR)" $(EMCC) $(EMCC_ARGS) \
		$(SOURCES) \
		$(CPPFLAGS) \
		$(DEBUG_CFLAGS) \
		$(DEBUG_LINKER_FLAGS) \
		$(EMSCRIPTEN_DEBUG_SETTINGS) \
		$(APPLICATION_EXPORT_FLAGS) \
		-o "$(DEBUG_DIR)/app.js"
	$(WASM_OPT) $(WASM_OPT_ARGS) $(DEBUG_WASM_OPT_FLAGS) \
		"$(DEBUG_DIR)/app.wasm" \
		-o "$(DEBUG_DIR)/app.checked.wasm"
	mv "$(DEBUG_DIR)/app.checked.wasm" "$(DEBUG_DIR)/app.wasm"
	@touch "$@"

$(DIST_STAMP): \
		$(WASM_STAMP) \
		$(COMPILATION_DATABASE) \
		$(ASSET_DIRS) \
		$(ASSET_SOURCES) \
		$(SITE_DIRS) \
		$(SITE_SOURCES) \
		scripts/release.sh
	@BROTLI="$(BROTLI)" \
	EHS_BROTLI_ARGS='$(BROTLI_ARGS)' \
	./scripts/release.sh package
	@touch "$@"

endif

# EOF

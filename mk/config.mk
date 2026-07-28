# SPDX-FileCopyrightText: 2026 Sergio Bonatto
# SPDX-License-Identifier: MIT

# -----------------------------------------------------------------------------
# 1. Project layout
# -----------------------------------------------------------------------------

PROJECT_ROOT := $(abspath .)
MAKE_CONFIG_FILES = $(MAKEFILE_LIST)
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
VERSION_MANIFEST := toolchain-versions.yml
VERSION_TOOL := scripts/read-version.sh
CACHE_ROOT := .cache
EMSCRIPTEN_CACHE_DIR := $(CACHE_ROOT)/emscripten
TOOLCHAIN_CACHE_DIR := $(CACHE_ROOT)/toolchains

PACKER_DIR := tools/packer
PACKER_BUILD_DIR := $(PROJECT_ROOT)/$(BUILD_DIR)/packer
PACKER := $(PACKER_BUILD_DIR)/release/packer
PACKER_SOURCE := $(PACKER_DIR)/src/packer.c
PACKER_HEADER := $(PACKER_DIR)/inc/packer.h
SOURCE_MANIFEST := $(AUDIT_DIR)/sources.sha256
SOURCE_MANIFEST_TOOL := scripts/source-manifest.sh
WASM_IMPORT_ALLOWLIST := $(CORE_DIR)/wasm-imports.allow
CONTENTS_HEADER := $(GENERATED_DIR)/contents_data.h
ASSETS_HEADER := $(GENERATED_DIR)/assets.h
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

EMSDK_VERSION := $(strip $(shell ./$(VERSION_TOOL) emscripten))
BROTLI_VERSION := $(strip $(shell ./$(VERSION_TOOL) brotli))
TERSER_VERSION := $(strip $(shell ./$(VERSION_TOOL) terser))
SYFT_VERSION := $(strip $(shell ./$(VERSION_TOOL) syft))
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

# EOF

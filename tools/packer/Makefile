# SPDX-FileCopyrightText: 2026 Sergio Bonatto
# SPDX-License-Identifier: MIT

SHELL := /bin/bash
.DEFAULT_GOAL := release
.DELETE_ON_ERROR:
.SUFFIXES:

CC ?= cc
BUILD_DIR ?= build

SRC_DIR := src
INC_DIR := inc
SOURCE := $(SRC_DIR)/packer.c
HEADER := $(INC_DIR)/packer.h

RELEASE_DIR := $(BUILD_DIR)/release
DEBUG_DIR := $(BUILD_DIR)/debug
RELEASE_BINARY := $(RELEASE_DIR)/packer
DEBUG_BINARY := $(DEBUG_DIR)/packer

COMMON_WARNING_FLAGS := \
	-Wall \
	-Wextra \
	-Wpedantic \
	-Werror \
	-Wpacked-bitfield-compat \
	-Wpacked-not-aligned \
	-Waddress-of-packed-member \
	-Wformat=2 \
	-Wformat-security \
	-Werror=format-security \
	-Wformat-overflow=2 \
	-Wformat-truncation=2 \
	-Wformat-signedness \
	-Wformat-y2k \
	-Wmissing-format-attribute \
	-Wshadow \
	-Wbad-function-cast \
	-Wcast-function-type \
	-Wcast-align \
	-Wcast-qual \
	-Wconversion \
	-Warith-conversion \
	-Wsign-conversion \
	-Wuninitialized \
	-Wmaybe-uninitialized \
	-Winit-self \
	-Wclobbered \
	-Wunused-parameter \
	-Wunused-result \
	-Wstrict-prototypes \
	-Wmissing-prototypes \
	-Wmissing-declarations \
	-Wnested-externs \
	-Wunused-function \
	-Wpointer-arith \
	-Waddress \
	-Walloca \
	-Wfree-nonheap-object \
	-Wrestrict \
	-Wnonnull \
	-Wunreachable-code \
	-Wsequence-point \
	-Wjump-misses-init \
	-Wstack-usage=8192 \
	-Wfloat-equal \
	-Wdouble-promotion \
	-Wwrite-strings \
	-Wredundant-decls \
	-Wswitch-default \
	-Wswitch-enum \
	-Wduplicated-cond \
	-Wduplicated-branches \
	-Wlogical-op \
	-Wunsafe-loop-optimizations \
	-Wvector-operation-performance \
	-Wundef \
	-Wvla \
	-Wempty-body \
	-Wdate-time \
	-Winvalid-pch \
	-Wtrigraphs \
	-Wsuggest-attribute=format \
	-Wsuggest-attribute=noreturn \
	-Wdeprecated

COMMON_HARDENING_FLAGS := \
	-U_FORTIFY_SOURCE \
	-D_FORTIFY_SOURCE=3 \
	-fstack-protector-strong \
	-fstack-clash-protection \
	-fno-delete-null-pointer-checks \
	-fwrapv \
	-fsigned-bitfields \
	-fsigned-char \
	-fcond-mismatch \
	-fno-common

RELEASE_CFLAGS := \
	-std=c11 \
	-Os \
	-DNDEBUG \
	-flto \
	-fuse-linker-plugin \
	-fomit-frame-pointer \
	-funroll-loops \
	-fno-exceptions \
	-fno-unwind-tables \
	-fno-asynchronous-unwind-tables \
	-ffunction-sections \
	-fdata-sections \
	-g0 \
	-fno-ident \
	-fvisibility=hidden \
	-fstrict-aliasing \
	-fno-strict-overflow \
	-ftrivial-auto-var-init=zero \
	$(COMMON_HARDENING_FLAGS) \
	$(COMMON_WARNING_FLAGS)

RELEASE_LDFLAGS := \
	-flto \
	-fuse-linker-plugin \
	-Wl,--gc-sections \
	-Wl,--as-needed \
	-Wl,-O1 \
	-Wl,-s \
	-Wl,-z,relro \
	-Wl,-z,now \
	-Wl,-z,noexecstack \
	-Wl,-z,separate-code \
	-Wl,-z,defs \
	-Wl,--build-id=sha1

DEBUG_CFLAGS := \
	-std=c11 \
	-O0 \
	-g3 \
	-ggdb \
	-DDEBUG \
	-fno-omit-frame-pointer \
	-fvar-tracking-assignments \
	-fdebug-prefix-map=$(abspath $(SRC_DIR))/=src/ \
	-frecord-gcc-switches \
	-fno-inline \
	-fno-inline-functions \
	-fno-inline-functions-called-once \
	-fno-strict-aliasing \
	-ftrivial-auto-var-init=pattern \
	-fanalyzer \
	-fanalyzer-verbosity=3 \
	-fsanitize=address,undefined,leak,alignment \
	-fno-sanitize-recover=all \
	$(COMMON_HARDENING_FLAGS) \
	$(COMMON_WARNING_FLAGS)

DEBUG_LDFLAGS := \
	-fsanitize=address,undefined,leak,alignment \
	-fno-sanitize-recover=all \
	-Wl,--as-needed \
	-Wl,-z,relro \
	-Wl,-z,now \
	-Wl,-z,noexecstack \
	-Wl,-z,separate-code \
	-Wl,-z,defs \
	-Wl,--build-id=sha1

.PHONY: all clean debug print-debug-flags print-debug-link-flags \
	print-release-flags print-release-link-flags release

all: release

release: $(RELEASE_BINARY)
	@echo "Packer release build completed: $(RELEASE_BINARY)"

debug: $(DEBUG_BINARY)
	@echo "Packer debug build completed: $(DEBUG_BINARY)"

$(RELEASE_BINARY): $(SOURCE) $(HEADER) Makefile | $(RELEASE_DIR)
	$(CC) -I$(INC_DIR) $(RELEASE_CFLAGS) $(SOURCE) \
		$(RELEASE_LDFLAGS) -o "$@"

$(DEBUG_BINARY): $(SOURCE) $(HEADER) Makefile | $(DEBUG_DIR)
	$(CC) -I$(INC_DIR) $(DEBUG_CFLAGS) $(SOURCE) \
		$(DEBUG_LDFLAGS) -o "$@"

$(RELEASE_DIR) $(DEBUG_DIR):
	@mkdir -p "$@"

clean:
	@build_dir="$(abspath $(BUILD_DIR))"; \
	case "$$build_dir" in \
		"$(abspath build)"|"$(abspath ../..)/.build/packer") \
			rm -rf "$$build_dir" ;; \
		*) \
			echo "Refusing to clean unexpected path: $$build_dir" >&2; \
			exit 1 ;; \
	esac
	@echo "Packer build artifacts removed."

print-release-flags:
	@printf '%s\n' "$(RELEASE_CFLAGS)"

print-release-link-flags:
	@printf '%s\n' "$(RELEASE_LDFLAGS)"

print-debug-flags:
	@printf '%s\n' "$(DEBUG_CFLAGS)"

print-debug-link-flags:
	@printf '%s\n' "$(DEBUG_LDFLAGS)"

# EOF

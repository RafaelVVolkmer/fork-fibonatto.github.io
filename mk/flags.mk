# SPDX-FileCopyrightText: 2026 Sergio Bonatto
# SPDX-License-Identifier: MIT

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

# EOF

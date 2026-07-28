# SPDX-FileCopyrightText: 2026 Sergio Bonatto
# SPDX-License-Identifier: MIT

# -----------------------------------------------------------------------------
# 8. Audited release pipeline
# -----------------------------------------------------------------------------

$(SOURCE_AUDIT_STAMP): \
		$(SOURCE_MANIFEST) \
		$(SOURCE_MANIFEST_TOOL) \
		$(ALL_C_SOURCES) \
		$(HEADERS) \
		$(PACKER_SOURCE) \
		$(PACKER_HEADER) | $(AUDIT_DIR)
	@./$(SOURCE_MANIFEST_TOOL) check "$(SOURCE_MANIFEST)"
	@touch "$@"

$(AUDIT_STAMP): \
		$(MAKE_CONFIG_FILES) \
		.emscripten-version \
		.brotli-version \
		.terser-version \
		$(PACKER_DIR)/Makefile \
		scripts/build.sh \
		scripts/toolchain.sh | $(AUDIT_DIR) check-tools
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
		$(MAKE_CONFIG_FILES) \
		.emscripten-version \
		.brotli-version \
		.terser-version \
		$(PACKER_DIR)/Makefile \
		scripts/build.sh \
		scripts/toolchain.sh | $(AUDIT_DIR) check-tools
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
		$(MAKE_CONFIG_FILES) | $(OBJECT_DIR) $(EMSCRIPTEN_CACHE_DIR)
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
		$(MAKE_CONFIG_FILES) | $(DEBUG_DIR) $(EMSCRIPTEN_CACHE_DIR)
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

# EOF

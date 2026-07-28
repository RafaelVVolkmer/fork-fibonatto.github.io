# SPDX-FileCopyrightText: 2026 Sergio Bonatto
# SPDX-License-Identifier: MIT

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

$(ASSETS_HEADER): $(MAKE_CONFIG_FILES) \
		$(ASSET_DIR)/images/profile.avif \
		$(ASSET_DIR)/fonts/lmroman10-regular.otf | $(GENERATED_DIR)
	@pfp_hash="$$(shasum -a 256 "$(ASSET_DIR)/images/profile.avif" | cut -c 1-8)"; \
	font_hash="$$(shasum -a 256 "$(ASSET_DIR)/fonts/lmroman10-regular.otf" | cut -c 1-8)"; \
	tmp="$@.tmp"; \
	printf '%s\n' \
		"#define ASSET_PFP \"assets/images/profile.$$pfp_hash.avif\"" \
		"#define ASSET_FONT \"assets/fonts/lmroman10-regular.$$font_hash.otf\"" > "$$tmp"; \
	mv "$$tmp" "$@"

# EOF

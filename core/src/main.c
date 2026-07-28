// SPDX-FileCopyrightText: 2026 Sergio Bonatto
// SPDX-License-Identifier: MIT

#include "pages.h"
#include "render.h"
#include "router.h"
#include "state.h"
#include "sys.h"
#include "ui.h"

#include <emscripten.h>
#include <string.h>

struct site_state state = {.runtime = 0.0f,
			   .is_dark = false,
			   .theme   = &theme_light,
			   .page    = PAGE_INITIAL};

int main(void) {
	char initial_hash[256];

	state.is_dark = sys_load_theme( ) == 1;
	state.theme   = state.is_dark ? &theme_dark : &theme_light;

	init_graphics(state.theme, UI_HEADER_HEIGHT);
	update_theme_colors(state.theme, palette);

	apply_style("#feed", css_feed);
	ui_render_header( );

	ui_init_router( );
	ui_get_current_hash(initial_hash, sizeof(initial_hash));

	if (initial_hash[0] != '\0' && strcmp(initial_hash, "#/") != 0) {
		handle_route(initial_hash);
	} else {
		switch_page(false);
	}

	page_add_footer( );
	draw_frame( );

	return 0;
}

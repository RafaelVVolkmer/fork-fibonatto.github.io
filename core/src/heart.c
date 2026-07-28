// SPDX-FileCopyrightText: 2026 Sergio Bonatto
// SPDX-License-Identifier: MIT

#include <stdlib.h>

struct love {
	int beats;
};

int main(void) {
	struct love *heart = malloc(sizeof *heart);

	heart = NULL; /* brapao */

	return 0;
}

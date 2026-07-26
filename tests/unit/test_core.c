// SPDX-FileCopyrightText: 2026 Sergio Bonatto
// SPDX-License-Identifier: MIT

#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

#include "buffer.h"
#include "config.h"
#include "markdown.h"
#include "math.h"
#include "ui.h"

static int graph_calls;
static int image_calls;
static int code_calls;

static void assert_contains(const char *haystack, const char *needle)
{
	if (strstr(haystack, needle) == NULL) {
		fprintf(stderr, "Expected output to contain: %s\n", needle);
		fprintf(stderr, "Actual output: %s\n", haystack);
		assert(false);
	}
}

void add_code_block(struct str_view lang, struct str_view code)
{
	code_calls++;
	buf_append(&g_html_buf, "<pre data-lang=\"");
	buf_append_attr_escaped(&g_html_buf, lang.data, lang.len);
	buf_append(&g_html_buf, "\"><code>");
	buf_escape(&g_html_buf, code.data, code.len);
	buf_append(&g_html_buf, "</code></pre>");
}

void add_image(const char *path, size_t path_len, const char *alt,
	       size_t alt_len, float scale, int width, int height, int is_lcp)
{
	(void)scale;
	(void)width;
	(void)height;
	(void)is_lcp;
	image_calls++;
	buf_append(&g_html_buf, "<img src=\"");
	buf_append_attr_escaped(&g_html_buf, path, path_len);
	buf_append(&g_html_buf, "\" alt=\"");
	if (alt != NULL) {
		buf_append_attr_escaped(&g_html_buf, alt, alt_len);
	}
	buf_append(&g_html_buf, "\">");
}

void add_bar(int height, int width, const float *pcts, const char **colors,
	     const float *opacities, const int *styles, int count)
{
	(void)height;
	(void)width;
	(void)pcts;
	(void)colors;
	(void)opacities;
	(void)styles;
	graph_calls += count > 0 ? 1 : 0;
	buf_append(&g_html_buf, "<div data-test=\"graph\"></div>");
}

const char *get_article_body(int index)
{
	return index == 0 ? "# Article\nBody" : NULL;
}

static void test_buffer(void)
{
	Buffer buffer;
	char fill[BUFFER_CAPACITY];

	memset(fill, 'x', sizeof(fill));
	buf_reset(&buffer);
	assert(buffer.len == 0U);
	assert(strcmp(buffer.data, "") == 0);
	assert(!buf_overflowed(&buffer));

	buf_append(&buffer, "<unsafe>");
	buf_append(&buffer, " ");
	buf_escape(&buffer, "&\"'", 3U);
	assert(strcmp(buffer.data, "<unsafe> &amp;&quot;&#39;") == 0);

	buf_reset(&buffer);
	buf_printf(&buffer, "%s:%d", "value", 42);
	assert(strcmp(buffer.data, "value:42") == 0);

	buf_reset(&buffer);
	buf_append_len(&buffer, fill, sizeof(fill));
	assert(buf_overflowed(&buffer));
	assert(buffer.data[0] == '\0');
}

static void test_math(void)
{
	Buffer buffer;

	buf_reset(&buffer);
	math_to_mathml(&buffer, "x^2 + \\frac{1}{y}",
		       strlen("x^2 + \\frac{1}{y}"), false);
	assert_contains(buffer.data, "<math ");
	assert_contains(buffer.data, "<msup>");
	assert_contains(buffer.data, "<mfrac>");
	assert_contains(buffer.data, "</math>");

	buf_reset(&buffer);
	math_to_mathml(&buffer, "\\text{safe<&}", strlen("\\text{safe<&}"),
		       true);
	assert_contains(buffer.data, "display=\"block\"");
	assert_contains(buffer.data, "&lt;");
}

static void test_markdown(void)
{
	const char *document =
		"---\n"
		"title: ignored\n"
		"---\n"
		"# Heading\n"
		"Text <unsafe> and $x_1^2$.\n"
		"![alt<](assets/image.png)\n"
		"[[graph:100,20;0.5,--accent,1.0,s]]\n"
		"```c\n"
		"int value = 1 < 2;\n"
		"```\n";

	graph_calls = 0;
	image_calls = 0;
	code_calls = 0;
	buf_reset(&g_html_buf);
	render_markdown(document);

	assert_contains(g_html_buf.data, "<h1 class=\"para\">Heading</h1>");
	assert_contains(g_html_buf.data, "Text &lt;unsafe&gt; and <math ");
	assert_contains(g_html_buf.data, "<msubsup>");
	assert_contains(g_html_buf.data, "<img src=\"assets/image.png\"");
	assert_contains(g_html_buf.data, "alt=\"alt&lt;\"");
	assert_contains(g_html_buf.data, "int value = 1 &lt; 2;");
	assert(strstr(g_html_buf.data, "title: ignored") == NULL);
	assert(graph_calls == 1);
	assert(image_calls == 1);
	assert(code_calls == 1);

	buf_reset(&g_html_buf);
	render_markdown("Unclosed $math");
	assert_contains(g_html_buf.data, "Unclosed $math");

	buf_reset(&g_html_buf);
	load_article(0);
	assert_contains(g_html_buf.data, "<h1 class=\"para\">Article</h1>");
}

int main(void)
{
	test_buffer();
	test_math();
	test_markdown();
	puts("Sanitizer unit tests passed.");
	return 0;
}

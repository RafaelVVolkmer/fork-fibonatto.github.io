// SPDX-FileCopyrightText: 2026 Sergio Bonatto
// SPDX-License-Identifier: MIT

#ifndef PROJECT_SRC_BUFFER_H
#define PROJECT_SRC_BUFFER_H

#include <stddef.h>
#include <stdarg.h>
#include <stdbool.h>

#define BUFFER_CAPACITY (128 * 1024)

#if defined(__clang__) || defined(__GNUC__)
#define EHS_PRINTF_FORMAT(format_index, first_argument) \
    __attribute__((format(printf, format_index, first_argument)))
#else
#define EHS_PRINTF_FORMAT(format_index, first_argument)
#endif

typedef struct {
    char data[BUFFER_CAPACITY];
    size_t len;
    bool overflow;
} Buffer;

extern Buffer g_html_buf;

void buf_reset(Buffer *b);
void buf_append(Buffer *b, const char *str);
void buf_append_len(Buffer *b, const char *str, size_t len);
void buf_printf(Buffer *b, const char *fmt, ...) EHS_PRINTF_FORMAT(2, 3);
void buf_escape(Buffer *b, const char *str, size_t len);
void buf_append_attr_escaped(Buffer *b, const char *str, size_t len);
bool buf_overflowed(const Buffer *b);

#endif

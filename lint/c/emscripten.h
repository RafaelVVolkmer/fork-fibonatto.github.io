// SPDX-FileCopyrightText: 2026 Sergio Bonatto
// SPDX-License-Identifier: MIT

// Minimal compatibility declarations for host-side C linting.
#ifndef EHS_LINT_EMSCRIPTEN_H
#define EHS_LINT_EMSCRIPTEN_H

#define EMSCRIPTEN_KEEPALIVE
#define EM_JS(return_type, name, parameters, ...) return_type name parameters

#endif

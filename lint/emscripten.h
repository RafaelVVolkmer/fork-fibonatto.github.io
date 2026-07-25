#ifndef EHS_LINT_EMSCRIPTEN_H
#define EHS_LINT_EMSCRIPTEN_H

#define EMSCRIPTEN_KEEPALIVE
#define EM_JS(return_type, name, parameters, ...) return_type name parameters

#endif

# SPDX-FileCopyrightText: 2026 Sergio Bonatto
# SPDX-License-Identifier: MIT

SHELL := /bin/bash

# Every user-facing invocation is replayed once through the logging wrapper.
# Recursive makes inherit EHS_LOGGED_MAKE=1 and therefore execute the real
# build graph without producing duplicate logs.
ifeq ($(EHS_LOGGED_MAKE),)

REQUESTED_GOALS := $(if $(MAKECMDGOALS),$(MAKECMDGOALS),release)
NO_LOG_GOALS := clean logs-clean distclean dist-clean

.DEFAULT_GOAL := _logged-dispatch
.PHONY: _logged-dispatch $(REQUESTED_GOALS)

$(REQUESTED_GOALS): _logged-dispatch

_logged-dispatch:
ifneq ($(filter $(NO_LOG_GOALS),$(REQUESTED_GOALS)),)
	@EHS_LOGGED_MAKE=1 "$(MAKE)" --no-print-directory \
		$(foreach goal,$(REQUESTED_GOALS),"$(goal)")
else
	@./scripts/runner.sh make "$(MAKE)" \
		$(foreach goal,$(REQUESTED_GOALS),"$(goal)")
endif

else

.DEFAULT_GOAL := release
.DELETE_ON_ERROR:
.SUFFIXES:

include mk/config.mk
include mk/flags.mk
include mk/targets.mk
include mk/generated.mk
include mk/pipeline.mk

endif

# EOF

# SPDX-License-Identifier: GPL-2.0
TEST_PROGS := \
	latency-balance-raid1.sh

TEST_FILES := lib.sh

# Prefer the kselftest harness when ../../lib.mk is present; fall back to
# a self-contained runner when it is not (e.g. in a partial tree).  The
# tests also run directly as ./latency-balance-*.sh (exit 0=pass, 1=fail,
# 4=skip).
ifneq ($(wildcard ../../lib.mk),)
include ../../lib.mk
else
.PHONY: all clean run_tests
all:
clean:
run_tests:
	@pass=0; fail=0; skip=0; \
	for t in $(TEST_PROGS); do \
		printf '# %s\n' "$$t"; \
		timeout 900 ./$$t; rc=$$?; \
		case $$rc in \
		0) pass=$$((pass+1));; \
		4) skip=$$((skip+1));; \
		*) fail=$$((fail+1));; \
		esac; \
	done; \
	printf '# pass=%d fail=%d skip=%d\n' "$$pass" "$$fail" "$$skip" >&2; \
	[ $$fail -eq 0 ]
endif

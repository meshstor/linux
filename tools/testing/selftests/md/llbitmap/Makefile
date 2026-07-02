# SPDX-License-Identifier: GPL-2.0
# Makefile for llbitmap selftests.
#
# These reproducers drive fault injection (dm-flakey, direct on-disk super
# edits) against an llbitmap-backed array and assert the kernel's failure
# handling.  lib.sh holds the shared helpers and documents the runtime
# requirements (loaded modules + a major-252-aware mdadm); each test SKIPs
# (exit 4) when they are absent.

TEST_PROGS := \
	test_torn_state_write_error_llbitmap.sh \
	test_torn_state_write_error_md_bitmap.sh

TEST_FILES := lib.sh

include ../../../lib.mk

# SPDX-License-Identifier: GPL-2.0
# Makefile for llbitmap selftests.
#
# These reproducers drive fault injection (dm-flakey, direct on-disk super
# edits) against an md array and assert the kernel's failure handling.
# lib.sh holds the shared helpers and documents the runtime requirements
# (loaded modules + an mdadm that understands the array under test); each
# test SKIPs (exit 4) when they are absent.

TEST_PROGS := \
	test_classic_bitmap_double_degraded_re_add.sh

TEST_FILES := lib.sh

include ../../../lib.mk

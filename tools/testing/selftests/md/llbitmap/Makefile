# SPDX-License-Identifier: GPL-2.0
# Makefile for llbitmap selftests.
#
# These reproducers drive fault injection (dm-flakey, direct on-disk super
# edits) against an llbitmap-backed array and assert the kernel's failure
# handling.  lib.sh holds the shared helpers and documents the runtime
# requirements (loaded modules + a major-252-aware mdadm); each test SKIPs
# (exit 4) when they are absent.

TEST_PROGS := \
	test_read_sb_unmap_highmem.sh \
	test_cache_pages_enomem_double_free.sh \
	test_classic_bitmap_double_degraded_re_add.sh \
	test_first_use_persist_failure.sh \
	test_first_use_persist_data_page_failure.sh \
	test_grow_resize_pctl.sh \
	test_recovery_degraded_writes.sh \
	test_resize_race_concurrent_write.sh \
	test_shrink_regrow_stale_state.sh \
	test_torn_state_write_error_llbitmap.sh \
	test_torn_state_write_error_md_bitmap.sh \
	test_assemble_kick_non_fresh.sh \
	test_first_use_persists.sh \
	test_lbs_stability.sh \
	test_mode_a_chunksize_einval.sh \
	test_mode_b_concurrent_io.sh \
	test_mode_b_data_persists.sh \
	test_mode_b_spare_recovers.sh \
	test_stop_events_sync.sh

TEST_FILES := lib.sh

include ../../../lib.mk

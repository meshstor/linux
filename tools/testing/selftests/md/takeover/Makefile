# SPDX-License-Identifier: GPL-2.0
TEST_PROGS := \
	test_r1_to_r10_basic.sh \
	test_r1_to_r10_odd_disks.sh \
	test_r1_to_r10_even_disks.sh \
	test_r1_to_r10_preserve_data.sh \
	test_r1_to_r10_per_leg_identity.sh \
	test_r1_to_r10_ext4_fsck.sh \
	test_r1_to_r10_no_resync.sh \
	test_r1_to_r10_bitmap.sh \
	test_r1_to_r10_no_bitmap.sh \
	test_r1_to_r10_chunk_unset.sh \
	test_r1_to_r10_chunk_misaligned_refusal.sh \
	test_r1_to_r10_chunk_shrink_fallback.sh \
	test_r1_to_r10_degraded.sh \
	test_r1_to_r10_write_mostly.sh \
	test_r1_to_r10_write_behind.sh \
	test_r1_to_r10_single_disk.sh \
	test_r1_to_r10_v090.sh \
	test_r1_to_r10_external_size.sh \
	test_r1_to_r10_refusal_leaves_array_intact.sh \
	test_r1_to_r10_persist_assemble.sh \
	test_r1_to_r10_grow_cli.sh \
	test_r1_to_r10_grow_io_continuous.sh \
	test_r1_to_r10_reverse_rejected.sh \
	test_r1_to_r10_wrong_target.sh \
	test_r1_to_r10_events_advance.sh \
	test_r1_to_r10_unequal_sizes.sh \
	test_r1_to_r10_msstat_format.sh \
	test_r1_to_r10_no_kernel_splat.sh \
	test_r1_to_r10_array_state.sh

TEST_FILES := lib.sh

# Prefer the upstream kselftest harness when ../../lib.mk is vendored in this
# tree.  It is not present on the meshstor lineage, so fall back to a
# self-contained runner; in practice these tests are run directly as
# ./test_r1_to_r10_*.sh (exit 0=pass, 1=fail, 4=skip).
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

# SPDX-License-Identifier: GPL-2.0
# P2PDMA fail-the-write selftests. Everything below boots a QEMU VM
# (host kernel via virtme-ng) with emulated NVMe: one CMB device donates
# real p2pdma pages, two more are the raid1/raid10 members. lib.sh
# documents the runtime requirements; each test SKIPs (exit 4) without them.

TEST_PROGS := \
	test_rig_cmb_provider.sh \
	test_symmetric_write_succeeds.sh \
	test_asymmetric_write_fails_einval.sh \
	test_all_unreachable_write_fails.sh \
	test_read_returns_einval.sh \
	test_stop_clean_after_p2p_error.sh \
	test_raid10_asymmetric_write.sh \
	test_target_status_arm.sh \
	test_mixed_error.sh

TEST_FILES := lib.sh run_vm.sh modules

include ../../lib.mk

# SPDX-License-Identifier: GPL-2.0
# P2PDMA selftests (v6 semantics). Everything below boots a QEMU VM
# (host kernel via virtme-ng) with emulated NVMe: one CMB device donates
# real p2pdma pages, two more are the raid1/raid10 members. lib.sh
# documents the runtime requirements; each test SKIPs (exit 4) without
# them. run_all.sh is the preferred entry point (per-test timeout,
# pass/fail/skip summary); this Makefile/lib.mk wiring is kept for
# consistency with the rest of tools/testing/selftests.

TEST_PROGS := \
	test_rig_cmb_provider.sh \
	test_symmetric_io_succeeds.sh \
	test_stop_clean_after_p2p_error.sh \
	test_topology_single_leg_unreachable.sh \
	test_topology_raid10_single_leg_unreachable.sh \
	test_topology_all_legs_unreachable.sh \
	test_status_matrix_injected.sh \
	test_status_target_tagged_ambiguity.sh \
	test_mixed_error.sh \
	test_badblocks_bounded_not_faulted.sh \
	test_badblocks_exhaustion_faults_member.sh \
	test_divergence_oracle.sh \
	test_narrow_write_error_reentry.sh \
	test_mixed_pgmap_untagged.sh \
	test_errno_never_zero_on_total_failure.sh \
	test_knob_advertise_hotadd.sh \
	test_diagnosability_p2pdma_status.sh \
	test_rwf_nowait_behaviour_capture.sh

TEST_FILES := lib.sh run_vm.sh modules

include ../../lib.mk

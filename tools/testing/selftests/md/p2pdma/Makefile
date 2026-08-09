# SPDX-License-Identifier: GPL-2.0
# P2PDMA fail-the-write selftests. Everything below boots a QEMU VM
# (host kernel via virtme-ng) with emulated NVMe: one CMB device donates
# real p2pdma pages, two more are the raid1/raid10 members. lib.sh
# documents the runtime requirements; each test SKIPs (exit 4) without them.

TEST_PROGS := \
	test_rig_cmb_provider.sh

TEST_FILES := lib.sh run_vm.sh modules

include ../../lib.mk

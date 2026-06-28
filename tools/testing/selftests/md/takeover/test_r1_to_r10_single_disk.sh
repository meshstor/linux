#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Precondition #1: raid_disks < 2 must be rejected.
. "$(dirname "$0")/lib.sh"
md_require_root
md_require_tools
md_require_modules

loop0="$(md_make_loop 64)"
MD_TEST_MD_DEV="$(md_find_free_md_dev)"

# 1-disk raid1 is degenerate but legal.
md_mdadm --create --run --force --metadata=1.2 --level=1 --raid-devices=1 \
	"$MD_TEST_MD_DEV" "$loop0" >/dev/null 2>&1 \
	|| md_skip "kernel refused 1-disk raid1"
md_wait_sync "$MD_TEST_MD_DEV"

sysfs="$(md_sysfs_path "$MD_TEST_MD_DEV")"

md_clear_dmesg
if echo raid10 > "$sysfs/level" 2>/dev/null; then
	md_fail "takeover accepted 1-disk raid1"
fi

if ! md_dmesg_contains "need at least 2 disks"; then
	md_fail "missing pr_warn about disk count"
fi

md_pass "takeover correctly refused 1-disk raid1"

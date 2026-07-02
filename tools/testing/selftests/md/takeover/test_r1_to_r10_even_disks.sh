#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# 4-disk raid1 -> raid10_near(4,4), layout = (1<<8)|4 = 260.
# Counterpart to test_r1_to_r10_odd_disks.sh, covering an even disk
# count distinct from the 2-disk basic case.
. "$(dirname "$0")/lib.sh"
md_require_root
md_require_tools
md_require_modules

loop0="$(md_make_loop 64)"
loop1="$(md_make_loop 64)"
loop2="$(md_make_loop 64)"
loop3="$(md_make_loop 64)"
MD_TEST_MD_DEV="$(md_find_free_md_dev)"

md_mdadm --create --run --metadata=1.2 --level=1 --raid-devices=4 \
	"$MD_TEST_MD_DEV" "$loop0" "$loop1" "$loop2" "$loop3" >/dev/null 2>&1 \
	|| md_fail "could not create 4-disk raid1"
md_wait_sync "$MD_TEST_MD_DEV"

sysfs="$(md_sysfs_path "$MD_TEST_MD_DEV")"

md_sysfs_write "$sysfs/level" raid10 \
	|| md_fail "takeover failed on 4-disk raid1"

layout="$(md_sysfs_read "$sysfs/layout")"
[ "$layout" = "260" ] || md_fail "layout not 260 (got: $layout)"

raid_disks="$(md_sysfs_read "$sysfs/raid_disks")"
[ "$raid_disks" = "4" ] || md_fail "raid_disks changed (got: $raid_disks)"

md_pass "4-disk raid1 -> raid10_near(4,4)"

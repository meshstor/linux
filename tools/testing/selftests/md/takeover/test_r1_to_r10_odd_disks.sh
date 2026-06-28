#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# 3-disk raid1 -> raid10_near(3,3), layout = (1<<8)|3 = 259.
. "$(dirname "$0")/lib.sh"
md_require_root
md_require_tools
md_require_modules

loop0="$(md_make_loop 64)"
loop1="$(md_make_loop 64)"
loop2="$(md_make_loop 64)"
MD_TEST_MD_DEV="$(md_find_free_md_dev)"

md_mdadm --create --run --metadata=1.2 --level=1 --raid-devices=3 \
	"$MD_TEST_MD_DEV" "$loop0" "$loop1" "$loop2" >/dev/null 2>&1 \
	|| md_fail "could not create 3-disk raid1"
md_wait_sync "$MD_TEST_MD_DEV"

sysfs="$(md_sysfs_path "$MD_TEST_MD_DEV")"

md_sysfs_write "$sysfs/level" raid10 \
	|| md_fail "takeover failed on 3-disk raid1"

layout="$(md_sysfs_read "$sysfs/layout")"
[ "$layout" = "259" ] || md_fail "layout not 259 (got: $layout)"

raid_disks="$(md_sysfs_read "$sysfs/raid_disks")"
[ "$raid_disks" = "3" ] || md_fail "raid_disks changed (got: $raid_disks)"

md_pass "3-disk raid1 -> raid10_near(3,3)"

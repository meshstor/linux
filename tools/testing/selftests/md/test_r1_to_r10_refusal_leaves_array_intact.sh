#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Atomicity: a refused takeover (any precondition) must leave the
# array's geometry untouched. The helper returns ERR_PTR BEFORE
# writing any of mddev->new_level / new_layout / new_chunk_sectors,
# and level_store() rolls back delta_disks on failure (md.c:4157).
# This test verifies the observable state.
. "$(dirname "$0")/lib.sh"
md_require_root
md_require_tools
md_require_modules

loop0="$(md_make_loop 64)"
loop1="$(md_make_loop 64)"
MD_TEST_MD_DEV="$(md_find_free_md_dev)"

# write-mostly causes precondition #4 to reject the takeover.
md_mdadm --create --run --metadata=1.2 --level=1 --raid-devices=2 \
	"$MD_TEST_MD_DEV" "$loop0" --write-mostly "$loop1" >/dev/null 2>&1 \
	|| md_fail "could not create raid1 w/ write-mostly"
md_wait_sync "$MD_TEST_MD_DEV"

sysfs="$(md_sysfs_path "$MD_TEST_MD_DEV")"

before_level="$(md_sysfs_read "$sysfs/level")"
before_layout="$(md_sysfs_read "$sysfs/layout")"
before_chunk="$(md_sysfs_read "$sysfs/chunk_size")"
before_raid_disks="$(md_sysfs_read "$sysfs/raid_disks")"

# Provoke a failed takeover.
if echo raid10 > "$sysfs/level" 2>/dev/null; then
	md_fail "takeover unexpectedly accepted"
fi

after_level="$(md_sysfs_read "$sysfs/level")"
after_layout="$(md_sysfs_read "$sysfs/layout")"
after_chunk="$(md_sysfs_read "$sysfs/chunk_size")"
after_raid_disks="$(md_sysfs_read "$sysfs/raid_disks")"

[ "$after_level" = "$before_level" ] \
	|| md_fail "level changed across refusal: $before_level -> $after_level"
[ "$after_layout" = "$before_layout" ] \
	|| md_fail "layout changed across refusal: $before_layout -> $after_layout"
[ "$after_chunk" = "$before_chunk" ] \
	|| md_fail "chunk_size changed across refusal: $before_chunk -> $after_chunk"
[ "$after_raid_disks" = "$before_raid_disks" ] \
	|| md_fail "raid_disks changed across refusal: $before_raid_disks -> $after_raid_disks"

# The array must still be writable after the refusal so the admin
# can fix the precondition and retry.
dd if=/dev/zero of="$MD_TEST_MD_DEV" bs=1M count=1 oflag=direct \
	>/dev/null 2>&1 || md_fail "array no longer accepts writes after refused takeover"

md_pass "refused takeover left array geometry and IO path intact"

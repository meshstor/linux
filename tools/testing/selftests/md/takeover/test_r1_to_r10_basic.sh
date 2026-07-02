#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Golden path: 2-disk healthy raid1 converts to raid10 near=2 via sysfs.

. "$(dirname "$0")/lib.sh"

md_require_root
md_require_tools
md_require_modules

loop0="$(md_make_loop 64)"
loop1="$(md_make_loop 64)"
MD_TEST_MD_DEV="$(md_find_free_md_dev)"

md_mdadm --create --run --metadata=1.2 --level=1 --raid-devices=2 \
	"$MD_TEST_MD_DEV" "$loop0" "$loop1" >/dev/null 2>&1 \
	|| md_fail "could not create raid1"
md_wait_sync "$MD_TEST_MD_DEV"

sysfs="$(md_sysfs_path "$MD_TEST_MD_DEV")"

# Trigger the takeover. The helper chooses chunk_size (512 KiB default)
# because raid1 does not permit sysfs chunk_size writes.
md_sysfs_write "$sysfs/level" raid10 \
	|| md_fail "level=raid10 write failed (pre-patch: expected -EINVAL)"

# Verify the new state.
level="$(md_sysfs_read "$sysfs/level")"
[ "$level" = "raid10" ] || md_fail "level not raid10 after takeover (got: $level)"

layout="$(md_sysfs_read "$sysfs/layout")"
# raid_disks=2, near_copies=2, far_copies=1 => (1<<8)|2 = 258 = 0x102
[ "$layout" = "258" ] || md_fail "layout not 258 (got: $layout)"

raid_disks="$(md_sysfs_read "$sysfs/raid_disks")"
[ "$raid_disks" = "2" ] || md_fail "raid_disks changed (got: $raid_disks)"

# Helper picked the 512 KiB default chunk.
chunk="$(md_sysfs_read "$sysfs/chunk_size")"
[ "$chunk" = "524288" ] || md_fail "chunk_size not 512 KiB (got: $chunk)"

# No spurious resync.
sync_action="$(md_sysfs_read "$sysfs/sync_action" 2>/dev/null || echo idle)"
[ "$sync_action" = "idle" ] || md_fail "spurious sync_action: $sync_action"

md_pass "basic raid1 -> raid10 near=2"

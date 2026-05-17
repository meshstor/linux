#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Persistence: after a successful takeover, --stop + --assemble must
# bring the array back as raid10 with the same geometry. Verifies that
# the new level, layout, chunk_size and resync_offset=MaxSector are
# written to the on-disk superblock by the post-takeover md_update_sb
# (md.c:4271 set_bit MD_SB_CHANGE_DEVS).
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

# Lay down a known pattern so we can verify byte-identity across
# the stop/assemble cycle as well.
dd if=/dev/urandom of="$MD_TEST_MD_DEV" bs=1M count=16 oflag=direct \
	>/dev/null 2>&1 || md_fail "initial dd failed"
sync

sysfs="$(md_sysfs_path "$MD_TEST_MD_DEV")"
md_sysfs_write "$sysfs/level" raid10 \
	|| md_fail "takeover failed"

sync
before="$(md5sum < "$MD_TEST_MD_DEV" | awk '{print $1}')"

md_mdadm --stop "$MD_TEST_MD_DEV" >/dev/null 2>&1 \
	|| md_fail "could not stop array"
udevadm settle >/dev/null 2>&1

md_mdadm --assemble "$MD_TEST_MD_DEV" "$loop0" "$loop1" >/dev/null 2>&1 \
	|| md_fail "could not reassemble array"
udevadm settle >/dev/null 2>&1

sysfs="$(md_sysfs_path "$MD_TEST_MD_DEV")"
level="$(md_sysfs_read "$sysfs/level")"
[ "$level" = "raid10" ] || md_fail "level not raid10 after reassemble (got: $level)"

layout="$(md_sysfs_read "$sysfs/layout")"
[ "$layout" = "258" ] || md_fail "layout not 258 after reassemble (got: $layout)"

chunk="$(md_sysfs_read "$sysfs/chunk_size")"
[ "$chunk" = "524288" ] || md_fail "chunk_size not 512 KiB after reassemble (got: $chunk)"

# resync_offset=MaxSector means no resync triggered on reassemble.
action="$(md_sysfs_read "$sysfs/sync_action" 2>/dev/null || echo idle)"
[ "$action" = "idle" ] || md_fail "spurious resync after reassemble: $action"

# Data still intact.
after="$(md5sum < "$MD_TEST_MD_DEV" | awk '{print $1}')"
[ "$before" = "$after" ] \
	|| md_fail "data corrupted across stop+assemble: $before != $after"

md_pass "raid10 geometry and data survived stop+assemble"

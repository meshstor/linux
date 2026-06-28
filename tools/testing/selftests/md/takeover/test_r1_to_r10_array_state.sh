#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# array_state must remain a healthy 'clean' or 'active' after the
# takeover (not 'broken' / 'suspended' / 'readonly'). Also confirms
# the degraded counter resets to 0 — md.c:4185 unconditionally
# clears mddev->degraded inside the post-takeover spin_lock block.
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
md_sysfs_write "$sysfs/level" raid10 \
	|| md_fail "takeover failed"

# A healthy array_state on an array that stayed raid1 would pass the
# checks below; assert the takeover actually happened first.
level="$(md_sysfs_read "$sysfs/level")"
[ "$level" = "raid10" ] || md_fail "level not raid10 after takeover: $level"

state="$(md_sysfs_read "$sysfs/array_state")"
case "$state" in
	clean|active|active-idle) ;;
	*) md_fail "unhealthy array_state after takeover: $state";;
esac

degraded="$(md_sysfs_read "$sysfs/degraded")"
[ "$degraded" = "0" ] || md_fail "degraded counter not reset (got: $degraded)"

# raid10 with all members in sync must report [UU] (or [UUU...]) on
# the status line. Read straight from /proc.
md_name="$(basename "$MD_TEST_MD_DEV")"
if ! grep -A1 "^${md_name} :" "$MD_PROC_STAT" | grep -qE '\[U+\]'; then
	md_fail "$MD_PROC_STAT not reporting fully-up array"
fi

md_pass "array_state and degraded counters healthy after takeover"

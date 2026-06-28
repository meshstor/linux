#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# level_store() does set_bit(MD_SB_CHANGE_DEVS) and md_update_sb after
# a successful takeover. The events counter must therefore advance, so
# the on-disk superblocks of the (now raid10) members carry a higher
# events value than the pre-takeover read. A reassemble that picks the
# wrong "freshest" disk would lose the level change otherwise.
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

md_name="$(basename "$MD_TEST_MD_DEV")"
# /sys/block/<dev>/<subsys-dir>/array_state needs to be 'clean' or
# 'active' for events to be settled. The events counter is exposed
# at /sys/block/<dev>/events_async (a block-layer counter that includes
# media events). The MD-specific events sit on the on-disk sb; the
# easiest way to read it is via mdadm --examine.
events_before="$(md_mdadm --examine "$loop0" 2>/dev/null \
	| awk '/Events :/{print $NF; exit}')"
[ -n "$events_before" ] || md_fail "could not read pre-takeover events counter"

sysfs="$(md_sysfs_path "$MD_TEST_MD_DEV")"
md_sysfs_write "$sysfs/level" raid10 \
	|| md_fail "takeover failed"

# Confirm the takeover actually happened; otherwise an events bump from
# unrelated sb activity could pass this test without a level change.
level="$(md_sysfs_read "$sysfs/level")"
[ "$level" = "raid10" ] || md_fail "level not raid10 after takeover: $level"

# Give md_update_sb time to write the new sb. Force a sync first.
sync
sleep 1
md_mdadm --wait "$MD_TEST_MD_DEV" >/dev/null 2>&1 || true

events_after="$(md_mdadm --examine "$loop0" 2>/dev/null \
	| awk '/Events :/{print $NF; exit}')"
[ -n "$events_after" ] || md_fail "could not read post-takeover events counter"

if [ "$events_after" -le "$events_before" ]; then
	md_fail "events counter did not advance: $events_before -> $events_after"
fi

md_pass "events counter advanced across takeover: $events_before -> $events_after"

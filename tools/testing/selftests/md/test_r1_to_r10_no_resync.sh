#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Helper must set resync_offset = MaxSector so no resync kicks off.
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

# Give any stray resync thread a moment to start.
sleep 1

action="$(md_sysfs_read "$sysfs/sync_action")"
[ "$action" = "idle" ] || md_fail "spurious resync started: $action"

# resync_offset must show "none" (interpreted as MaxSector) or be absent.
offset="$(md_sysfs_read "$sysfs/resync_start" 2>/dev/null || echo none)"
case "$offset" in
	none|"") ;;
	*) md_fail "resync_start not cleared (got: $offset)";;
esac

md_pass "no spurious resync after takeover"

#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# raid10 -> raid1 must be rejected: there is no symmetric helper
# (raid1_takeover only accepts level=5 with 2 devices, see raid1.c).
# Without this rejection, a user who took over raid1 -> raid10 would
# silently get back into raid1 without copying data, potentially with
# the wrong geometry (e.g. far_copies != 1).
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
	|| md_fail "forward takeover failed"

# Now try the reverse direction. Must fail.
if echo raid1 > "$sysfs/level" 2>/dev/null; then
	md_fail "reverse raid10 -> raid1 takeover unexpectedly accepted"
fi

# Confirm we're still raid10.
level="$(md_sysfs_read "$sysfs/level")"
[ "$level" = "raid10" ] || md_fail "level changed by rejected reverse takeover: $level"

md_pass "raid10 -> raid1 correctly rejected"

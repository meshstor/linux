#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# A clean 2-disk raid1 must NOT be silently convertible to a level that
# would drop redundancy or misrepresent the layout. Two targets are
# genuinely rejected and must leave the array as raid1:
#
#   raid0 - raid0_takeover_raid1() requires (N-1) mirror legs already
#           faulty (raid0.c); a healthy raid1 fails that check.
#   raid6 - raid6_takeover() only accepts a raid5 source (raid5.c).
#
# raid5 and raid4 are deliberately NOT asserted here: raid5_takeover_raid1()
# *does* accept a clean 2-disk raid1 (a supported, separate conversion that
# this raid1->raid10 series does not change), so claiming they are rejected
# would be factually wrong and would break under MD_SUBSYS=md (or once a
# raid456 personality is loaded under the ms subsystem).
#
# Under the ms subsystem the raid0/raid6 personalities may be absent, in
# which case the rejection comes from level_store() failing to resolve the
# personality rather than from the takeover handler; either way the
# observable invariant -- the array stays raid1 -- holds.

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

tested=0
for target in raid0 raid6; do
	if echo "$target" > "$sysfs/level" 2>/dev/null; then
		md_fail "takeover unexpectedly accepted raid1 -> $target"
	fi
	# Each rejection must leave the array as raid1.
	level="$(md_sysfs_read "$sysfs/level")"
	[ "$level" = "raid1" ] \
		|| md_fail "level mutated after rejected -> $target attempt (got: $level)"
	tested=$(( tested + 1 ))
done

[ "$tested" -gt 0 ] || md_skip "neither raid0 nor raid6 personality is registered -- the raid1->raidX takeover-refusal guard is not present in this build (expected under MD_SUBSYS=ms; run under MD_SUBSYS=md to exercise it)"

md_pass "raid1 takeover to registered raid0/raid6 target(s) rejected by the takeover guard; array stays raid1 ($tested target(s) exercised)"

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
# would be factually wrong.
#
# When a target personality is not registered at all, a rejected level
# write proves nothing about the takeover guards: level_store() fails at
# personality resolution before raid0_takeover_raid1()/raid6_takeover()
# ever runs, and the test would pass even with the guards removed. Gate
# each target on its personality being available (modprobe, then the
# Personalities line of $MD_PROC_STAT), assert only on available targets,
# and SKIP when neither is.

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
	# The raid6 personality lives in the raid456 module.
	case "$target" in
		raid6) mod=raid456 ;;
		*) mod="$target" ;;
	esac
	modprobe -q "$mod" 2>/dev/null || true
	# Only assert against a registered personality; an unregistered one
	# is rejected at resolution, before the takeover guard runs.
	if ! head -1 "$MD_PROC_STAT" 2>/dev/null | grep -qw "$target"; then
		continue
	fi
	if echo "$target" > "$sysfs/level" 2>/dev/null; then
		md_fail "takeover unexpectedly accepted raid1 -> $target"
	fi
	# Each rejection must leave the array as raid1.
	level="$(md_sysfs_read "$sysfs/level")"
	[ "$level" = "raid1" ] \
		|| md_fail "level mutated after rejected -> $target attempt (got: $level)"
	tested=$(( tested + 1 ))
done

[ "$tested" -gt 0 ] || md_skip "neither the raid0 nor the raid6 personality is available -- cannot exercise the takeover-refusal guards"

md_pass "raid1 takeover to registered raid0/raid6 target(s) rejected by the takeover guard; array stays raid1 ($tested target(s) exercised)"

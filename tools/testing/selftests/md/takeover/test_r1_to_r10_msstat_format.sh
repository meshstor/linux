#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# /proc/msstat (the ms-subsys analog of /proc/mdstat) must reflect
# the new personality and layout after takeover. This catches a class
# of bugs where the sysfs and the proc summary disagree.
. "$(dirname "$0")/lib.sh"
md_require_root
md_require_tools
md_require_modules

[ -r "$MD_PROC_STAT" ] || md_skip "$MD_PROC_STAT not readable"

loop0="$(md_make_loop 64)"
loop1="$(md_make_loop 64)"
loop2="$(md_make_loop 64)"
MD_TEST_MD_DEV="$(md_find_free_md_dev)"
md_name="$(basename "$MD_TEST_MD_DEV")"

md_mdadm --create --run --metadata=1.2 --level=1 --raid-devices=3 \
	"$MD_TEST_MD_DEV" "$loop0" "$loop1" "$loop2" >/dev/null 2>&1 \
	|| md_fail "could not create 3-disk raid1"
md_wait_sync "$MD_TEST_MD_DEV"

# Pre-takeover line must say "raid1".
grep -E "^${md_name} : active raid1 " "$MD_PROC_STAT" >/dev/null \
	|| md_fail "$MD_PROC_STAT does not report raid1 pre-takeover"

sysfs="$(md_sysfs_path "$MD_TEST_MD_DEV")"
md_sysfs_write "$sysfs/level" raid10 \
	|| md_fail "takeover failed"

# Post-takeover line must say "raid10". The next line should mention
# "near-copies" — that's the raid10_status() format.
grep -E "^${md_name} : active raid10 " "$MD_PROC_STAT" >/dev/null \
	|| md_fail "$MD_PROC_STAT does not report raid10 post-takeover"

grep -A1 "^${md_name} : active raid10 " "$MD_PROC_STAT" \
	| grep -q "near-copies" \
	|| md_fail "$MD_PROC_STAT missing 'near-copies' status line"

md_pass "$MD_PROC_STAT reports raid10 with near-copies after takeover"

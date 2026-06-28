#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Byte-identity at the physical-leg level: in raid1 each leg holds a
# full copy of the data; raid10_near(N,N) (the layout chosen by the
# helper) keeps that property because every chunk has N copies and the
# stripe maps trivially onto the same byte offset on every leg. After
# the takeover, the data offset on each leg must still match what we
# wrote pre-takeover.
#
# We read the raw data region of each loop file directly (skipping the
# 1.2 superblock + bitmap reservation = data_offset). data_offset is
# read from sysfs so this works regardless of mdadm's default.
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

# Lay down a deterministic pattern (urandom seeded by /dev/urandom).
dd if=/dev/urandom of="$MD_TEST_MD_DEV" bs=1M count=16 oflag=direct \
	>/dev/null 2>&1 || md_fail "initial dd failed"
sync

sysfs="$(md_sysfs_path "$MD_TEST_MD_DEV")"

# data_offset per leg (in 512-byte sectors).
loop0_name="$(basename "$loop0")"
loop1_name="$(basename "$loop1")"
do0="$(md_sysfs_read "$sysfs/dev-$loop0_name/offset")"
do1="$(md_sysfs_read "$sysfs/dev-$loop1_name/offset")"
[ -n "$do0" ] && [ -n "$do1" ] || md_fail "could not read per-leg data_offset"

# Capture per-leg checksum of the first 8 MiB of data, computed at
# the raw block layer (bypass the array entirely).
leg0_before="$(dd if="$loop0" bs=512 skip="$do0" count=16384 2>/dev/null | md5sum | awk '{print $1}')"
leg1_before="$(dd if="$loop1" bs=512 skip="$do1" count=16384 2>/dev/null | md5sum | awk '{print $1}')"

# Sanity: raid1 mirrors -> both legs are identical pre-takeover.
[ "$leg0_before" = "$leg1_before" ] \
	|| md_fail "raid1 legs diverged pre-takeover: $leg0_before vs $leg1_before"

md_sysfs_write "$sysfs/level" raid10 \
	|| md_fail "takeover failed"
sync

# Guard against a silent no-op: an array that stayed raid1 trivially
# preserves per-leg bytes/offsets and would pass the checks below.
level="$(md_sysfs_read "$sysfs/level")"
[ "$level" = "raid10" ] || md_fail "level not raid10 after takeover: $level"

# Re-read data_offset from the raid10 sysfs (it may move if mdadm
# rewrites the sb, though for in-place takeover it must NOT change).
sysfs="$(md_sysfs_path "$MD_TEST_MD_DEV")"
do0_after="$(md_sysfs_read "$sysfs/dev-$loop0_name/offset")"
do1_after="$(md_sysfs_read "$sysfs/dev-$loop1_name/offset")"

[ "$do0" = "$do0_after" ] \
	|| md_fail "data_offset on leg0 moved across takeover: $do0 -> $do0_after"
[ "$do1" = "$do1_after" ] \
	|| md_fail "data_offset on leg1 moved across takeover: $do1 -> $do1_after"

leg0_after="$(dd if="$loop0" bs=512 skip="$do0_after" count=16384 2>/dev/null | md5sum | awk '{print $1}')"
leg1_after="$(dd if="$loop1" bs=512 skip="$do1_after" count=16384 2>/dev/null | md5sum | awk '{print $1}')"

[ "$leg0_before" = "$leg0_after" ] \
	|| md_fail "leg0 data changed across takeover: $leg0_before -> $leg0_after"
[ "$leg1_before" = "$leg1_after" ] \
	|| md_fail "leg1 data changed across takeover: $leg1_before -> $leg1_after"

md_pass "per-leg data identity preserved across takeover"

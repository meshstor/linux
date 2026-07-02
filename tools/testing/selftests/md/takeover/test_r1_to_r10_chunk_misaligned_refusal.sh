#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# The chunk-alignment refusal is the takeover's core data-safety guard:
# raid10_size() floors the array to whole chunks, so a member size that
# no power-of-2 chunk >= PAGE_SIZE divides would silently shrink the
# array and drop the tail (ext4 backup superblocks, last extents). The
# helper must refuse instead. Shrink the raid1's component_size to
# K*512 + 1 KiB -- dev_sectors == 2 (mod 8), indivisible by the minimum
# chunk on any page size -- and verify the takeover is refused, the
# array stays raid1, and data is intact.
. "$(dirname "$0")/lib.sh"
md_require_root
md_require_tools
md_require_modules
md_require_takeover

loop0="$(md_make_loop 64)"
loop1="$(md_make_loop 64)"
MD_TEST_MD_DEV="$(md_find_free_md_dev)"

md_mdadm --create --run --metadata=1.2 --level=1 --raid-devices=2 \
	"$MD_TEST_MD_DEV" "$loop0" "$loop1" >/dev/null 2>&1 \
	|| md_fail "could not create raid1"
md_wait_sync "$MD_TEST_MD_DEV"

sysfs="$(md_sysfs_path "$MD_TEST_MD_DEV")"

# component_size is in KiB; shrinking an active clean raid1 is an
# online resize and leaves resync_offset untouched, so every other
# takeover precondition still holds.
natural_kb="$(md_sysfs_read "$sysfs/component_size")"
misaligned_kb=$(( (natural_kb / 512 - 1) * 512 + 1 ))
[ "$misaligned_kb" -gt 0 ] || md_fail "array too small to misalign"
echo "$misaligned_kb" > "$sysfs/component_size" \
	|| md_fail "could not shrink component_size to ${misaligned_kb}K"
got_kb="$(md_sysfs_read "$sysfs/component_size")"
[ "$got_kb" = "$misaligned_kb" ] \
	|| md_fail "component_size did not stick (want $misaligned_kb, got $got_kb)"

# Data written before the attempt must be untouched after the refusal.
"$DD" if=/dev/urandom of="$MD_TEST_MD_DEV" bs=1M count=8 oflag=direct \
	>/dev/null 2>&1 || md_fail "initial dd failed"
sync
md5_before="$("$DD" if="$MD_TEST_MD_DEV" bs=1M count=8 iflag=direct \
	2>/dev/null | md5sum | awk '{print $1}')"

md_clear_dmesg
if echo raid10 > "$sysfs/level" 2>/dev/null; then
	md_fail "takeover accepted a non-chunk-aligned member size"
fi

if ! md_dmesg_contains "not chunk-aligned"; then
	md_fail "missing pr_warn about non-chunk-aligned member size"
fi

level="$(md_sysfs_read "$sysfs/level")"
[ "$level" = "raid1" ] || md_fail "level changed after refusal: $level"

md5_after="$("$DD" if="$MD_TEST_MD_DEV" bs=1M count=8 iflag=direct \
	2>/dev/null | md5sum | awk '{print $1}')"
[ "$md5_after" = "$md5_before" ] \
	|| md_fail "data changed across refused takeover: $md5_before -> $md5_after"

md_pass "takeover refused non-chunk-aligned member size; array intact"

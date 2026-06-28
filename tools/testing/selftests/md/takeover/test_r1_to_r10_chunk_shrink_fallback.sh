#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# When the member size is PAGE_SIZE-aligned but no 512 KiB chunk
# divides it, the helper halves the chunk until one fits rather than
# refusing (raid5_takeover_raid1 does the same). For near_copies ==
# raid_disks the chunk is semantically irrelevant, so the takeover must
# succeed with the smaller chunk and an identical array size and data.
# component_size = K*512 + PAGE_SIZE/1024 KiB makes dev_sectors
# divisible by PAGE_SIZE but by no larger power-of-2 chunk, forcing the
# halving loop all the way down to exactly PAGE_SIZE.
. "$(dirname "$0")/lib.sh"
md_require_root
md_require_tools
md_require_modules

page_b="$(getconf PAGESIZE 2>/dev/null)" || page_b=4096
page_kb=$((page_b / 1024))

loop0="$(md_make_loop 64)"
loop1="$(md_make_loop 64)"
MD_TEST_MD_DEV="$(md_find_free_md_dev)"

md_mdadm --create --run --metadata=1.2 --level=1 --raid-devices=2 \
	"$MD_TEST_MD_DEV" "$loop0" "$loop1" >/dev/null 2>&1 \
	|| md_fail "could not create raid1"
md_wait_sync "$MD_TEST_MD_DEV"

md_name="$(basename "$MD_TEST_MD_DEV")"
sysfs="$(md_sysfs_path "$MD_TEST_MD_DEV")"

natural_kb="$(md_sysfs_read "$sysfs/component_size")"
odd_kb=$(( (natural_kb / 512 - 1) * 512 + page_kb ))
[ "$odd_kb" -gt 0 ] || md_fail "array too small for shrink-fallback sizing"
echo "$odd_kb" > "$sysfs/component_size" \
	|| md_fail "could not shrink component_size to ${odd_kb}K"

dd if=/dev/urandom of="$MD_TEST_MD_DEV" bs=1M count=8 oflag=direct \
	>/dev/null 2>&1 || md_fail "initial dd failed"
sync
md5_before="$(dd if="$MD_TEST_MD_DEV" bs=1M count=8 iflag=direct \
	2>/dev/null | md5sum | awk '{print $1}')"
size_before="$(md_sysfs_read "/sys/block/$md_name/size")"

md_sysfs_write "$sysfs/level" raid10 \
	|| md_fail "takeover refused a PAGE_SIZE-aligned member size"

level="$(md_sysfs_read "$sysfs/level")"
[ "$level" = "raid10" ] || md_fail "level not raid10 after takeover: $level"

chunk_b="$(md_sysfs_read "$sysfs/chunk_size")"
[ "$chunk_b" = "$page_b" ] \
	|| md_fail "expected chunk to shrink to PAGE_SIZE=$page_b, got $chunk_b"

# The whole point of the alignment dance: the array must NOT shrink.
size_after="$(md_sysfs_read "/sys/block/$md_name/size")"
[ "$size_after" = "$size_before" ] \
	|| md_fail "array size changed: $size_before -> $size_after sectors"

md5_after="$(dd if="$MD_TEST_MD_DEV" bs=1M count=8 iflag=direct \
	2>/dev/null | md5sum | awk '{print $1}')"
[ "$md5_after" = "$md5_before" ] \
	|| md_fail "data changed across takeover: $md5_before -> $md5_after"

md_pass "chunk fell back to ${chunk_b}B; array size and data preserved"

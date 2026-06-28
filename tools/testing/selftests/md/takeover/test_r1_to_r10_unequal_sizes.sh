#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# raid1 with members of different sizes uses min(rdev->sectors) for
# the array. raid10_size() must reach the same conclusion in
# raid10_takeover_raid1's setup_conf path; otherwise the post-takeover
# array would expose sectors beyond the smallest leg's capacity.
. "$(dirname "$0")/lib.sh"
md_require_root
md_require_tools
md_require_modules

loop0="$(md_make_loop 64)"
loop1="$(md_make_loop 96)"   # 50% larger
MD_TEST_MD_DEV="$(md_find_free_md_dev)"

md_mdadm --create --run --metadata=1.2 --level=1 --raid-devices=2 \
	"$MD_TEST_MD_DEV" "$loop0" "$loop1" >/dev/null 2>&1 \
	|| md_fail "could not create raid1 with unequal-sized members"
md_wait_sync "$MD_TEST_MD_DEV"

md_name="$(basename "$MD_TEST_MD_DEV")"
size_before="$(md_sysfs_read "/sys/block/$md_name/size")"

sysfs="$(md_sysfs_path "$MD_TEST_MD_DEV")"
md_sysfs_write "$sysfs/level" raid10 \
	|| md_fail "takeover failed"

# A no-op level write also leaves the size unchanged; confirm the
# takeover actually happened first.
level="$(md_sysfs_read "$sysfs/level")"
[ "$level" = "raid10" ] || md_fail "level not raid10 after takeover: $level"

size_after="$(md_sysfs_read "/sys/block/$md_name/size")"
[ "$size_before" = "$size_after" ] \
	|| md_fail "array size changed across takeover: $size_before -> $size_after (would expose data past min leg!)"

# Final IO check: write at end-of-array minus 1 MiB.
end_offset_kb=$(( (size_after / 2) - 1024 ))
dd if=/dev/zero of="$MD_TEST_MD_DEV" bs=1K seek="$end_offset_kb" count=512 \
	conv=notrunc oflag=direct >/dev/null 2>&1 \
	|| md_fail "write at end-of-array failed"

md_pass "array size honoured smallest-leg sizing across takeover ($size_after sectors)"

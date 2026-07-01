#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Precondition: an admin-set array_size (external_size=1) must block takeover.
# raid10_size would recompute from rdev->sectors and expose any hidden
# sectors past the shrunken boundary, silently trampling user data.
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

md_name="$(basename "$MD_TEST_MD_DEV")"
sysfs="$(md_sysfs_path "$MD_TEST_MD_DEV")"

# /sys/block/mdN/size reports 512-byte sectors; array_size takes
# KiB. Convert sectors to KiB (divide by 2) and shrink by 1 MiB
# so external_size gets set to 1 without hitting -E2BIG.
natural_sec="$(md_sysfs_read "/sys/block/$md_name/size")"
natural_kb=$((natural_sec / 2))
shrunk_kb=$((natural_kb - 1024))
if [ "$shrunk_kb" -le 0 ]; then
	md_fail "array too small to shrink for external_size test"
fi

if ! echo "$shrunk_kb" > "$sysfs/array_size" 2>/dev/null; then
	md_fail "could not set array_size (external_size) on raid1"
fi

md_clear_dmesg
if echo raid10 > "$sysfs/level" 2>/dev/null; then
	md_fail "takeover accepted array with admin-set array_size"
fi

if ! md_dmesg_contains "array_sectors explicitly set"; then
	md_fail "missing pr_warn about admin-set array_sectors"
fi

md_pass "takeover correctly refused admin-set array_sectors"

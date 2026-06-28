#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# A raid1 created without an internal bitmap (--bitmap=none) must
# also take over cleanly. The bitmap-survives test exercises the
# "with bitmap" path; this one is the negative-existence companion.
. "$(dirname "$0")/lib.sh"
md_require_root
md_require_tools
md_require_modules

loop0="$(md_make_loop 64)"
loop1="$(md_make_loop 64)"
MD_TEST_MD_DEV="$(md_find_free_md_dev)"

md_mdadm --create --run --metadata=1.2 --level=1 --raid-devices=2 \
	--bitmap=none \
	"$MD_TEST_MD_DEV" "$loop0" "$loop1" >/dev/null 2>&1 \
	|| md_fail "could not create raid1 without bitmap"
md_wait_sync "$MD_TEST_MD_DEV"

sysfs="$(md_sysfs_path "$MD_TEST_MD_DEV")"

# Confirm no bitmap is present.
if [ -d "$sysfs/bitmap" ]; then
	# Some implementations keep a bitmap subdir even when empty;
	# check chunksize to disambiguate.
	chunksize="$(md_sysfs_read "$sysfs/bitmap/chunksize" 2>/dev/null || echo 0)"
	[ "$chunksize" = "0" ] || md_fail "unexpected bitmap present: chunksize=$chunksize"
fi

md_sysfs_write "$sysfs/level" raid10 \
	|| md_fail "takeover failed on bitmap-less raid1"

level="$(md_sysfs_read "$sysfs/level")"
[ "$level" = "raid10" ] || md_fail "level not raid10 (got: $level)"

md_pass "bitmap-less raid1 -> raid10"

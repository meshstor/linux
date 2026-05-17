#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# raid1 -> raid5 / raid6 / raid0 must all be rejected because the
# raid5/6/0 takeover handlers do not accept level=1. Catches a future
# accident where someone wires raid1 source into the wrong helper.
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

for target in raid0 raid5 raid6 raid4; do
	if echo "$target" > "$sysfs/level" 2>/dev/null; then
		md_fail "takeover unexpectedly accepted raid1 -> $target"
	fi
	# Each rejection must leave the array as raid1.
	level="$(md_sysfs_read "$sysfs/level")"
	[ "$level" = "raid1" ] \
		|| md_fail "level mutated after rejected -> $target attempt (got: $level)"
done

md_pass "raid1 takeover rejects unsupported target levels"

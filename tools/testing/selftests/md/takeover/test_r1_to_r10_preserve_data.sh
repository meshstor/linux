#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Empirical counterpart to the byte-identity proof in spec section 3.
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

# Write 32 MiB of urandom, record md5.
"$DD" if=/dev/urandom of="$MD_TEST_MD_DEV" bs=1M count=32 oflag=direct \
	>/dev/null 2>&1 || md_fail "initial dd failed"
sync
before="$(md5sum < "$MD_TEST_MD_DEV" | awk '{print $1}')"

md_sysfs_write "$sysfs/level" raid10 \
	|| md_fail "takeover failed"

# Guard against a silent no-op: a level write that returned 0 but left
# the array as raid1 would otherwise pass the byte-identity check below.
level="$(md_sysfs_read "$sysfs/level")"
[ "$level" = "raid10" ] || md_fail "level not raid10 after takeover: $level"

sync
after="$(md5sum < "$MD_TEST_MD_DEV" | awk '{print $1}')"

[ "$before" = "$after" ] || md_fail "byte-identity broken: $before != $after"

md_pass "byte-identity preserved across takeover (md5=$before)"

#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Precondition #2: degraded raid1 must be rejected.
. "$(dirname "$0")/lib.sh"
md_require_root
md_require_tools
md_require_modules

loop0="$(md_make_loop 64)"
loop1="$(md_make_loop 64)"
loop2="$(md_make_loop 64)"
MD_TEST_MD_DEV="$(md_find_free_md_dev)"

md_mdadm --create --run --metadata=1.2 --level=1 --raid-devices=3 \
	"$MD_TEST_MD_DEV" "$loop0" "$loop1" "$loop2" >/dev/null 2>&1 \
	|| md_fail "could not create 3-disk raid1"
md_wait_sync "$MD_TEST_MD_DEV"

sysfs="$(md_sysfs_path "$MD_TEST_MD_DEV")"

# Fail and remove one disk to force degraded state.
md_mdadm --fail "$MD_TEST_MD_DEV" "$loop2" >/dev/null 2>&1
md_mdadm --remove "$MD_TEST_MD_DEV" "$loop2" >/dev/null 2>&1

degraded="$(md_sysfs_read "$sysfs/degraded")"
[ "$degraded" = "1" ] || md_fail "expected degraded=1 (got: $degraded)"

md_clear_dmesg
if echo raid10 > "$sysfs/level" 2>/dev/null; then
	md_fail "takeover accepted degraded raid1"
fi

if ! md_dmesg_contains "degraded"; then
	md_fail "missing pr_warn about degraded"
fi

md_pass "takeover correctly refused degraded raid1"

#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Precondition #4: WriteMostly rdev must be rejected.
. "$(dirname "$0")/lib.sh"
md_require_root
md_require_tools
md_require_modules
md_require_takeover

loop0="$(md_make_loop 64)"
loop1="$(md_make_loop 64)"
MD_TEST_MD_DEV="$(md_find_free_md_dev)"

md_mdadm --create --run --metadata=1.2 --level=1 --raid-devices=2 \
	"$MD_TEST_MD_DEV" "$loop0" --write-mostly "$loop1" >/dev/null 2>&1 \
	|| md_fail "could not create raid1 with write-mostly"
md_wait_sync "$MD_TEST_MD_DEV"

sysfs="$(md_sysfs_path "$MD_TEST_MD_DEV")"

md_clear_dmesg
if echo raid10 > "$sysfs/level" 2>/dev/null; then
	md_fail "takeover accepted write-mostly member"
fi

if ! md_dmesg_contains "write-mostly"; then
	md_fail "missing pr_warn about write-mostly"
fi

md_pass "takeover correctly refused write-mostly member"

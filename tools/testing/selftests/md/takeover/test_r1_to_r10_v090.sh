#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Precondition: v0.90 metadata cannot represent raid10 layout.
. "$(dirname "$0")/lib.sh"
md_require_root
md_require_tools
md_require_modules

loop0="$(md_make_loop 64)"
loop1="$(md_make_loop 64)"
MD_TEST_MD_DEV="$(md_find_free_md_dev)"

md_mdadm --create --run --metadata=0.90 --level=1 --raid-devices=2 \
	"$MD_TEST_MD_DEV" "$loop0" "$loop1" >/dev/null 2>&1 \
	|| md_fail "could not create v0.90 raid1"
md_wait_sync "$MD_TEST_MD_DEV"

sysfs="$(md_sysfs_path "$MD_TEST_MD_DEV")"

md_clear_dmesg
if echo raid10 > "$sysfs/level" 2>/dev/null; then
	md_fail "takeover accepted v0.90 metadata"
fi

if ! md_dmesg_contains "v0.90 metadata"; then
	md_fail "missing pr_warn about v0.90 metadata"
fi

md_pass "takeover correctly refused v0.90 metadata"

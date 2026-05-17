#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Precondition #5: max_write_behind != 0 must be rejected.
. "$(dirname "$0")/lib.sh"
md_require_root
md_require_tools
md_require_modules

loop0="$(md_make_loop 64)"
loop1="$(md_make_loop 64)"
MD_TEST_MD_DEV="$(md_find_free_md_dev)"

md_mdadm --create --run --metadata=1.2 --level=1 --raid-devices=2 \
	--bitmap=internal --write-behind=256 \
	"$MD_TEST_MD_DEV" "$loop0" --write-mostly "$loop1" >/dev/null 2>&1 \
	|| md_skip "could not create raid1 with write-behind"
md_wait_sync "$MD_TEST_MD_DEV"

sysfs="$(md_sysfs_path "$MD_TEST_MD_DEV")"

# The write-behind test also has write-mostly, so it would fail precondition #4
# first. To isolate precondition #5, clear WriteMostly on both members first.
for dev_dir in "$sysfs"/dev-*; do
	if [ -w "$dev_dir/state" ]; then
		echo -writemostly > "$dev_dir/state" 2>/dev/null || true
	fi
done

md_clear_dmesg
if echo raid10 > "$sysfs/level" 2>/dev/null; then
	md_fail "takeover accepted write-behind bitmap"
fi

if ! md_dmesg_contains "write-behind"; then
	md_fail "missing pr_warn about write-behind"
fi

md_pass "takeover correctly refused write-behind bitmap"

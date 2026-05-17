#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Precondition: non-MaxSector reshape_position must block takeover.
#
# Note: level_store() at md.c:4109 already rejects the sysfs write
# with -EBUSY when reshape_position != MaxSector, so the helper's own
# defensive check is not reached in normal operation. This test asserts
# the observable behaviour (the sysfs write fails) without caring which
# layer enforced it, guarding against any future refactor that moves
# the upstream gate.
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

# Inject a non-MaxSector reshape_position. The raw sysfs entry accepts
# any integer string; 0 is the simplest marker that is != MaxSector.
if ! echo 0 > "$sysfs/reshape_position" 2>/dev/null; then
	md_skip "kernel rejected reshape_position write (no hook available)"
fi

if echo raid10 > "$sysfs/level" 2>/dev/null; then
	md_fail "takeover accepted array with non-MaxSector reshape_position"
fi

md_pass "takeover correctly refused non-MaxSector reshape_position"

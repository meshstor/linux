#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# raid1 has chunk_sectors == 0 at creation and rejects sysfs writes to
# chunk_size via raid1_reshape. The takeover helper must therefore pick a
# default. Verify the result is 512 KiB, matching mdadm's DEFAULT_CHUNK.
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

# Confirm the starting state: raid1 reports chunk_size = 0.
before="$(md_sysfs_read "$sysfs/chunk_size")"
[ "$before" = "0" ] || md_fail "unexpected pre-takeover chunk_size: $before"

# Do NOT set chunk_size. Trigger takeover directly.
md_sysfs_write "$sysfs/level" raid10 \
	|| md_fail "takeover failed (pre-patch: helper not present)"

level="$(md_sysfs_read "$sysfs/level")"
[ "$level" = "raid10" ] || md_fail "level not raid10 after takeover: $level"

after="$(md_sysfs_read "$sysfs/chunk_size")"
[ "$after" = "524288" ] \
	|| md_fail "helper did not apply 512 KiB default (got: $after)"

md_pass "helper applied 512 KiB default chunk_size"

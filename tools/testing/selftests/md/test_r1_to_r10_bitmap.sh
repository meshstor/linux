#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Internal bitmap must carry through the takeover unchanged.
. "$(dirname "$0")/lib.sh"
md_require_root
md_require_tools
md_require_modules

loop0="$(md_make_loop 64)"
loop1="$(md_make_loop 64)"
MD_TEST_MD_DEV="$(md_find_free_md_dev)"

md_mdadm --create --run --metadata=1.2 --level=1 --raid-devices=2 \
	--bitmap=internal --bitmap-chunk=512 \
	"$MD_TEST_MD_DEV" "$loop0" "$loop1" >/dev/null 2>&1 \
	|| md_fail "could not create raid1 with bitmap"
md_wait_sync "$MD_TEST_MD_DEV"

sysfs="$(md_sysfs_path "$MD_TEST_MD_DEV")"

# Capture pre-takeover bitmap chunk count.
before_chunks="$(md_sysfs_read "$sysfs/bitmap/chunksize" 2>/dev/null || echo missing)"
[ "$before_chunks" != "missing" ] || md_fail "bitmap not created"

md_sysfs_write "$sysfs/level" raid10 \
	|| md_fail "takeover failed"

after_chunks="$(md_sysfs_read "$sysfs/bitmap/chunksize" 2>/dev/null || echo missing)"
[ "$after_chunks" = "$before_chunks" ] \
	|| md_fail "bitmap chunksize changed: $before_chunks -> $after_chunks"

md_pass "bitmap survived takeover"

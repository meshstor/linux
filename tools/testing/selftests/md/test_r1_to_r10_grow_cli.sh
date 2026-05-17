#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Real-world entry point: `mdadm --grow --level=10` is the documented
# user-facing command. Internally mdadm writes chunk_size, layout,
# new_level and raid_disks BEFORE the final `level` write. Each of
# those intermediate writes can set MD_RECOVERY_NEEDED in mddev->recovery,
# and the takeover helper's blanket `if (mddev->recovery)` check then
# rejects with "recovery state not clean" even though no resync is
# actually running. The raw-sysfs path (basic test) succeeds because it
# does ONLY the level write.
#
# This test fails today: keep it as a regression marker. The fix is
# either to make mdadm skip those intermediate writes for the
# raid1->raid10 takeover, or to tighten the helper's check to
# test_bit(MD_RECOVERY_RUNNING, ...) instead of the whole bitfield.
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

# Give md thread an extra grace period so MD_RECOVERY_NEEDED has a
# realistic chance to clear before mdadm starts banging on sysfs.
sleep 2

if ! md_mdadm --grow --level=10 "$MD_TEST_MD_DEV" >/dev/null 2>&1; then
	# Capture the kernel reason so the failure mode is obvious to
	# whoever runs this later.
	reason="$(dmesg | grep -E 'raid1->raid10 takeover refused' | tail -1)"
	md_fail "mdadm --grow --level=10 rejected by kernel: ${reason:-unknown}"
fi

sysfs="$(md_sysfs_path "$MD_TEST_MD_DEV")"
level="$(md_sysfs_read "$sysfs/level")"
[ "$level" = "raid10" ] || md_fail "level not raid10 after --grow (got: $level)"

layout="$(md_sysfs_read "$sysfs/layout")"
[ "$layout" = "258" ] || md_fail "layout not 258 after --grow (got: $layout)"

md_pass "mdadm --grow --level=10 drives the takeover"

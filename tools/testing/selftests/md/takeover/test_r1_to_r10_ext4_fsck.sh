#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# End-to-end sanity: a mounted ext4 filesystem must survive the
# takeover without fsck errors. This catches any byte-identity break
# that the bulk md5 sweep might miss (e.g., a misplaced sector that
# happens to be in slack space).
. "$(dirname "$0")/lib.sh"
md_require_root
md_require_tools
md_require_modules

if ! command -v mkfs.ext4 >/dev/null 2>&1 || ! command -v e2fsck >/dev/null 2>&1; then
	md_skip "missing mkfs.ext4 or e2fsck"
fi

loop0="$(md_make_loop 96)"
loop1="$(md_make_loop 96)"
MD_TEST_MD_DEV="$(md_find_free_md_dev)"
mnt="$(mktemp -d "${TMPDIR:-/tmp}/md-fsck.XXXXXX")"

cleanup_extra() {
	umount "$mnt" >/dev/null 2>&1
	rmdir "$mnt" >/dev/null 2>&1
}
# md_cleanup runs first via the lib.sh trap; chain extra cleanup.
trap 'cleanup_extra; md_cleanup' EXIT

md_mdadm --create --run --metadata=1.2 --level=1 --raid-devices=2 \
	"$MD_TEST_MD_DEV" "$loop0" "$loop1" >/dev/null 2>&1 \
	|| md_fail "could not create raid1"
md_wait_sync "$MD_TEST_MD_DEV"

mkfs.ext4 -q -F "$MD_TEST_MD_DEV" >/dev/null 2>&1 \
	|| md_fail "mkfs.ext4 failed"
mount "$MD_TEST_MD_DEV" "$mnt" || md_fail "mount failed"

# Lay down a tree of files with checksummable content.
for i in $(seq 1 32); do
	"$DD" if=/dev/urandom of="$mnt/file_$i" bs=64K count=1 \
		>/dev/null 2>&1 || md_fail "file write failed"
done
sync
before_sum="$(cd "$mnt" && find . -type f -exec md5sum {} + | sort | md5sum | awk '{print $1}')"

umount "$mnt" || md_fail "umount before takeover failed"

sysfs="$(md_sysfs_path "$MD_TEST_MD_DEV")"
md_sysfs_write "$sysfs/level" raid10 \
	|| md_fail "takeover failed"

# Guard against a silent no-op: a clean fsck on an array that stayed
# raid1 would otherwise let this test pass without a takeover.
level="$(md_sysfs_read "$sysfs/level")"
[ "$level" = "raid10" ] || md_fail "level not raid10 after takeover: $level"

# fsck must be clean across the level change.
e2fsck -nf "$MD_TEST_MD_DEV" >/dev/null 2>&1 \
	|| md_fail "e2fsck found errors after takeover"

mount "$MD_TEST_MD_DEV" "$mnt" || md_fail "remount after takeover failed"
after_sum="$(cd "$mnt" && find . -type f -exec md5sum {} + | sort | md5sum | awk '{print $1}')"
umount "$mnt" || md_fail "final umount failed"

[ "$before_sum" = "$after_sum" ] \
	|| md_fail "file contents changed across takeover: $before_sum != $after_sum"

md_pass "ext4 fsck clean and files intact across takeover"

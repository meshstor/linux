#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Mode B correctness reproducer: after fresh-spare recovery, the spare
# must actually contain the user data (not just advance recovery_offset
# bookkeeping). Verified by:
#   1. Create raid1 with --assume-clean, write a known marker file
#   2. Fail+remove member B, add fresh member C, wait for in_sync
#   3. Fail+remove member A (the original survivor)
#   4. Stop+reassemble using ONLY the spare C
#   5. Mount and verify the marker file content matches
#
# The simple Mode B test (test_mode_b_spare_recovers.sh) passes on the
# unfixed kernel because conf->fullsync in raid1_sync_request forces
# sync I/O regardless of what the bitmap says — bookkeeping completes
# even if the bitmap state machine declines to transition. This test
# verifies the I/O actually copied real data.

set -eu

DIR="$(dirname "$0")"
. "$DIR/lib.sh"

llbitmap_require_root
llbitmap_require_modules
llbitmap_require_tools

LA=$(llbitmap_make_loop 512)
LB=$(llbitmap_make_loop 512)
LC=$(llbitmap_make_loop 512)

llbitmap_alloc_ms_dev >/dev/null
MS_DEV="$LLBITMAP_TEST_MS_DEV"
MS_NAME="$LLBITMAP_TEST_MS_NAME"
LC_BASE=$(basename "$LC")

echo "INFO: ms_dev=$MS_DEV members=$LA,$LB spare=$LC"

"$MDADM" --create "$MS_DEV" \
	--level=1 --metadata=1.2 --raid-devices=2 --homehost=any \
	--bitmap=auto --bitmap-chunk=64M --consistency-policy=bitmap \
	--assume-clean "$LA" "$LB" --run --force >/dev/null 2>&1

# Verify llbitmap is the active bitmap.
bt=$(cat "/sys/block/$MS_NAME/ms/bitmap_type" 2>/dev/null || echo "")
case "$bt" in
	*"[llbitmap]"*) : ;;
	*) llbitmap_skip "expected llbitmap, got '$bt'" ;;
esac

# Write a known marker via xfs.
mkfs.xfs -q -f "$MS_DEV" >/dev/null 2>&1
LLBITMAP_TEST_MOUNT=$(mktemp -d /tmp/llbitmap-mnt.XXXXXX)
mount "$MS_DEV" "$LLBITMAP_TEST_MOUNT"

# Write 32 MiB of content with a checksum-friendly pattern.
"$DD" if=/dev/urandom of="$LLBITMAP_TEST_MOUNT/marker" bs=1M count=32 conv=fsync status=none
sync
EXPECTED_MD5=$(md5sum "$LLBITMAP_TEST_MOUNT/marker" | awk '{print $1}')
echo "INFO: marker md5=$EXPECTED_MD5"

umount "$LLBITMAP_TEST_MOUNT"

# Fail+remove member B; add fresh member C as the spare.
"$MDADM" --manage "$MS_DEV" --fail "$LB" --remove "$LB" >/dev/null 2>&1
"$MDADM" --manage "$MS_DEV" --add "$LC" >/dev/null 2>&1

# Wait up to 90s for the spare to reach in_sync.
deadline=$(( $(date +%s) + 90 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
	state=$(llbitmap_member_state "$MS_NAME" "$LC_BASE")
	if printf '%s' "$state" | grep -qw "in_sync"; then
		break
	fi
	sleep 1
done
state=$(llbitmap_member_state "$MS_NAME" "$LC_BASE")
if ! printf '%s' "$state" | grep -qw "in_sync"; then
	cat "/sys/block/$MS_NAME/ms/llbitmap/bits" 2>&1 | sed 's/^/  /'
	llbitmap_fail "spare did not reach in_sync within 90s; state='$state'"
fi
echo "INFO: spare reached in_sync"

# Now the critical part: fail+remove member A so the array runs ONLY
# on the recovered spare C. If recovery copied real data, the marker
# survives. If recovery only advanced bookkeeping (the Mode B latent
# bug), the spare contains zeros and md5 mismatches.
"$MDADM" --manage "$MS_DEV" --fail "$LA" --remove "$LA" >/dev/null 2>&1
sleep 1

# Re-mount and verify.
mount "$MS_DEV" "$LLBITMAP_TEST_MOUNT" 2>&1 | head
if ! mountpoint -q "$LLBITMAP_TEST_MOUNT"; then
	llbitmap_fail "could not mount degraded array on spare"
fi

GOT_MD5=$(md5sum "$LLBITMAP_TEST_MOUNT/marker" 2>&1 | awk '{print $1}')
umount "$LLBITMAP_TEST_MOUNT"

if [ "$GOT_MD5" != "$EXPECTED_MD5" ]; then
	llbitmap_fail "marker md5 mismatch on spare-only array: expected=$EXPECTED_MD5 got=$GOT_MD5"
fi

llbitmap_pass "spare contains correct marker data after recovery"

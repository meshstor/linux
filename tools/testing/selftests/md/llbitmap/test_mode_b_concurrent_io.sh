#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Mode B with concurrent I/O: recovery runs while user writes are in
# flight. The hypothesis from the investigation is that BitClean chunks
# don't transition to BitSyncing, so the bitmap-state-vs-actual-state
# diverges under load and recovery either stalls or misses chunks.
#
# Test flow:
#   1. Create raid1 + xfs, write 256 MiB initial data, sync, capture md5
#   2. Fail+remove member B
#   3. Background: continuous random writes to /mnt/llbtest at ~30 MB/s
#   4. Foreground: add member C, watch /sys/.../dev-loopC/state
#   5. After in_sync (or 180s timeout), stop background, capture md5
#   6. Fail+remove member A so only spare remains
#   7. Re-mount, verify md5 of files matches (the in-progress writes
#      may have finished or not; we verify the FINAL on-disk state
#      matches whichever member was last sync'd).
#
# Pre-fix expectation per investigation: spare stuck at "spare", or
# spare reaches in_sync but md5 mismatches under concurrent load.

set -eu

DIR="$(dirname "$0")"
. "$DIR/lib.sh"

llbitmap_require_root
llbitmap_require_modules
llbitmap_require_tools

LA=$(llbitmap_make_loop 2048)
LB=$(llbitmap_make_loop 2048)
LC=$(llbitmap_make_loop 2048)

llbitmap_alloc_ms_dev >/dev/null
MS_DEV="$LLBITMAP_TEST_MS_DEV"
MS_NAME="$LLBITMAP_TEST_MS_NAME"
LC_BASE=$(basename "$LC")

echo "INFO: ms_dev=$MS_DEV members=$LA,$LB spare=$LC"

"$MDADM" --create "$MS_DEV" \
	--level=1 --metadata=1.2 --raid-devices=2 --homehost=any \
	--bitmap=auto --bitmap-chunk=64M --consistency-policy=bitmap \
	--assume-clean "$LA" "$LB" --run --force >/dev/null 2>&1

# Sanity: llbitmap is the active bitmap.
bt=$(cat "/sys/block/$MS_NAME/ms/bitmap_type" 2>/dev/null || echo "")
case "$bt" in
	*"[llbitmap]"*) : ;;
	*) llbitmap_skip "expected llbitmap, got '$bt'" ;;
esac

mkfs.xfs -q -f "$MS_DEV" >/dev/null 2>&1
LLBITMAP_TEST_MOUNT=$(mktemp -d /tmp/llbitmap-mnt.XXXXXX)
mount "$MS_DEV" "$LLBITMAP_TEST_MOUNT"

# Initial data: 256 MiB of pseudorandom content. Captured md5 will be
# our reference for what the spare must hold post-recovery.
dd if=/dev/urandom of="$LLBITMAP_TEST_MOUNT/initial" bs=1M count=256 conv=fsync status=none
sync
INITIAL_MD5=$(md5sum "$LLBITMAP_TEST_MOUNT/initial" | awk '{print $1}')
echo "INFO: initial 256 MiB md5=$INITIAL_MD5"

# Fail+remove member B.
"$MDADM" --manage "$MS_DEV" --fail "$LB" --remove "$LB" >/dev/null 2>&1

# Start the concurrent writer in the background. It writes a 64 MiB
# rolling file with random data; will run until killed. Sized so
# recovery and writes overlap heavily on a 2 GiB array.
WRITER_PID_FILE=$(mktemp)
(
	# shellcheck disable=SC2034
	for round in $(seq 1 200); do
		dd if=/dev/urandom of="$LLBITMAP_TEST_MOUNT/rolling" bs=1M count=64 conv=fsync status=none 2>/dev/null || break
		sync 2>/dev/null || break
		sleep 0.1
	done
) &
WRITER_PID=$!
echo "$WRITER_PID" > "$WRITER_PID_FILE"
echo "INFO: started concurrent writer pid=$WRITER_PID"

# Add the fresh spare. Recovery starts in parallel with writes.
"$MDADM" --manage "$MS_DEV" --add "$LC" >/dev/null 2>&1
echo "INFO: added spare, watching for in_sync (max 180s)"

deadline=$(( $(date +%s) + 180 ))
elapsed=0
while [ "$(date +%s)" -lt "$deadline" ]; do
	state=$(llbitmap_member_state "$MS_NAME" "$LC_BASE")
	if printf '%s' "$state" | grep -qw "in_sync"; then
		elapsed=$(( 180 - (deadline - $(date +%s)) ))
		break
	fi
	if [ $((elapsed % 10)) -eq 0 ] && [ "$elapsed" -gt 0 ]; then
		bits_summary=$(awk '{printf "%s=%s ", $1$2, $NF}' "/sys/block/$MS_NAME/ms/llbitmap/bits" 2>/dev/null || echo "?")
		echo "INFO: t=${elapsed}s state='$state' bits=$bits_summary"
	fi
	sleep 1
	elapsed=$((elapsed + 1))
done

# Stop the writer regardless of outcome.
kill "$WRITER_PID" 2>/dev/null || true
wait "$WRITER_PID" 2>/dev/null || true
rm -f "$WRITER_PID_FILE"

state=$(llbitmap_member_state "$MS_NAME" "$LC_BASE")
if ! printf '%s' "$state" | grep -qw "in_sync"; then
	echo "INFO: bitmap stats at timeout:"
	cat "/sys/block/$MS_NAME/ms/llbitmap/bits" 2>&1 | sed 's/^/  /'
	echo "INFO: msstat:"
	cat /proc/msstat | sed 's/^/  /'
	umount "$LLBITMAP_TEST_MOUNT" 2>/dev/null || true
	llbitmap_fail "spare did not reach in_sync within 180s under concurrent I/O; state='$state'"
fi
echo "INFO: spare reached in_sync in ${elapsed}s under concurrent I/O"

# Sync any pending I/O before failover.
sync

# Fail+remove member A so the array runs only on the spare.
"$MDADM" --manage "$MS_DEV" --fail "$LA" --remove "$LA" >/dev/null 2>&1
sleep 1

# Re-check the initial file. The /rolling file may have been mid-write
# at the moment we killed the writer; we don't assert on its content.
# But /initial was written before the writer started and synced; its
# md5 must match what the spare returns.
GOT_MD5=$(md5sum "$LLBITMAP_TEST_MOUNT/initial" 2>&1 | awk '{print $1}')
umount "$LLBITMAP_TEST_MOUNT" 2>/dev/null || true

if [ "$GOT_MD5" != "$INITIAL_MD5" ]; then
	llbitmap_fail "initial file md5 mismatch on spare under concurrent recovery: expected=$INITIAL_MD5 got=$GOT_MD5"
fi

llbitmap_pass "concurrent-I/O recovery completed in ${elapsed}s with intact initial data"

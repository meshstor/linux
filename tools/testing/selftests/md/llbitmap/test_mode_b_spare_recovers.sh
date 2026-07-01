#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Mode B reproducer: fresh-spare recovery on a degraded RAID1 with
# --bitmap=auto must reach in_sync within a bounded time.
#
# Pre-fix expectation: TIMEOUT (spare stuck in "spare" state because
# llbitmap state machine refuses to transition BitClean -> BitSyncing
# during degraded recovery).
#
# Post-fix expectation: spare reaches "in_sync" within ~30 s.

set -eu

DIR="$(dirname "$0")"
. "$DIR/lib.sh"

llbitmap_require_root
llbitmap_require_modules
llbitmap_require_tools

# 256 MiB members. Big enough that BitmapActionStale visible chunk count
# isn't a one-chunk anomaly; small enough to recover quickly post-fix.
LA=$(llbitmap_make_loop 256)
LB=$(llbitmap_make_loop 256)
LC=$(llbitmap_make_loop 256)

# Call without $(...) so the globals set by the function propagate.
llbitmap_alloc_ms_dev >/dev/null
MS_DEV="$LLBITMAP_TEST_MS_DEV"
MS_NAME="$LLBITMAP_TEST_MS_NAME"
LC_BASE=$(basename "$LC")

echo "INFO: ms_dev=$MS_DEV members=$LA,$LB spare=$LC"

# --assume-clean -> all chunks become BitClean. This is the
# precondition that makes Mode B fire: BitClean[Startsync] = BitNone in
# the state machine table, and the degraded fast path only special-cases
# BitDirty.
"$MDADM" --create "$MS_DEV" \
	--level=1 --metadata=1.2 --raid-devices=2 --homehost=any \
	--bitmap=auto --bitmap-chunk=64M --consistency-policy=bitmap \
	--assume-clean "$LA" "$LB" --run --force >/dev/null 2>&1

# Sanity: confirm llbitmap is the active bitmap implementation.
bitmap_type=$(cat "/sys/block/$MS_NAME/${LLBITMAP_SYSFS_SUBDIR}/bitmap_type" 2>/dev/null || echo "")
case "$bitmap_type" in
	*"[llbitmap]"*) : ;;
	*) llbitmap_skip "bitmap_type='$bitmap_type', expected llbitmap to be selected" ;;
esac

# Confirm chunks are BitClean (assume-clean precondition).
clean_count=$(llbitmap_state_count "$MS_NAME" "clean")
if [ "$clean_count" -lt 2 ]; then
	llbitmap_fail "expected >=2 BitClean chunks after --assume-clean, got $clean_count"
fi
echo "INFO: BitClean chunks before fail/add: $clean_count"

# Fail + remove member B; add fresh member C as a spare.
"$MDADM" --manage "$MS_DEV" --fail "$LB" --remove "$LB" >/dev/null 2>&1
"$MDADM" --manage "$MS_DEV" --add "$LC" >/dev/null 2>&1

# Initial state of the new spare is "spare". Wait up to 90s for it to
# reach "in_sync". Without the BitmapActionStale fix the bitmap declines
# to transition BitClean->BitSyncing for any chunk, so recovery_offset
# never reaches MaxSector and the spare is stuck.
deadline=$(( $(date +%s) + 90 ))
final_state=""
elapsed=0
while [ "$(date +%s)" -lt "$deadline" ]; do
	state=$(llbitmap_member_state "$MS_NAME" "$LC_BASE")
	# state is e.g. "spare", "in_sync", "in_sync,write_mostly", etc.
	if printf '%s' "$state" | grep -qw "in_sync"; then
		final_state="$state"
		elapsed=$(( 90 - (deadline - $(date +%s)) ))
		break
	fi
	sleep 1
done

if [ -z "$final_state" ]; then
	state=$(llbitmap_member_state "$MS_NAME" "$LC_BASE")
	echo "INFO: bitmap stats at timeout:"
	cat "/sys/block/$MS_NAME/${LLBITMAP_SYSFS_SUBDIR}/llbitmap/bits" 2>&1 | sed 's/^/  /'
	echo "INFO: mdstat:"
	cat ${LLBITMAP_PROC_STAT} 2>&1 | sed 's/^/  /'
	llbitmap_fail "spare $LC_BASE did not reach in_sync within 90s; final state='$state'"
fi

llbitmap_pass "spare $LC_BASE reached '$final_state' in ${elapsed}s"

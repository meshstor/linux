#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Reproducer for the init-time bitmap *data-page* write-failure gap fixed by
#   "md/llbitmap: detect init data-page write failure, commit super last".
#
# The earlier fix made llbitmap_init() persist the BITMAP_FIRST_USE-clear
# super synchronously with failure detection, but still flushed the bitmap
# *data* pages asynchronously (md_write_metadata()).  Before mddev->pers is
# assigned, super_written() -> md_error() is a no-op and md_super_wait() only
# waits for completion, so a data-page write error during --create was
# silently swallowed.  The super committed FIRST_USE-clear, so the next
# assemble skipped re-init and trusted stale/unwritten bitmap data.
#
# Unlike test_first_use_persist_failure.sh (which fails *every* write, a case
# both the old and fixed kernels reject), this test fails ONLY the bitmap data
# sectors while keeping the super sectors healthy -- the exact "super ok, data
# fails" window the fix closes:
#
#   - Old kernel: the super write (page 0, sectors 0-1) succeeds, so on-disk
#     FIRST_USE is cleared; the async data flush fails and is swallowed; the
#     array STARTS.  Bug.
#   - Fixed kernel: the data write is synchronous and failure-detected, and
#     the super (page 0) is committed last, so init returns -EIO with
#     FIRST_USE still set on disk; the array refuses to start.
#
# On-disk bitmap layout (metadata 1.2, 512-byte logical block => io_size 512):
#   bitmap super at SB; page 0 = [super: bytes 0..1023 = sectors 0..1]
#   [data: bytes 1024.. = sector 2..].  Chunk 0's init state lands at byte
#   1024, so failing sectors [SB+2, SB+8) reliably hits an init data write
#   while leaving the super (sectors SB..SB+1) writable.
#
# Mechanism:
#   1. Create a 2-member raid1 over two loop devices, init the bitmap.
#   2. Stop; plant BITMAP_FIRST_USE on both members so the next assemble
#      must re-run llbitmap_init.
#   3. Wrap each loop in a dm device: linear (healthy) for the super and
#      everything else, flakey/error_writes for the 6 page-0 data sectors.
#   4. mdadm --assemble over the dm devices.
#
# Harness robustness (two false-PASS vectors closed):
#   * meshstor superblocks are bit-for-bit identical to kernel md, so the
#     IN-TREE md_mod incrementally auto-assembles our members the moment a
#     dm/loop node carrying the superblock (re)appears, holding them busy.
#     A naive 'mdadm --assemble' then fails with "is busy - skipping" and the
#     array never reaches RUN_ARRAY -- but FIRST_USE was never touched, so a
#     verdict that treats "FIRST_USE still set" as PASS reports a false PASS
#     (the injected fault was never exercised).  dp_stop_inkernel_md() stops
#     only the IN-TREE md arrays that hold OUR members, right before every
#     explicit assemble / on-disk read.
#   * The verdict now REQUIRES proof the data-sector write injection actually
#     engaged (a control write to a failing sector must return EIO) before it
#     may PASS, and discriminates on the real signal: fixed => RUN_ARRAY
#     refused with I/O error and FIRST_USE preserved; unfixed => array started
#     and FIRST_USE cleared.
#
# Verdict:
#   PASS  the fixed kernel refused: "failed to RUN_ARRAY ...: I/O error" OR
#         dmesg "failed to persist initial bitmap" OR (array did not start AND
#         FIRST_USE still set on both members) -- with injection proven active.
#   FAIL  the array started despite a failing data-page write (the swallowed-
#         error bug), OR the harness could not exercise the fault after setup
#         (the injection did not engage, or an injection-active run reached no
#         clear verdict).  A regression guard that cannot run its target must be
#         loud, not silently skipped -- a silent skip is how the original false
#         PASS hid.
#   SKIP  an environmental precondition is missing (not root, no dmsetup, no
#         dm-flakey target, mdadm create failed, not an llbitmap array) -- the
#         test could not even be set up.

set -u

DIR="$(dirname "$0")"
. "$DIR/lib.sh"

llbitmap_require_root
llbitmap_require_modules
llbitmap_require_tools
command -v dmsetup >/dev/null || llbitmap_skip "dmsetup not available"
modprobe dm-flakey 2>/dev/null || true
dmsetup targets | grep -q '^flakey' || llbitmap_skip "dm-flakey target missing"

LOOP_SIZE_MB=100

DP_DM_NAMES=()

# Stop any IN-KERNEL (in-tree md_mod) array that udev auto-assembled over our
# members.  meshstor superblocks are bit-for-bit identical to kernel md, so the
# in-tree md_mod grabs the dm/loop members the moment they reappear (after a
# --stop or a dmsetup create/resume), holding them busy and shadowing direct
# reads of the underlying loops.  The 'md*' holder glob matches only in-tree
# md arrays (our personality is 'msNNN'), so this never stops OUR array.
dp_stop_inkernel_md() {
	local memb base h hname
	for memb in "${FA:-}" "${FB:-}" "${LA:-}" "${LB:-}"; do
		[ -n "$memb" ] && [ -e "$memb" ] || continue
		base=$(basename "$(readlink -f "$memb")")
		for h in /sys/block/"$base"/holders/md*; do
			[ -e "$h" ] || continue
			hname=$(basename "$h")
			mdadm --stop "/dev/$hname" >/dev/null 2>&1 || true
		done
	done
	udevadm settle 2>/dev/null || true
}

dp_cleanup() {
	set +e
	"$MDADM" --stop "${MS_DEV:-/dev/does-not-exist}" >/dev/null 2>&1
	dp_stop_inkernel_md
	# Erase the bit-identical md superblock so udev cannot keep re-assembling our
	# members into an in-tree md array (which holds the dm/loop nodes busy and
	# leaks them across runs).  The dm view's md-super region is healthy linear,
	# so zero through it first, then the raw loops once the dm nodes are gone.
	local d try n left
	for d in "${DP_DM_NAMES[@]:-}"; do
		[ -e "/dev/mapper/$d" ] && "$MDADM" --zero-superblock "/dev/mapper/$d" >/dev/null 2>&1
	done
	for try in 1 2 3 4 5; do
		dp_stop_inkernel_md
		left=0
		for n in "${DP_DM_NAMES[@]:-}"; do
			[ -e "/dev/mapper/$n" ] || continue
			dmsetup remove "$n" 2>/dev/null || left=1
		done
		[ "$left" -eq 0 ] && break
		sleep 0.3
	done
	# Loops are plain now; wipe their superblocks before llbitmap_cleanup detaches
	# them so a detach race cannot leave an assemblable member behind.
	"$MDADM" --zero-superblock "${LA:-/dev/does-not-exist}" "${LB:-/dev/does-not-exist}" >/dev/null 2>&1
	dp_stop_inkernel_md
	llbitmap_cleanup
	set -e
}
trap dp_cleanup EXIT

# Byte offset of the bitmap super within a member (sb_start + offset field).
bitmap_super_offset() {
	local dev="$1"
	local sb_start=4096
	local off
	off=$("$DD" if="$dev" bs=1 skip=$((sb_start + 96)) count=4 status=none |
	      od -An -tu4 -N4 | tr -d ' ')
	echo $(( sb_start + off * 512 ))
}

read_state_byte0() {
	local dev="$1" sb_off
	sb_off=$(bitmap_super_offset "$dev")
	"$DD" if="$dev" bs=1 skip=$((sb_off + 48)) count=1 status=none | od -An -tu1 -N1 | tr -d ' '
}

write_state_byte0() {
	local dev="$1" val="$2" sb_off
	sb_off=$(bitmap_super_offset "$dev")
	printf "\\x$(printf '%02x' "$val")" | "$DD" of="$dev" bs=1 seek=$((sb_off + 48)) count=1 conv=notrunc status=none
}

# Build the composite dm table: healthy linear everywhere except 6 error_writes
# sectors covering page-0 data (sectors SB_SECTOR+2 .. SB_SECTOR+7).
make_selective_table() {
	local loop="$1" sb_sector="$2" total="$3"
	local s2=$(( sb_sector + 2 ))
	local s8=$(( sb_sector + 8 ))
	printf '0 %d linear %s 0\n' "$s2" "$loop"
	printf '%d 6 flakey %s %d 0 999 1 error_writes\n' "$s2" "$loop" "$s2"
	printf '%d %d linear %s %d\n' "$s8" "$(( total - s8 ))" "$loop" "$s8"
}

# Setup
LA=$(llbitmap_make_loop $LOOP_SIZE_MB)
LB=$(llbitmap_make_loop $LOOP_SIZE_MB)

llbitmap_alloc_ms_dev >/dev/null
MS_DEV="$LLBITMAP_TEST_MS_DEV"
MS_NAME="$LLBITMAP_TEST_MS_NAME"

echo "=== FIRST_USE-persist data-page failure-detection reproducer ==="
echo "  members: $LA, $LB"
echo "  md dev: $MS_DEV"

"$MDADM" --create "$MS_DEV" \
	--level=1 --metadata=1.2 --raid-devices=2 --homehost=any \
	--bitmap=auto --assume-clean "$LA" "$LB" --run --force \
	>/dev/null 2>&1 || llbitmap_skip "mdadm create failed"

bt=$(cat "/sys/block/$MS_NAME/ms/bitmap_type" 2>/dev/null || echo "")
case "$bt" in
	*"[llbitmap]"*) : ;;
	*) llbitmap_skip "not llbitmap ($bt)" ;;
esac

sync
"$MDADM" --stop "$MS_DEV" >/dev/null 2>&1
udevadm settle 2>/dev/null

# The bit-identical superblock makes the in-tree md_mod auto-assemble LA/LB the
# moment they reappear after --stop; that array holds the members and its page
# cache shadows a direct read of the underlying loops.  Stop it and invalidate
# the caches so the FIRST_USE plant lands on the real on-disk bitmap super.
dp_stop_inkernel_md
blockdev --flushbufs "$LA" 2>/dev/null || true
blockdev --flushbufs "$LB" 2>/dev/null || true

# Plant FIRST_USE (bit 3 = 0x08) on both members so re-init runs on assemble.
SA=$(read_state_byte0 "$LA"); SB_=$(read_state_byte0 "$LB")
write_state_byte0 "$LA" $(( SA | 8 ))
write_state_byte0 "$LB" $(( SB_ | 8 ))
sync
blockdev --flushbufs "$LA" 2>/dev/null || true
blockdev --flushbufs "$LB" 2>/dev/null || true
A_PLANTED=$(read_state_byte0 "$LA"); B_PLANTED=$(read_state_byte0 "$LB")
echo "  planted FIRST_USE: A=$A_PLANTED B=$B_PLANTED (expect 0x08 set)"
[ $(( A_PLANTED & 8 )) -ne 0 ] || llbitmap_skip "could not plant FIRST_USE on A"

# Compute the bitmap super sector and build the selective dm devices.
SB_BYTE=$(bitmap_super_offset "$LA")
SB_SECTOR=$(( SB_BYTE / 512 ))
SIZE_A=$(blockdev --getsz "$LA")
SIZE_B=$(blockdev --getsz "$LB")
echo "  bitmap super at byte $SB_BYTE (sector $SB_SECTOR); failing sectors $((SB_SECTOR+2))..$((SB_SECTOR+7))"

# Defensive: drop any stale dp-sel from an earlier aborted run so the creates
# below don't fail with "Device or resource busy" (name already exists).
for stale in dp-selA dp-selB; do
	[ -e "/dev/mapper/$stale" ] && dmsetup remove --retry "$stale" 2>/dev/null
done
dmsetup create dp-selA --table "$(make_selective_table "$LA" "$SB_SECTOR" "$SIZE_A")"
DP_DM_NAMES+=("dp-selA")
dmsetup create dp-selB --table "$(make_selective_table "$LB" "$SB_SECTOR" "$SIZE_B")"
DP_DM_NAMES+=("dp-selB")
FA=/dev/mapper/dp-selA
FB=/dev/mapper/dp-selB

# Releasing the dm nodes re-triggered udev auto-assembly into the in-tree md;
# stop it so our explicit assemble (and the control write below) can open the
# members instead of failing with "is busy - skipping".
dp_stop_inkernel_md

# Prove the data-sector write injection is actually engaged, kernel-agnostically:
# a direct write to the first failing sector must return EIO.  Without this an
# assemble that never ran (members busy, wrong errno, etc.) could masquerade as
# "init refused".  The write fails, so it leaves the on-disk bitmap untouched.
INJECTION_ACTIVE=0
if ! "$DD" if=/dev/zero of="$FA" bs=512 seek=$((SB_SECTOR + 2)) count=1 \
	oflag=direct conv=notrunc status=none 2>/dev/null; then
	INJECTION_ACTIVE=1
fi
echo "  injection control write to failing sector: $([ "$INJECTION_ACTIVE" -eq 1 ] && echo 'EIO (active)' || echo 'SUCCEEDED (NOT active)')"
# The control write opened FA; make sure udev did not re-grab it meanwhile.
dp_stop_inkernel_md

# Assemble. llbitmap_init runs (FIRST_USE on disk); the super sectors are
# healthy but the page-0 data sectors return EIO on write.  The in-tree md
# races to re-grab the bit-identical members between our stop and the assemble;
# if it wins, mdadm reports "busy - skipping" for that member and RUN_ARRAY
# never exercises the fault.  Retry -- stopping the in-tree md each round --
# until a member is no longer skipped (a real start or a real -EIO refusal both
# mean the fault path ran) or attempts are exhausted.
out=""
ARRAY_STARTED=0
ASTATE=absent
for attempt in 1 2 3 4 5; do
	dp_stop_inkernel_md
	llbitmap_dmesg_clear
	out=$("$MDADM" --assemble "$MS_DEV" "$FA" "$FB" --run 2>&1 || true)
	ASTATE=$(cat "/sys/block/$MS_NAME/ms/array_state" 2>/dev/null || echo absent)
	case "$ASTATE" in
		clean|active|active-idle|readonly|read-auto|write-pending) ARRAY_STARTED=1 ;;
	esac
	echo "$out" | grep -qiE 'has been started' && ARRAY_STARTED=1
	echo "  assemble attempt $attempt: started=$ARRAY_STARTED state=$ASTATE :: $out"
	"$MDADM" --stop "$MS_DEV" >/dev/null 2>&1 || true
	udevadm settle 2>/dev/null
	# Fault path engaged (real start, or real -EIO refusal) -> done.
	if [ "$ARRAY_STARTED" -eq 1 ] ||
	   echo "$out" | grep -qiE 'failed to RUN_ARRAY.*(I/O error|Input/output)|failed to persist initial bitmap'; then
		break
	fi
	# Otherwise only a busy-skip is worth retrying.
	echo "$out" | grep -qi 'busy - skipping' || break
	sleep 0.3
done

echo "  --- relevant dmesg ---"
dmesg | tail -40 | grep -iE 'llbitmap|md/raid|persist|gets error|bitmap' | tail -10

# Read final on-disk FIRST_USE via the underlying loops (bypass dm).  Stop the
# in-tree md that re-grabbed the members FIRST (so the removal does not race a
# busy holder), then drop the dm nodes; keep DP_DM_NAMES populated so dp_cleanup
# can still retry anything that lingers.  Flush caches so the read sees disk.
dp_stop_inkernel_md
for n in dp-selA dp-selB; do
	[ -e "/dev/mapper/$n" ] && dmsetup remove --retry "$n" 2>/dev/null
done
FA=""; FB=""
dp_stop_inkernel_md
blockdev --flushbufs "$LA" 2>/dev/null || true
blockdev --flushbufs "$LB" 2>/dev/null || true
A_AFTER=$(read_state_byte0 "$LA"); B_AFTER=$(read_state_byte0 "$LB")
A_STILL=$(( A_AFTER & 8 )); B_STILL=$(( B_AFTER & 8 ))

echo
echo "=== verdict ==="
echo "  injection active: $INJECTION_ACTIVE"
echo "  array started:    $ARRAY_STARTED"
echo "  FIRST_USE after assemble: A=$A_STILL B=$B_STILL  (set => init did NOT commit)"
echo "  assemble output: $out"

# A verdict requires the injected fault to have actually engaged; otherwise the
# code path under test was never reached.  dm-flakey is already confirmed
# present (checked up top), so a control write that did NOT return EIO means the
# harness is broken, not the environment -- FAIL loudly rather than skip, so the
# guard cannot silently stop covering the bug (the original false-PASS failure
# mode).
if [ "$INJECTION_ACTIVE" -ne 1 ]; then
	llbitmap_fail "data-sector write injection did not engage (control write to a flakey error_writes sector succeeded) -- harness broken, cannot exercise the data-page write fault"
fi

# With the injection proven active, the fixed kernel ALWAYS refuses RUN_ARRAY
# (-EIO from llbitmap_init): whichever member assembled, its page-0 data write
# fails.  So the array ever reaching a started state is, by itself, the
# swallowed-error bug -- independent of the (assembly-order-sensitive) on-disk
# FIRST_USE read.
if [ "$ARRAY_STARTED" -eq 1 ]; then
	llbitmap_fail "array started despite a failing data-page write (swallowed-error bug); FIRST_USE A=$A_STILL B=$B_STILL"
fi

# Fixed kernel: synchronous failure detection -> RUN_ARRAY refused with -EIO,
# super committed last so FIRST_USE preserved.  Match the errno specifically so
# an unrelated EINVAL cannot pass.
if echo "$out" | grep -qiE 'failed to RUN_ARRAY.*(I/O error|Input/output)'; then
	llbitmap_pass "fixed kernel refused init with -EIO (data-page write failure detected)"
fi
if dmesg | tail -80 | grep -q 'failed to persist initial bitmap'; then
	llbitmap_pass "fixed kernel logged 'failed to persist initial bitmap' and refused"
fi
if [ "$A_STILL" -ne 0 ] && [ "$B_STILL" -ne 0 ]; then
	llbitmap_pass "array did not start and FIRST_USE preserved on both members"
fi

llbitmap_fail "ambiguous outcome with injection active (started=$ARRAY_STARTED A_STILL=$A_STILL B_STILL=$B_STILL) -- neither a clean -EIO refusal nor a clean start; the test could not reach a verdict"

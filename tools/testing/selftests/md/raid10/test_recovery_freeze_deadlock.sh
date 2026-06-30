#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Reproducer for the forced-raise_barrier() vs freeze_array() deadlock in
# the per-bucket raid10 barrier code.
#
# The cycle (three parties, each holding what the next one needs):
#
#   mdX_resync   blocked in the 2nd+ (forced) raise_barrier() of a
#                recovery batch, waiting for nr_pending[idx] == 0.  The
#                already-raised barriers of the same batch hold
#                nr_sync_pending for r10bios that are built but not yet
#                submitted (submission happens only after the whole
#                window is built).
#   normal read  failed, owned by handle_read_error() (it keeps its
#                nr_pending[idx] until the allow_barrier() after
#                re-submit), or parked on the retry queues.
#   mdX_raid10   inside handle_read_error() -> freeze_array(conf, 1),
#                waiting for nr_sync_pending to drain -- which needs the
#                unsubmitted batch to complete, which needs the forced
#                raise to succeed, which needs the failed read to drain,
#                which needs raid10d.
#
# Reaching the cycle deterministically:
#
#   - The forced raise only exists when one recovery window builds two
#     or more r10bios, i.e. at least two mirror sets are rebuilding a
#     member in the same window.
#   - A failed read is only parked for raid10d retry (the leg that
#     freezes) if _enough() says the array survives without the erroring
#     device; a read error on a set's *last* in-sync member is returned
#     straight to the caller and never reaches handle_read_error().
#     This is why a near-2 double rebuild cannot trip the bug by itself:
#     both pairs are down to their last copy, so every read error in the
#     forced raise's bucket takes the direct-EIO path.  A *near-3* set
#     that is rebuilding one member still has two in-sync copies, so a
#     read error there is both redundant (parks, freezes) and lives in
#     the very unit the forced raise targets.
#   - chunk size == barrier unit (64 MB), so with 6 disks in near-3 and
#     slots 0+3 rebuilding, every recovery window builds r10bio #1 at
#     array unit 2k (set 0/1/2) and r10bio #2 -- the forced raise -- at
#     array unit 2k+1 (set 3/4/5).  Whole units, no 1/1024 hash lottery.
#   - dm-flakey 'error_reads' segments on members 4 AND 5 inside array
#     unit 1 make direct reads of that range fail (writes still pass)
#     whichever in-sync copy read_balance picks, so normal reads park in
#     exactly the bucket the forced raise targets.  Member 3 of the same
#     set is the one rebuilding.
#   - recovery is throttled so its own reads stay far below the bad
#     segment for the whole watch period (recovery reads must not hit
#     the injected errors; only normal I/O may).
#
# On a kernel with the bug the array wedges within seconds: recovery
# stops, all new I/O hangs, mdX_resync sits in raise_barrier() and
# mdX_raid10 in freeze_array(), both in D state.  The only way out is an
# administrative abort ('echo idle > sync_action'), which this test also
# exercises before reporting FAIL.
#
# On a fixed kernel the forced raise backs off while a freeze is
# pending, the batch is submitted, the freeze completes, and recovery
# survives the read-error storm; after lifting the injection it runs to
# completion.  PASS.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "${HERE}/lib.sh"

# This reproducer deliberately drives the array into the forced-raise_barrier()
# vs freeze_array() deadlock.  On the in-tree md driver (MD_SUBSYS=md) that is a
# genuine upstream wedge: ${MD}_resync parks in raise_barrier() and ${MD}_raid10
# in freeze_array(), both in D state, and only a reboot clears them (the
# per-bucket back-off fix lives in raid10_ms, not in stock md).  Refuse to run
# against in-tree md so the suite can never brick that kernel.
if [ "$MD_SUBSYS" = md ]; then
	raid10_skip "forced-raise vs freeze_array deadlock genuinely wedges the in-tree md driver (D-state kthreads, reboot needed); run only on ms (MD_SUBSYS=ms)"
fi

WATCH_SECS="${RAID10_WEDGE_WATCH_SECS:-60}"
STALL_SECS="${RAID10_WEDGE_STALL_SECS:-10}"
SYNC_KBPS="${RAID10_SYNC_KBPS:-500}"
IMG_DIR="${RAID10_IMG_DIR:-/dev/shm}"

# Geometry.  Chunk == barrier unit (64 MB) so recovery windows map to
# whole units; 2 chunks of data per member; 6 members in near-3 =
# 4 array units, sets {0,1,2} (even units) and {3,4,5} (odd units).
CHUNK_KB=$((64 * 1024))
DATA_OFFSET_SECT=$((4 * 2048))			# --data-offset=4M
LOOP_SIZE="132M"				# 4M offset + 2 x 64M chunks
# Bad segment: 1 MB of array unit 1, at in-chunk offset 56 MB.  Array
# unit 1 lives on members 3+4+5 at data offset 0..64M, so on members
# 4 and 5 the segment starts at 4M (data offset) + 56M.  1 MB = 256
# distinct 4 KB blocks keeps the per-rdev badblocks tables (512 entries)
# from filling up and failing a device outright.
BAD_ARRAY_OFF_MB=120				# 64 (unit 1 start) + 56
BAD_DEV_START_SECT=$(((4 + 56) * 2048))
BAD_LEN_SECT=2048				# 1 MB

raid10_require_root
raid10_require_tools
raid10_require_module
raid10_require_tmpfs "$IMG_DIR" \
	"$((8 * $(raid10_size_to_kb "$LOOP_SIZE") + 256 * 1024))"

if ! command -v dmsetup >/dev/null 2>&1; then
	raid10_skip "missing tool: dmsetup"
fi
modprobe dm-flakey >/dev/null 2>&1 || true
if ! dmsetup targets 2>/dev/null | grep -qw flakey; then
	raid10_skip "dm-flakey target not available"
fi

DEV="$(raid10_alloc_md)"
MD="${DEV##*/}"
RAID10_TEST_MD="$MD"
SYSFS="$(_raid10_sysfs "$MD")"

DM_NAMES=("r10wedge4-${MD}" "r10wedge5-${MD}")
FIO_PID=""

# Cleanup must run even from a wedged state, so every step that can
# block on array I/O is timeout-guarded.  The md array sits on top of
# the dm wrappers, which sit on top of loops, so teardown is strictly:
# fio -> sync_action idle -> mdadm --stop -> dmsetup remove -> loops.
test_cleanup() {
	set +e
	[ -n "$FIO_PID" ] && kill "$FIO_PID" >/dev/null 2>&1
	wait >/dev/null 2>&1
	if [ -b "/dev/${MD}" ]; then
		timeout 30 sh -c "echo idle > '$SYSFS/sync_action'" 2>/dev/null
		timeout 30 "$MDADM" --stop "/dev/${MD}" >/dev/null 2>&1
	fi
	local n
	for n in "${DM_NAMES[@]}"; do
		dmsetup remove --retry "$n" >/dev/null 2>&1
	done
	raid10_cleanup
}
trap test_cleanup EXIT

raid10_init_registry
LOOPS=()
for i in 0 1 2 3 4 5; do
	LOOPS+=("$(raid10_make_loop "$IMG_DIR" "$LOOP_SIZE")")
done
SPARES=()
for i in 0 1; do
	SPARES+=("$(raid10_make_loop "$IMG_DIR" "$LOOP_SIZE")")
done
raid10_load_registry

# Members 4 and 5 go behind dm wrappers so the error segment can be
# swapped in and out at runtime.  Start with plain passthroughs.
MEMBER_SECT=$(blockdev --getsz "${LOOPS[4]}")
dmsetup create "${DM_NAMES[0]}" --table "0 $MEMBER_SECT linear ${LOOPS[4]} 0"
dmsetup create "${DM_NAMES[1]}" --table "0 $MEMBER_SECT linear ${LOOPS[5]} 0"

inject_on() {
	local end=$((BAD_DEV_START_SECT + BAD_LEN_SECT)) i
	for i in 0 1; do
		local loop="${LOOPS[$((4 + i))]}"
		dmsetup suspend "${DM_NAMES[$i]}"
		dmsetup reload "${DM_NAMES[$i]}" --table "
0 $BAD_DEV_START_SECT linear $loop 0
$BAD_DEV_START_SECT $BAD_LEN_SECT flakey $loop $BAD_DEV_START_SECT 0 86400 1 error_reads
$end $((MEMBER_SECT - end)) linear $loop $end"
		dmsetup resume "${DM_NAMES[$i]}"
	done
}

inject_off() {
	local i
	for i in 0 1; do
		dmsetup suspend "${DM_NAMES[$i]}"
		dmsetup reload "${DM_NAMES[$i]}" \
			--table "0 $MEMBER_SECT linear ${LOOPS[$((4 + i))]} 0"
		dmsetup resume "${DM_NAMES[$i]}"
	done
}

"$MDADM" --create --run --force --assume-clean "$DEV" --level=10 \
	--raid-devices=6 --layout=n3 --chunk="$CHUNK_KB" \
	--data-offset=4M --bitmap=none \
	"${LOOPS[0]}" "${LOOPS[1]}" "${LOOPS[2]}" "${LOOPS[3]}" \
	"/dev/mapper/${DM_NAMES[0]}" "/dev/mapper/${DM_NAMES[1]}" \
	>/dev/null 2>&1
sleep 1
raid10_wait_idle "$MD"

# The geometry math above assumes mdadm honoured --data-offset.
DOFF=$("$MDADM" -E "${LOOPS[1]}" 2>/dev/null | awk '/Data Offset/ {print $4}')
if [ "${DOFF:-0}" -ne "$DATA_OFFSET_SECT" ]; then
	raid10_fail "unexpected data offset ${DOFF:-?} (want $DATA_OFFSET_SECT)"
fi

# Read errors are deliberately plentiful; keep md from kicking the
# erroring members out for exceeding their per-hour read error budget.
echo 100000 > "$SYSFS/max_read_errors"
raid10_set_sync_speed "$MD" "$SYNC_KBPS"

# Fail members 0 and 3 (one per near-3 set) and re-add two spares with
# recovery frozen, so a single recovery pass rebuilds both slots -- the
# forced raise only exists when one window builds >= 2 r10bios.
echo frozen > "$SYSFS/sync_action"
"$MDADM" "$DEV" --fail "${LOOPS[0]}" --remove "${LOOPS[0]}" >/dev/null 2>&1
"$MDADM" "$DEV" --fail "${LOOPS[3]}" --remove "${LOOPS[3]}" >/dev/null 2>&1
"$MDADM" "$DEV" --add "${SPARES[0]}" --add "${SPARES[1]}" >/dev/null 2>&1
echo idle > "$SYSFS/sync_action"

for i in $(seq 1 20); do
	[ "$(cat "$SYSFS/sync_action")" = "recover" ] && break
	sleep 0.5
done
if [ "$(cat "$SYSFS/sync_action")" != "recover" ]; then
	raid10_fail "double-spare recovery did not start"
fi
REBUILDING=$(grep -l -E "spare|replacement" "$SYSFS"/dev-*/state 2>/dev/null | wc -l)
if [ "$REBUILDING" -lt 2 ]; then
	raid10_fail "expected 2 rebuilding members, found $REBUILDING"
fi

inject_on

# Hammer the bad megabyte with mixed direct I/O.  Each failing read
# parks in the forced raise's bucket and feeds raid10d a freeze_array()
# call; md then records a badblock for the failed sectors, which would
# silence that block (read_balance skips badblocked copies without
# parking anything).  The writes succeed through the flakey segments
# and clear those badblocks again, so the supply of parking reads stays
# continuous instead of burning out after one pass over the range.
# The IOPS cap keeps the error rate well under max_read_errors for the
# whole watch (unthrottled tmpfs I/O burns >100k read errors in seconds
# and md kicks the member out despite the raised budget).
fio --name=errload --filename="$DEV" --offset="${BAD_ARRAY_OFF_MB}M" \
	--size=1M --rw=randrw --rwmixread=75 --bs=4k --direct=1 \
	--numjobs=4 --rate_iops=100 --time_based \
	--runtime=$((WATCH_SECS + 60)) \
	--continue_on_error=io --group_reporting --output=/dev/null \
	>/dev/null 2>&1 &
FIO_PID=$!

resync_stack() {
	local pid
	pid=$(pgrep -x "${MD}_resync" | head -1) || true
	[ -n "$pid" ] && cat "/proc/$pid/stack" 2>/dev/null || true
}
daemon_stack() {
	local pid
	pid=$(pgrep -x "${MD}_raid10" | head -1) || true
	[ -n "$pid" ] && cat "/proc/$pid/stack" 2>/dev/null || true
}

WEDGED=0
last_sc=""
last_change=$(date +%s)
for i in $(seq 1 "$WATCH_SECS"); do
	sleep 1
	action=$(cat "$SYSFS/sync_action" 2>/dev/null || echo gone)
	sc=$(cat "$SYSFS/sync_completed" 2>/dev/null || echo gone)
	now=$(date +%s)
	if [ "$sc" != "$last_sc" ]; then
		last_sc="$sc"
		last_change=$now
		continue
	fi
	[ "$action" = "recover" ] || continue
	[ $((now - last_change)) -ge "$STALL_SECS" ] || continue
	rs=$(resync_stack)
	ds=$(daemon_stack)
	if echo "$rs" | grep -q -E "raise_barrier|raid10_sync_request" &&
	   echo "$ds" | grep -q -E "freeze_array|handle_read_error"; then
		WEDGED=1
		break
	fi
done

if [ "$WEDGED" = "1" ]; then
	echo "WEDGE: recovery stalled ${STALL_SECS}s at '$last_sc'" >&2
	echo "--- ${MD}_resync stack:" >&2;  resync_stack >&2
	echo "--- ${MD}_raid10 stack:" >&2;  daemon_stack >&2
	# Debug aid: keep the wedge alive for external inspection.
	if [ "${RAID10_WEDGE_HOLD_SECS:-0}" -gt 0 ]; then
		echo "holding wedge for ${RAID10_WEDGE_HOLD_SECS}s" >&2
		sleep "$RAID10_WEDGE_HOLD_SECS"
	fi
	kill "$FIO_PID" >/dev/null 2>&1 || true
	# The documented escape hatch must still work, or the machine
	# needs a reboot -- check it before reporting the failure.
	if ! timeout 30 sh -c "echo idle > '$SYSFS/sync_action'"; then
		echo "FATAL: 'echo idle > sync_action' is also wedged;" \
		     "array is unrecoverable without reboot" >&2
	fi
	raid10_fail "force-raise vs freeze_array deadlock: recovery wedged under a read-error storm"
fi

# Survived the storm.  Stop the error source, let recovery finish, and
# make sure it actually completes.
kill "$FIO_PID" >/dev/null 2>&1 || true
wait "$FIO_PID" 2>/dev/null || true
FIO_PID=""
inject_off
raid10_set_sync_speed "$MD" 2000000
raid10_wait_idle "$MD" 180 || raid10_fail "recovery never completed after lifting injection"
DEGRADED=$(cat "$SYSFS/degraded" 2>/dev/null || echo unreadable)
if [ "$DEGRADED" != "0" ]; then
	raid10_fail "array still degraded ($DEGRADED) after recovery"
fi

raid10_pass "recovery survived a read-error storm during a double rebuild (no force-raise vs freeze deadlock)"

#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# freeze_array() must stay correct when a management quiesce races an
# active sync.
#
# Why this exists
# ---------------
# The per-bucket conversion changed raid10_quiesce() from a bare
# raise_barrier()/lower_barrier() to freeze_array()/unfreeze_array().
# That makes the management freeze path responsible for draining in-flight
# *sync* I/O, which the global design never had to do.  Four commits guard
# this management entry (raid10_quiesce -> freeze_array(conf, 0), i.e.
# extra == 0 -- distinct from handle_read_error()'s extra == 1 that the
# deadlock reproducer covers):
#
#   "count in-flight sync I/O so freeze_array() cannot return early"
#       adds nr_sync_pending so the freeze waits for resync r10bios that
#       live in barrier[idx], not nr_pending[idx].
#   "don't lose freeze_array()'s wakeup to a barrier-counter race"
#       fixes the lost wakeup (wait_barrier_nolock undo + the smp_mb()
#       between setting array_freeze_pending and sampling the counters).
#   "return -EINTR from raise_barrier() when sync is interrupted"
#       lets the aborted sync unwind instead of blocking uninterruptibly
#       behind the freeze.
#   "assert barrier accounting cannot underflow"
#       turns a broken raise/lower balance into a loud BUG_ON/WARN rather
#       than a silent early-return.  Run a kernel built with these asserts
#       (CONFIG_MD_RAID10 + lockdep/BUG-on-data-corruption) to get the
#       most out of this test.
#
# Trigger
# -------
# A throttled 'check' keeps sync r10bios in flight (nr_sync_pending > 0).
# We then repeatedly toggle the array readonly<->readwrite.  Each
# 'mdadm --readonly' both aborts the sync (MD_RECOVERY_INTR ->
# raise_barrier() must return -EINTR and unwind) and runs
# __md_stop_writes() -> raid10_quiesce(1) -> freeze_array(conf, 0), which
# must drain the in-flight sync I/O before returning.  'mdadm --readwrite'
# restores the array and we restart the check.
#
# PASS:  every toggle completes within the timeout, neither ${MD}_resync
#        nor ${MD}_raid10 is wedged in freeze_array()/raise_barrier(), no
#        new raid10 barrier splat appears in dmesg, and a final unthrottled
#        sync completes leaving the array non-degraded.
# FAIL:  a readonly (freeze) toggle times out, a thread stalls in D state
#        in the barrier code, or dmesg shows a barrier-accounting WARN/BUG.
# SKIP:  tooling/tmpfs prerequisites missing.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "${HERE}/lib.sh"

IMG_DIR="${RAID10_IMG_DIR:-/dev/shm}"
LOOP_SIZE="${RAID10_LOOP_SIZE:-256M}"
TOGGLES="${RAID10_FREEZE_TOGGLES:-30}"
SYNC_KBPS="${RAID10_SYNC_KBPS:-2000}"
TOGGLE_TIMEOUT="${RAID10_TOGGLE_TIMEOUT:-30}"

raid10_require_root
raid10_require_tools
raid10_require_module
raid10_require_tmpfs "$IMG_DIR" \
	"$((4 * $(raid10_size_to_kb "$LOOP_SIZE") + 128 * 1024))"

DEV="$(raid10_alloc_md)"
MD="${DEV##*/}"
RAID10_TEST_MD="$MD"
SYSFS="$(_raid10_sysfs "$MD")"

# Forcefully restore a writable, idle, stopped array even from a half-frozen
# state; the generic trap in lib.sh then tears down loops.
freeze_cleanup() {
	set +e
	if [ -b "/dev/${MD}" ]; then
		timeout 20 "$MDADM" --readwrite "/dev/${MD}" >/dev/null 2>&1
		timeout 20 sh -c "echo idle > '$SYSFS/sync_action'" 2>/dev/null
	fi
	raid10_cleanup
}
trap freeze_cleanup EXIT

raid10_init_registry
LOOPS=()
for i in 0 1 2 3; do
	LOOPS+=("$(raid10_make_loop "$IMG_DIR" "$LOOP_SIZE")")
done
raid10_load_registry

"$MDADM" --create --run --force --assume-clean "$DEV" --level=10 \
	--raid-devices=4 --layout=n2 --bitmap=none "${LOOPS[@]}" >/dev/null 2>&1
sleep 1
raid10_wait_idle "$MD"

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

# Start a throttled check so sync r10bios are continuously in flight.
start_check() {
	raid10_set_sync_speed "$MD" "$SYNC_KBPS"
	echo check > "$SYSFS/sync_action" 2>/dev/null || true
}

DMESG_PRE=$(dmesg 2>/dev/null | wc -l || echo 0)

start_check
sleep 1
# Prove a sync is actually in flight before we start freezing: freeze_array's
# drain path (the target) is only exercised when there are in-flight sync
# r10bios.  If the throttled check never engaged, freezing a quiescent array
# drains trivially and "survived N toggles" would PASS without testing anything.
raid10_assert_syncing "$MD" "before the first freeze toggle" \
	|| raid10_fail "throttled check never engaged -- freeze_array vs active-sync not exercised"

froze_with_sync=0
for t in $(seq 1 "$TOGGLES"); do
	# Count toggles where a sync was genuinely in flight at freeze time, so
	# the verdict can prove freeze_array actually had sync r10bios to drain.
	case "$(cat "$SYSFS/sync_action" 2>/dev/null || echo idle)" in
		check|repair|resync|recover) froze_with_sync=$((froze_with_sync + 1)) ;;
	esac
	# Freeze: abort the sync and quiesce.  This is the call that must
	# drain nr_sync_pending without hanging.
	if ! timeout "$TOGGLE_TIMEOUT" "$MDADM" --readonly "$DEV" >/dev/null 2>&1; then
		echo "--- ${MD}_resync stack:" >&2; resync_stack >&2
		echo "--- ${MD}_raid10 stack:" >&2; daemon_stack >&2
		raid10_fail "toggle $t: 'mdadm --readonly' (freeze_array) wedged for ${TOGGLE_TIMEOUT}s"
	fi

	# A wedge can also show up as a thread parked in the barrier code even
	# if the ioctl returned; catch that explicitly.
	rs=$(resync_stack); ds=$(daemon_stack)
	if echo "$rs" | grep -q -E "raise_barrier" &&
	   echo "$ds" | grep -q -E "freeze_array"; then
		echo "--- ${MD}_resync stack:" >&2; echo "$rs" >&2
		echo "--- ${MD}_raid10 stack:" >&2; echo "$ds" >&2
		raid10_fail "toggle $t: threads stalled in raise_barrier()/freeze_array()"
	fi

	if ! timeout "$TOGGLE_TIMEOUT" "$MDADM" --readwrite "$DEV" >/dev/null 2>&1; then
		raid10_fail "toggle $t: 'mdadm --readwrite' wedged for ${TOGGLE_TIMEOUT}s"
	fi
	start_check
	sleep 0.3
done

# Any barrier-accounting assert that fired during the run?
SPLAT=$(dmesg 2>/dev/null | tail -n +$((DMESG_PRE + 1)) \
	| grep -E -i 'raid10.*(barrier|nr_sync|underflow)|WARNING.*raid10|BUG.*raid10|array_freeze_pending' \
	|| true)
if [ -n "$SPLAT" ]; then
	echo "$SPLAT" >&2
	raid10_fail "raid10 barrier-accounting splat in dmesg during freeze/resync toggling"
fi

# Let an unthrottled sync finish and confirm the array is healthy.
raid10_set_sync_speed "$MD" 2000000
echo check > "$SYSFS/sync_action" 2>/dev/null || true
sleep 1
raid10_wait_idle "$MD" 180 || raid10_fail "sync never completed after $TOGGLES freeze toggles"

DEGRADED=$(cat "$SYSFS/degraded" 2>/dev/null || echo unreadable)
if [ "$DEGRADED" != "0" ]; then
	raid10_fail "array degraded ($DEGRADED) after freeze/resync toggling"
fi

# At least one freeze must have drained an in-flight sync; otherwise every
# toggle froze a quiescent array and the target drain path was never exercised.
[ "$froze_with_sync" -gt 0 ] || raid10_fail "no freeze toggle occurred while a sync was in flight -- freeze_array-vs-active-sync never exercised (a no-op run cannot PASS)"

raid10_pass "survived $TOGGLES quiesce(freeze_array) vs active-sync toggles ($froze_with_sync with a sync in flight) with no hang, splat, or degradation"

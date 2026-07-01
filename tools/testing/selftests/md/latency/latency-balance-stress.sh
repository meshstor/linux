#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Lifetime / teardown stress test for the latency-aware read balancer.
#
# The SED code carries hand-written lifetime rules whose failure mode is a
# kernel use-after-free or leak, not a skewed read ratio:
#   * rdev->lat_stats is freed in md_rdev_clear() and read locklessly in
#     md_lat_read_done() (guarded only by the completing read's nr_pending);
#   * the per-mddev fold worker walks rdev_for_each_rcu() while membership
#     changes underneath it;
#   * raid{1,10}_free() -> md_latency_fold_stop() must cancel_delayed_work_sync
#     a worker that re-queues itself every ~25ms, with mddev_destroy() as a
#     backstop.
# None of that is exercised by the functional tests, which never remove a
# disk or tear an array down under activity.
#
# This test hammers those paths under a continuous read load and then scans
# the kernel log for splats.  It is most valuable on a kernel built with
# CONFIG_KASAN=y (and lockdep / PROVE_LOCKING); on a stock kernel it still
# shakes the races but only oopses/WARNs are observable.
#
# Targets the meshstor-ms stack (/dev/msN) by default under MD_SUBSYS=ms;
# set MD_SUBSYS=md for the in-tree /dev/mdN driver -- see lib.sh.
set -euo pipefail

# Smaller legs than the functional tests: recovery after each re-add must
# be cheap because we do it many times.
: "${LATBAL_LEG_MB:=128}"
export LATBAL_LEG_MB

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

CHURN_ITERS="${LATBAL_CHURN_ITERS:-12}"
TOGGLE_ITERS="${LATBAL_TOGGLE_ITERS:-50}"
TEARDOWN_ITERS="${LATBAL_TEARDOWN_ITERS:-8}"

FIO_PID=""
stop_bg_fio() {
	[ -n "$FIO_PID" ] || return 0
	kill "$FIO_PID" >/dev/null 2>&1 || true
	wait "$FIO_PID" 2>/dev/null || true
	FIO_PID=""
}
# Make sure a backgrounded fio never outlives the script.
trap 'stop_bg_fio; latbal_cleanup' EXIT

latbal_require_root
latbal_require_tools
latbal_require_personality raid1
latbal_require_dm_delay
latbal_require_tmpfs

if latbal_kasan_active; then
	echo "note: CONFIG_KASAN active -- use-after-free will be caught"
else
	echo "note: KASAN not detected; run on a KASAN+lockdep kernel for full value"
fi

# Three legs so the array stays readable (>=2 active) while one churns.
# Skew the delays so the latency machinery stays engaged throughout.
latbal_make_leg 0
latbal_make_leg 1
latbal_make_leg 2
latbal_set_delay 1 1
latbal_set_delay 2 "$LATBAL_SLOW_MS"

latbal_create_array 1 3
latbal_require_feature

latbal_dmesg_mark start

# Continuous read load for phases A-C.  continue_on_error so a transient
# blip while a leg is failed does not abort the load generator.
reads_before=0
for i in 0 1 2; do reads_before=$(( reads_before + $(latbal_reads_of "$i") )); done
fio --name=stress --filename="$LATBAL_DEV" --rw=randread --bs=8k \
    --time_based --runtime=600 --direct=1 --iodepth=16 --numjobs=4 \
    --continue_on_error=all --group_reporting --minimal >/dev/null 2>&1 &
FIO_PID=$!
sleep 2		# let the fold worker spin up and publish EWMAs

# Prove the read load actually engaged BEFORE relying on a "no splat" verdict:
# a dead fio (bad args, device gone) or a run that issues no reads drives none
# of the lockless-completion / lifetime paths, yet the dmesg scan would still be
# clean and PASS.  Require the load generator alive AND reads reaching the legs.
kill -0 "$FIO_PID" 2>/dev/null \
	|| latbal_fail "background read load (fio) died at startup -- lifetime/UAF paths not exercised"
reads_after=0
for i in 0 1 2; do reads_after=$(( reads_after + $(latbal_reads_of "$i") )); done
[ "$(( reads_after - reads_before ))" -gt 100 ] \
	|| latbal_fail "read load did not reach the legs ($reads_before -> $reads_after reads) -- no read completions to race teardown against"

# Phase A: membership churn.  fail -> remove (md_rdev_clear frees lat_stats
# while the worker may be mid-walk) -> add (raid1_add_disk kicks the worker)
# -> recover.  Alternate legs 1 and 2 so leg 0 always anchors the array.
echo "phaseA: $CHURN_ITERS rounds of fail/remove/add under load"
churn_ok=0
for i in $(seq 1 "$CHURN_ITERS"); do
	idx=$(( (i % 2) + 1 ))
	leg="$(latbal_leg_path "$idx")"
	latbal_mdadm "$LATBAL_DEV" --fail "$leg"   >/dev/null 2>&1 || true
	# Count real removes: this is the op that frees lat_stats under the
	# worker's feet (the race under test).  Kept resilient (|| true elsewhere)
	# but a phase A where nothing ever removed is a no-op, not coverage.
	if latbal_mdadm "$LATBAL_DEV" --remove "$leg" >/dev/null 2>&1; then
		churn_ok=$(( churn_ok + 1 ))
	fi
	sleep 0.2
	latbal_mdadm "$LATBAL_DEV" --add "$leg"    >/dev/null 2>&1 || true
	latbal_wait_idle 60
done
[ "$churn_ok" -gt 0 ] || latbal_fail "phaseA membership churn never engaged (0/$CHURN_ITERS removes succeeded) -- the free-vs-worker race was not exercised"

# Phase B: kill-switch toggle churn.  Drives the worker's park/kick races
# and the kill-switch park path against live completions.
echo "phaseB: $TOGGLE_ITERS latency_balance toggles under load"
for _ in $(seq 1 "$TOGGLE_ITERS"); do
	echo 0 > "$LATBAL_SYS/latency_balance"
	echo 1 > "$LATBAL_SYS/latency_balance"
done

# Phase C: fold-cadence knob churn across its whole accepted range.
echo "phaseC: latency_fold_ms range sweep"
for v in 5 1000 25 7 1000 5 250; do
	echo "$v" > "$LATBAL_SYS/latency_fold_ms"
done
echo 25 > "$LATBAL_SYS/latency_fold_ms"

stop_bg_fio
latbal_mdadm --stop "$LATBAL_DEV" >/dev/null 2>&1 || true
LATBAL_DEV=""

# Phase D: start/stop churn.  Each create runs md_latency_fold_start and
# each stop runs raid1_free -> md_latency_fold_stop (cancel_delayed_work_sync
# against a worker that just re-queued), exercising the teardown cancel and
# the mddev_destroy backstop.
echo "phaseD: $TEARDOWN_ITERS create/load/stop cycles"
for _ in $(seq 1 "$TEARDOWN_ITERS"); do
	latbal_create_array 1 3
	# Brief load so the worker is actively requeuing at stop time.
	latbal_run_fio 1 || true
	latbal_mdadm --stop "$LATBAL_DEV" >/dev/null 2>&1 || true
	LATBAL_DEV=""
done

# Verdict: any KASAN report, oops, or memory-corruption splat fails; a
# WARNING is only treated as failure if it implicates md/raid/latency.
splat="$(latbal_dmesg_since_mark | grep -Ei \
	'kasan|use-after-free|slab-out-of-bounds|bug:|oops|general protection|null pointer deref|list_(add|del)|refcount_' || true)"
warn="$(latbal_dmesg_since_mark | grep -E 'WARNING:' | grep -Ei 'md|raid|lat' || true)"
if [ -n "$splat" ] || [ -n "$warn" ]; then
	echo "FAIL: kernel splat during stress:" >&2
	[ -n "$splat" ] && echo "$splat" >&2
	[ -n "$warn" ] && echo "$warn" >&2
	exit 1
fi

latbal_pass "latency-balance lifetime/teardown stress (no splats)"

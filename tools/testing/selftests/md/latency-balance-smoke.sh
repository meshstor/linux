#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Smoke test for ms latency-aware read balancing.
# RAID1 over two ramdisks, each behind dm-delay. Targets the ms stack:
# the build host's md_mod has none of this code.
#
# Requires: root, the freshly built ms modules (MODDIR), the
# meshstor-patched mdadm (MDADM; system mdadm rejects /dev/msN),
# dmsetup, fio, brd (must not be loaded yet).
#
# Phases:
#  1. asymmetric legs (0ms vs 2ms): >=99% of reads on the fast leg
#  2. latency_ewma_ns nonzero on BOTH legs (probes are working)
#  3. swap the delays live (dm table reload): traffic migrates within 2s
#  4. equalize fast (0ms/0ms), feature on: the stale ~ms EWMA must
#     rediscover to us-scale within seconds (probe/trickle liveness).
#     Read share stays pinned here BY DESIGN: ramdisk completions are
#     inline, nr_pending never accumulates, so the cost model sits in
#     its low-QD "fastest leg" regime - do not assert spread on
#     equal-fast legs.
#  5. equalize slow (2ms/2ms), feature on: dm-delay completes via its
#     kthread, so queuing is real and the pending term must spread the
#     load - no herding on a symmetric mirror (each leg >= 20%)
#  6. latency_balance=0: stock min-pending spread returns
#     (each leg >= 20%)
#  7. low-IOPS asymmetric, feature back on, SLOW leg at index 0 so
#     the stock tie-break cannot mask a regression: at a ~50 IOPS
#     trickle the adaptive per-leg gate must keep the served leg
#     measured - the slow leg may only see staleness-blip and probe
#     reads, never pinned herding bursts (P1 regression)
#  8. idle park and completion-path resume: ~2.6s without reads must
#     park the fold worker (observable: the park edge invalidates
#     both EWMAs to 0), and the first reads afterwards must resume
#     it (EWMAs repopulate)
set -euo pipefail

MODDIR=${MODDIR:-/home/mykola/linux-meshstor/build/devtest/meshstor-ms-0.0.dev}
MDADM=${MDADM:-/home/mykola/mdadm/mdadm}
MS=/dev/ms97
MSNAME=ms97
SIZE_MB=256
SLOW_MS=2
BRD_LOADED=0

cleanup() {
	set +e
	$MDADM --stop $MS >/dev/null 2>&1
	dmsetup remove lat-ewma-0 >/dev/null 2>&1
	dmsetup remove lat-ewma-1 >/dev/null 2>&1
	[ "$BRD_LOADED" = 1 ] && rmmod brd >/dev/null 2>&1
}
trap cleanup EXIT

fail() { echo "FAIL: $1"; exit 1; }

reads_of() {	# $1 = dm name (lat-ewma-0|lat-ewma-1)
	local dm
	dm=$(dmsetup info -c --noheadings -o blkdevname "$1")
	awk -v d="$dm" '$3==d {print $4}' /proc/diskstats
}

set_delay() {	# $1 = dm name, $2 = backing dev, $3 = delay ms
	local sectors
	sectors=$(blockdev --getsz "$2")
	dmsetup suspend "$1"
	dmsetup reload "$1" --table "0 $sectors delay $2 0 $3"
	dmsetup resume "$1"
}

run_fio() {	# $1 = seconds
	fio --name=lat-smoke --filename=$MS --rw=randread --bs=8k \
	    --runtime="$1" --time_based --direct=1 --iodepth=16 \
	    --numjobs=4 --group_reporting --minimal >/dev/null
}

run_fio_lowiops() {	# $1 = seconds; ~50 IOPS QD1 trickle
	fio --name=lat-trickle --filename=$MS --rw=randread --bs=8k \
	    --runtime="$1" --time_based --direct=1 --iodepth=1 \
	    --rate_iops=50 --minimal >/dev/null
}

share_check() {	# $1 = phase, $2 = leg name expected dominant, $3 = pct
	local a0 a1 d0 d1 tot want_leg=$2 pct=$3
	a0=$(reads_of lat-ewma-0); a1=$(reads_of lat-ewma-1)
	run_fio 10
	d0=$(( $(reads_of lat-ewma-0) - a0 ))
	d1=$(( $(reads_of lat-ewma-1) - a1 ))
	tot=$((d0 + d1))
	echo "$1: leg0=$d0 leg1=$d1"
	[ "$tot" -gt 0 ] || fail "$1: no reads observed"
	case $want_leg in
	leg0) [ $((d0 * 100)) -ge $((tot * pct)) ] || fail "$1: leg0 share < ${pct}%";;
	leg1) [ $((d1 * 100)) -ge $((tot * pct)) ] || fail "$1: leg1 share < ${pct}%";;
	both) [ $((d0 * 100)) -ge $((tot * pct)) ] &&
	      [ $((d1 * 100)) -ge $((tot * pct)) ] || fail "$1: spread < ${pct}% per leg";;
	esac
}

[ "$(id -u)" = 0 ] || fail "must run as root"
[ -e "$MODDIR/ms_mod.ko" ] || fail "built modules not found in $MODDIR"
[ -x "$MDADM" ] || fail "patched mdadm not found at $MDADM"

# Fresh modules: replace whatever ms generation is loaded.
if grep -q '^ms[0-9]' /proc/msstat 2>/dev/null; then
	fail "active ms arrays present - refusing to touch the ms stack"
fi
rmmod raid10_ms raid1_ms ms_mod >/dev/null 2>&1 || true
insmod "$MODDIR/ms_mod.ko"
insmod "$MODDIR/raid1_ms.ko"

# brd must be ours alone: if it is already loaded (or built in),
# /dev/ram* may hold someone else's data and the fill below would
# destroy it - and modprobe would silently ignore our parameters.
[ ! -d /sys/module/brd ] ||
	fail "brd already loaded - refusing to touch existing ramdisks"
modprobe brd rd_nr=2 rd_size=$((SIZE_MB * 1024))
BRD_LOADED=1
SECTORS=$(blockdev --getsz /dev/ram0)
dmsetup create lat-ewma-0 --table "0 $SECTORS delay /dev/ram0 0 0"
dmsetup create lat-ewma-1 --table "0 $SECTORS delay /dev/ram1 0 $SLOW_MS"

echo y | $MDADM --create $MS --run --force --level=1 --raid-devices=2 \
	--assume-clean --metadata=1.2 \
	/dev/mapper/lat-ewma-0 /dev/mapper/lat-ewma-1 >/dev/null
SYS=/sys/block/$MSNAME/ms
[ -d "$SYS" ] || fail "$SYS missing - is this the ms stack?"
[ "$(cat $SYS/latency_balance)" = 1 ] || fail "latency_balance default is not 1"

# Fill so reads span the device, then settle.
fio --name=warm --filename=$MS --rw=write --bs=1M --size=$((SIZE_MB - 8))M \
    --direct=1 --iodepth=8 >/dev/null
run_fio 5

# Phase 1: fast-leg affinity.
share_check phase1 leg0 99

# Phase 2: probe liveness - both legs measured.
e0=$(cat "$SYS"/dev-dm-*/latency_ewma_ns | sort -n | head -1)
e1=$(cat "$SYS"/dev-dm-*/latency_ewma_ns | sort -n | tail -1)
echo "phase2: ewma min=$e0 max=$e1"
[ "$e0" -gt 0 ] || fail "phase2: a leg was never measured (probes broken)"
[ "$e1" -gt "$e0" ] || fail "phase2: legs indistinguishable"

# Phase 3: swap delays live; expect migration to leg1.
set_delay lat-ewma-0 /dev/ram0 $SLOW_MS
set_delay lat-ewma-1 /dev/ram1 0
run_fio 2	# settle: > fold period + EWMA time constant
share_check phase3 leg1 99

# Phase 4: equalize fast - rediscovery. leg0's stale ~1.4ms EWMA must
# fall to us-scale. The adaptive gate keeps the busy leg near the
# 1-in-256 ceiling but drops a trickle-rate leg to shift 0, so the
# sequential-pin trickle plus probes re-measure leg0 within ~1s.
# The cold-leg EWMA floors around ~2.5us vs the hot leg's ~250ns
# (cold-path cost, weight 1 vs the hot leg's amortized queue weight),
# so assert a generous 100us.
set_delay lat-ewma-0 /dev/ram0 0
run_fio 5	# rediscovery window
emax=$(cat "$SYS"/dev-dm-*/latency_ewma_ns | sort -n | tail -1)
echo "phase4: ewma max=$emax after equalize-fast"
[ "$emax" -lt 100000 ] || fail "phase4: stale EWMA did not reconverge (max=${emax}ns)"

# Phase 5: equal slow legs, feature still ON - with real queuing the
# pending term must spread the load: no herding on a symmetric mirror.
set_delay lat-ewma-0 /dev/ram0 $SLOW_MS
set_delay lat-ewma-1 /dev/ram1 $SLOW_MS
run_fio 5	# settle: organic re-measurement at 2ms on both legs
share_check phase5 both 20

# Phase 6: kill switch off -> stock min-pending spread.
set_delay lat-ewma-0 /dev/ram0 0
set_delay lat-ewma-1 /dev/ram1 0
echo 0 > "$SYS/latency_balance"
run_fio 2	# settle
share_check phase6 both 20

# Phase 7: low-IOPS asymmetric - P1 regression. The old fixed
# 1-in-256 gate starved the served leg's EWMA inside the staleness
# horizon at trickle rates; whichever leg stayed measured (probes)
# then took 100% of reads in ~128-read pinned bursts. The slow leg
# sits at index 0 HERE ON PURPOSE: raid1's stock min-pending
# tie-break prefers the lowest index, so an abstaining-but-unmeasured
# kernel herds onto the slow leg too - this phase passes only when
# the adaptive per-leg gate keeps the served leg measured. Expected
# slow-leg traffic with the fix: ~1 stock-fallback read per staleness
# cycle plus ~1 probe per 128 array reads, ~3% - herding regimes
# show 30%+, so bound at 10%.
echo 1 > "$SYS/latency_balance"
set_delay lat-ewma-0 /dev/ram0 $SLOW_MS
run_fio_lowiops 5	# settle: re-measure both legs at trickle rate
a0=$(reads_of lat-ewma-0); a1=$(reads_of lat-ewma-1)
run_fio_lowiops 30
d0=$(( $(reads_of lat-ewma-0) - a0 ))
d1=$(( $(reads_of lat-ewma-1) - a1 ))
tot=$((d0 + d1))
echo "phase7: leg0=$d0 leg1=$d1"
[ "$tot" -gt 0 ] || fail "phase7: no reads observed"
[ $((d0 * 100)) -le $((tot * 10)) ] ||
	fail "phase7: slow-leg share > 10% at low IOPS (P1 herding)"

# Phase 8: idle park and completion-path resume. After the backoff
# ladder runs dry (~2.6s without a read) the worker must park, and
# the park edge invalidates the EWMAs - that zero is the observable.
# The first reads afterwards must kick it back via the completion
# path and re-measurement must repopulate the EWMAs on both legs
# (leg1 organically, leg0 via trickle/probes - both legs are equal
# fast here, same regime phase 4 already validated).
set_delay lat-ewma-0 /dev/ram0 0
sleep 6		# > full backoff ladder: worker parks and invalidates
emax=$(cat "$SYS"/dev-dm-*/latency_ewma_ns | sort -n | tail -1)
echo "phase8: ewma max=$emax after idle spell"
[ "$emax" -eq 0 ] || fail "phase8: fold worker did not park on idle (max=${emax}ns)"
run_fio 3	# completion kick + re-measurement
emin=$(cat "$SYS"/dev-dm-*/latency_ewma_ns | sort -n | head -1)
echo "phase8: ewma min=$emin after resume"
[ "$emin" -gt 0 ] || fail "phase8: worker did not resume after idle park"

echo PASS

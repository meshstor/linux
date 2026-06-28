#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Functional test for raid1 latency-aware (shortest-expected-delay) read
# balancing.  RAID1 over two dm-delay legs on loop-backed tmpfs.
#
# Targets the in-tree md driver via /dev/mdN by default (skips unless the
# running kernel was built from this tree); export MDADM / LATBAL_DEV_PREFIX
# / LATBAL_SYSFS_SUBDIR / LATBAL_MDSTAT to point it at the ms stack instead
# -- see latency-balance-lib.sh.
#
# Phases:
#  1. asymmetric legs (0ms vs 2ms): >=99% of reads on the fast leg
#  2. latency_ewma_ns nonzero on BOTH legs (probes are working)
#  3. swap the delays live: traffic migrates to the new fast leg within ~2s
#  4. equalize fast (0ms/0ms): the stale ~ms EWMA must rediscover to
#     us-scale within seconds (probe/trickle liveness).  Read share stays
#     pinned here BY DESIGN on inline-completing backends, so spread is NOT
#     asserted -- only that the stale EWMA reconverges.
#  5. equalize slow (2ms/2ms): dm-delay completes via its kthread, so
#     queuing is real and the pending term must spread the load (each leg
#     >= 20%): no herding on a symmetric mirror.
#  6. latency_balance=0: stock min-pending spread returns (each leg >= 20%).
#  7. low-IOPS asymmetric, SLOW leg at index 0 so raid1's stock lowest-index
#     min-pending tie-break cannot mask a regression: at a ~50 IOPS trickle
#     the adaptive per-leg gate must keep the served leg measured, so the
#     slow leg sees only staleness-blip and probe reads, never pinned
#     herding bursts (slow-leg share <= 10%).
#  8. idle park and completion-path resume: ~2.6s without reads parks the
#     fold worker (observable: both EWMAs invalidated to 0); the first reads
#     afterwards must resume it (EWMAs repopulate).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=latency-balance-lib.sh
. "$HERE/latency-balance-lib.sh"

SLOW=$LATBAL_SLOW_MS

latbal_require_root
latbal_require_tools
latbal_require_personality raid1
latbal_require_dm_delay
latbal_require_tmpfs

latbal_make_leg 0
latbal_make_leg 1
# leg0 fast, leg1 slow.
latbal_set_delay 1 "$SLOW"

latbal_create_array 1 2
latbal_require_feature
[ "$(cat "$LATBAL_SYS/latency_balance")" = 1 ] || latbal_fail "latency_balance default is not 1"

latbal_warm

# Phase 1: fast-leg affinity.
latbal_share_check phase1 leg0 99

# Phase 2: probe liveness -- both legs measured.
e0=$(latbal_ewma_min); e1=$(latbal_ewma_max)
echo "phase2: ewma min=$e0 max=$e1"
[ "$e0" -gt 0 ] || latbal_fail "phase2: a leg was never measured (probes broken)"
[ "$e1" -gt "$e0" ] || latbal_fail "phase2: legs indistinguishable"

# Phase 3: swap delays live; expect migration to leg1.
latbal_set_delay 0 "$SLOW"
latbal_set_delay 1 0
latbal_run_fio 2	# settle: > fold period + EWMA time constant
latbal_share_check phase3 leg1 99

# Phase 4: equalize fast -- rediscovery. leg0's stale ~ms EWMA must fall
# to us-scale via the trickle/probe re-measurement.  Generous 100us bound.
latbal_set_delay 0 0
latbal_run_fio 5
emax=$(latbal_ewma_max)
echo "phase4: ewma max=$emax after equalize-fast"
[ "$emax" -lt 100000 ] || latbal_fail "phase4: stale EWMA did not reconverge (max=${emax}ns)"

# Phase 5: equal slow legs, feature ON -- real queuing must spread load.
latbal_set_delay 0 "$SLOW"
latbal_set_delay 1 "$SLOW"
latbal_run_fio 5	# settle: organic re-measurement at 2ms on both legs
latbal_share_check phase5 both 20

# Phase 6: kill switch off -> stock min-pending spread.
latbal_set_delay 0 0
latbal_set_delay 1 0
echo 0 > "$LATBAL_SYS/latency_balance"
latbal_run_fio 2	# settle
latbal_share_check phase6 both 20

# Phase 7: low-IOPS asymmetric, slow leg at index 0 (defeats the stock
# lowest-index tie-break).  Expected slow-leg traffic with the adaptive
# gate: ~1 stock-fallback read per staleness cycle plus ~1 probe per 128
# array reads, ~3%; herding regimes show 30%+, so bound at 10%.
echo 1 > "$LATBAL_SYS/latency_balance"
latbal_set_delay 0 "$SLOW"
latbal_run_fio_lowiops 5	# settle: re-measure both legs at trickle rate
a0=$(latbal_reads_of 0); a1=$(latbal_reads_of 1)
latbal_run_fio_lowiops 30
d0=$(( $(latbal_reads_of 0) - a0 ))
d1=$(( $(latbal_reads_of 1) - a1 ))
tot=$((d0 + d1))
echo "phase7: leg0=$d0 leg1=$d1"
[ "$tot" -gt 0 ] || latbal_fail "phase7: no reads observed"
[ $((d0 * 100)) -le $((tot * 10)) ] \
	|| latbal_fail "phase7: slow-leg share > 10% at low IOPS (herding)"

# Phase 8: idle park and completion-path resume.  After the backoff ladder
# runs dry (~2.6s without a read) the worker parks and the park edge
# invalidates the EWMAs -- that zero is the observable.  The first reads
# afterwards must kick it back via the completion path.
latbal_set_delay 0 0
sleep 6		# > full backoff ladder: worker parks and invalidates
emax=$(latbal_ewma_max)
echo "phase8: ewma max=$emax after idle spell"
[ "$emax" -eq 0 ] || latbal_fail "phase8: fold worker did not park on idle (max=${emax}ns)"
latbal_run_fio 3	# completion kick + re-measurement
emin=$(latbal_ewma_min)
echo "phase8: ewma min=$emin after resume"
[ "$emin" -gt 0 ] || latbal_fail "phase8: worker did not resume after idle park"

latbal_pass "raid1 latency-aware read balancing"

#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Functional test for raid10 latency-aware (shortest-expected-delay) read
# balancing.  raid10's read_balance() is a separate implementation from
# raid1's choose_best_rdev() -- it loops over conf->copies with near/far
# geometry and mutates slot/rdev in place rather than returning early -- so
# it needs its own coverage; raid1 passing proves nothing here.
#
# Two dm-delay legs in a near=2 layout: every sector has a copy on both
# legs, so read_balance always chooses between the two, exactly like the
# raid1 case but through the raid10 picker.  Targets the meshstor-ms stack
# (/dev/msN) by default under MD_SUBSYS=ms; set MD_SUBSYS=md for the
# in-tree /dev/mdN driver -- see lib.sh.
#
# Phases mirror the raid1 test (1-6, 8); phase 7's raid1-specific
# lowest-index tie-break is replaced by a trickle-liveness check that does
# not assume a tie-break order.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

SLOW=$LATBAL_SLOW_MS

latbal_require_root
latbal_require_tools
latbal_require_personality raid10
latbal_require_dm_delay
latbal_require_tmpfs

latbal_make_leg 0
latbal_make_leg 1
latbal_set_delay 1 "$SLOW"	# leg0 fast, leg1 slow

# near=2 over 2 devices: a mirror, both legs hold every block.
latbal_create_array 10 2 n2
latbal_require_feature
[ "$(cat "$LATBAL_SYS/latency_balance")" = 1 ] || latbal_fail "latency_balance default is not 1"

latbal_warm

# Phase 1: fast-leg affinity through the raid10 picker.
latbal_share_check phase1 leg0 99

# Phase 2: probe liveness -- both legs measured.
e0=$(latbal_ewma_min); e1=$(latbal_ewma_max)
echo "phase2: ewma min=$e0 max=$e1"
[ "$e0" -gt 0 ] || latbal_fail "phase2: a leg was never measured (probes broken)"
[ "$e1" -gt "$e0" ] || latbal_fail "phase2: legs indistinguishable"

# Phase 3: swap delays live; expect migration to leg1.
latbal_set_delay 0 "$SLOW"
latbal_set_delay 1 0
latbal_run_fio 2
latbal_share_check phase3 leg1 99

# Phase 4: equalize fast -- stale ~ms EWMA must reconverge to us-scale.
latbal_set_delay 0 0
latbal_run_fio 5
emax=$(latbal_ewma_max)
echo "phase4: ewma max=$emax after equalize-fast"
[ "$emax" -lt 100000 ] || latbal_fail "phase4: stale EWMA did not reconverge (max=${emax}ns)"

# Phase 5: equal slow legs, feature ON -- real queuing must spread load.
latbal_set_delay 0 "$SLOW"
latbal_set_delay 1 "$SLOW"
latbal_run_fio 5
latbal_share_check phase5 both 20

# Phase 6: kill switch off -> stock spread.
latbal_set_delay 0 0
latbal_set_delay 1 0
echo 0 > "$LATBAL_SYS/latency_balance"
latbal_run_fio 2
latbal_share_check phase6 both 20

# Phase 7': low-IOPS liveness.  No lowest-index tie-break assumption here
# (raid10 slot order comes from raid10_find_phys, not disk index), so
# rather than bound the slow-leg share we assert the adaptive per-leg gate
# keeps BOTH legs measured at a trickle -- the property the gate exists to
# guarantee.  A starved leg would decay to ewma==0 inside the staleness
# horizon.
echo 1 > "$LATBAL_SYS/latency_balance"
latbal_set_delay 0 "$SLOW"
latbal_run_fio_lowiops 20	# trickle on asymmetric legs
e0=$(latbal_ewma_min)
echo "phase7: ewma min=$e0 at low IOPS"
[ "$e0" -gt 0 ] || latbal_fail "phase7: a leg decayed to unmeasured at low IOPS (gate too coarse)"

# Phase 8: idle park and completion-path resume.
latbal_set_delay 0 0
latbal_set_delay 1 0
sleep 6
emax=$(latbal_ewma_max)
echo "phase8: ewma max=$emax after idle spell"
[ "$emax" -eq 0 ] || latbal_fail "phase8: fold worker did not park on idle (max=${emax}ns)"
latbal_run_fio 3
emin=$(latbal_ewma_min)
echo "phase8: ewma min=$emin after resume"
[ "$emin" -gt 0 ] || latbal_fail "phase8: worker did not resume after idle park"

latbal_pass "raid10 latency-aware read balancing"

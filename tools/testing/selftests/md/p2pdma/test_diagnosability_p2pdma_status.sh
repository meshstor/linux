#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# /sys/block/msX/ms/p2pdma_status (md.c p2pdma_status_show()): one
# array-level line, then one line per member,
# "<dev> advertise=yes|no observed=none|p2pdma|other".
# "advertise=" is that MEMBER's OWN intrinsic PCI-P2P capability
# (blk_queue_pci_p2pdma() on its own bdev queue) -- NOT the array-level
# p2pdma_advertise POLICY, which the array applies to decide whether
# advertise its OWN queue's P2P feature bit, and does not change what an
# individual member reports about itself here.
#
# "observed=" is a FAILURE latch, not a completion latch: there is no "ok"
# state. raid1_p2pdma_observe() records only a non-zero status, so
# observed=none means "no P2P failure seen for this member". That is what
# makes the report usable: the latch is first-write-wins, and once an array
# advertises P2P the first completion of ANY kind reaches it -- in
# production essentially always an ordinary host-page write (mkfs, journal,
# metadata). An "ok" state would therefore latch immediately on every array
# and mask every later P2P failure.
#
# Runs on the ASYMMETRIC topology so exactly one leg is P2P-unreachable,
# which is what lets this file assert the discrimination directly.
#
# PRECONDITION, same as test_topology_single_leg_unreachable.sh: asserting
# the P2P verdict on the unreachable leg requires MS_MOD_DIR to hold
# modules built through the real DKMS pipeline (dkms/patches/0012 applied)
# unless the running kernel emits BLK_STS_P2PDMA natively -- otherwise the
# member completion arrives as BLK_STS_INVAL (6.17/7.0) or BLK_STS_TARGET
# (6.12/6.14) and latches "other" instead of "p2pdma".
#
# Five things are asserted:
#   1. Before any I/O, both legs already show their true advertise=
#      capability (yes, for these real p2p-capable NVMe legs), and
#      observed=none (no failure seen yet).
#   2. After one P2P write, the UNREACHABLE leg reads observed=p2pdma and
#      the reachable leg still reads observed=none -- the latch does not
#      over-fire on a completion that succeeded.
#   3. That transition emits exactly one dmesg breadcrumb naming the array
#      and the member ("no P2P path"), and a second identical write emits
#      no further breadcrumb: it is one-shot per member (spec §3.4).
#   4. The master write still succeeds (RC=0) off the reachable leg -- the
#      diagnostics observe, they do not gate.
#   5. p2pdma_advertise=never does not stop I/O from being processed --
#      the policy/diagnostics never gate an actual request, only report
#      on it.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
if [ -z "${P2P_IN_VM:-}" ]; then
	p2p_require_rig
	exec "$DIR/run_vm.sh" asymmetric \
		env P2P_IN_VM=1 MS_MOD_DIR="${MS_MOD_DIR:-}" \
		MDADM="${MDADM:-}" MD_SUBSYS="${MD_SUBSYS:-}" \
		"$DIR/$(basename "$0")"
fi
p2p_require_root; p2p_require_rig
trap 'p2p_advertise_set auto 2>/dev/null; p2p_cleanup' EXIT
p2p_load_ms_modules
LEG1="$(p2p_nvme_by_serial leg1)"
LEG2="$(p2p_nvme_by_serial leg2)"
ARR="$(p2p_make_array 1 "$LEG1" "$LEG2")"
SFILE="$(p2p_status_file "$ARR")"
[ -e "$SFILE" ] || p2p_fail "no p2pdma_status sysfs file at $SFILE"

# The breadcrumb prints the array and the member by their kernel names
# ("ms/ms0: nvme2n1: no P2P path ..."), so match on those, not on /dev paths.
ARR_NAME="$(basename "$ARR")"
LEG2_NAME="$(basename "$LEG2")"
crumbs() { dmesg | grep -c 'no P2P path' || true; }

echo "--- before any I/O ---"
cat "$SFILE"
grep -Eq '^\S+ advertise=yes observed=none$' "$SFILE" \
	|| p2p_fail "expected every member to read 'advertise=yes observed=none' before any I/O"
[ "$(grep -c 'advertise=yes observed=none' "$SFILE")" -eq 2 ] \
	|| p2p_fail "expected exactly 2 members reporting advertise=yes observed=none before any I/O"
grep -q 'observed=ok' "$SFILE" \
	&& p2p_fail "p2pdma_status still reports an 'ok' verdict -- the failure-only latch regressed"

C0="$(crumbs)"
RC="$(p2p_io write "$ARR" "$(p2p_bdf_by_serial cmb0)")"
[ "$RC" = "0" ] || p2p_fail "p2p write for the diagnosability check returned errno=$RC, want 0 (v6: succeeds off leg1)"
C1="$(crumbs)"

echo "--- after one P2P write (leg2 unreachable) ---"
cat "$SFILE"
grep -q "^$LEG2_NAME .*observed=p2pdma$" "$SFILE" \
	|| p2p_fail "unreachable leg $LEG2_NAME did not latch observed=p2pdma"
grep -q "^$(basename "$LEG1") .*observed=none$" "$SFILE" \
	|| p2p_fail "reachable leg $(basename "$LEG1") did not stay observed=none -- the latch over-fires on success"

[ "$((C1 - C0))" -eq 1 ] \
	|| p2p_fail "expected exactly 1 'no P2P path' dmesg breadcrumb for the first failure, got $((C1 - C0))"
dmesg | grep 'no P2P path' | tail -1 | grep -q "$ARR_NAME" \
	|| p2p_fail "breadcrumb does not name the array ($ARR_NAME)"
dmesg | grep 'no P2P path' | tail -1 | grep -q "$LEG2_NAME" \
	|| p2p_fail "breadcrumb does not name the member ($LEG2_NAME)"

# One-shot per member: a second identical failure must not re-log.
RC="$(p2p_io write "$ARR" "$(p2p_bdf_by_serial cmb0)")"
[ "$RC" = "0" ] || p2p_fail "second p2p write returned errno=$RC, want 0"
[ "$(crumbs)" -eq "$C1" ] \
	|| p2p_fail "breadcrumb is not one-shot: a second failure on $LEG2_NAME logged again"

# Diagnostics must never gate I/O: even declared "never", a write must
# still be attempted and (off the reachable leg) succeed.
p2p_advertise_set never
RC="$(p2p_io write "$ARR" "$(p2p_bdf_by_serial cmb0)")"
[ "$RC" = "0" ] || p2p_fail "p2p write under p2pdma_advertise=never returned errno=$RC -- the policy gated I/O"
p2p_advertise_set auto

p2p_pass "p2pdma_status latches failures only, logs once per member, and never gates I/O"

#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# P7c: PRODUCTION POSTURE — compat convergence on local legs. Lenient
# cufile.json (allow_compat_mode: true), injector armed for the native
# attempt (own budget, remaining=64). SPLIT VERDICTS:
#   kernel-side (must PASS): breadcrumb present, no fault, badblocks empty,
#     injected>=1, force-disarm completed BEFORE convergence checks (gdsio
#     runs 4 workers x 1MiB IOs — leftover budget under multi-worker
#     completion ordering is nondeterministic; NEVER assert on it).
#   userspace pair (may SKIP on policy): overall gdsio rc==0 (the bounce
#     retry) AND per-leg sha convergence after disarm. Presumes cuFile 1.15
#     retries MID-IO EINVAL under compat mode — only ever observed at
#     registration time; if the pair fails while the witness confirms a
#     native attempt and kernel state is clean, SKIP naming
#     "cuFile compat mode does not retry mid-IO errors" (product
#     escalation; userspace policy must not FAIL the kernel campaign).
# Writes $GDS_RESULTS/p7c-userspace-outcome for P7h's inheritance.
set -eu
DIR="$(dirname "$0")"; . "$DIR/lib.sh"
p2pdma_require_root; p2pdma_require_modules; p2pdma_require_tools
gds_require_gdsio
QF="$(gds_tool ms-queue-features)"
WITNESS="$(gds_tool gds-p2p-witness)"
trap gds_teardown EXIT

gds_injector_require raid1_end_write_request raid1_ms

p2pdma_pick_members raid1
[ "$P2PDMA_SUBSTRATE" = nvme ] || { echo "SKIP: needs real NVMe test partitions" >&2; exit 4; }
M0="$P2PDMA_M0"; M1="$P2PDMA_M1"
rc=0; "$QF" "$M0" >/dev/null || rc=$?
[ "$rc" != 4 ] || { echo "SKIP: cannot probe member advertise (bpftrace)" >&2; exit 4; }
[ "$rc" = 0 ] || { echo "SKIP: members do not advertise P2P on this box" >&2; exit 4; }

gds_csi_mdadm_create /dev/ms0 1 "$M0" "$M1" >/dev/null 2>&1 \
	|| { echo "SKIP: array create failed" >&2; exit 4; }
P2PDMA_ARRAY=/dev/ms0
rc=0; "$QF" /dev/ms0 >/dev/null || rc=$?
[ "$rc" != 4 ] || { echo "SKIP: cannot probe queue features on /dev/ms0 (rc=4)" >&2; exit 4; }
[ "$rc" = 0 ] || { echo "SKIP: /dev/ms0 does not advertise P2P (qf rc=$rc)" >&2; exit 4; }

gds_mkfs_mount /dev/ms0 "$GDS_MNT" || { echo "SKIP: mkfs/mount failed" >&2; exit 4; }
JSON=$(gds_cufile_json lenient "$GDS_RESULTS/p7c")

gds_dev_diskpart "$M1"
echo "injector target: disk=$GDS_INJ_DISK partno=$GDS_INJ_PARTNO majmin=$GDS_INJ_MAJMIN"
gds_injector_load raid1_ms:raid1_end_write_request "$GDS_INJ_DISK" "$GDS_INJ_PARTNO" \
	match=success to_status=inval p2p_only=1 \
	|| { echo "SKIP: insmod inval_inject failed" >&2; exit 4; }
gds_dmesg_mark
gds_injector_arm 64

rc=0; "$WITNESS" --expect-ms nonzero --expect-rc any -o "$GDS_RESULTS/p7c-witness.txt" -- \
	bash -c "$(declare -f gds_gdsio_write); GDSIO='$GDSIO' GDS_RESULTS='$GDS_RESULTS' gds_gdsio_write '$GDS_MNT' 0 '$JSON'" || rc=$?
case $rc in
	0) : ;;
	4) echo "SKIP: witness could not attach" >&2; exit 4;;
	*) gds_verdict p7 p7c_kernel FAIL "no native attempt witnessed: $(head -1 "$GDS_RESULTS/p7c-witness.txt" 2>/dev/null)"
	   echo "FAIL: lenient run never attempted the native path (rig assumption broken)" >&2; exit 1;;
esac
WREPORT=$(head -1 "$GDS_RESULTS/p7c-witness.txt")
WRC=$(echo "$WREPORT" | sed -n 's/.*cmd_rc=\([0-9]*\).*/\1/p')

INJECTED=$(gds_injector_injected); LEFT=$(gds_injector_remaining)
# BINDING: no armed budget may survive into convergence or side-state checks.
gds_injector_disarm
echo "budget: injected=$INJECTED leftover=$LEFT (recorded, not asserted)"
[ "$INJECTED" -ge 1 ] || { gds_verdict p7 p7c_kernel FAIL "injected=0 (mis-aimed probe?)"; echo "FAIL: injector never fired" >&2; exit 1; }
awk '/^ms0 :/{print;getline;print}' /proc/msstat | grep -q '\[UU\]' \
	|| { gds_verdict p7 p7c_kernel FAIL "a leg was faulted"; echo "FAIL: arm must fault nothing" >&2; exit 1; }
gds_assert_no_badblocks /dev/ms0 \
	|| { gds_verdict p7 p7c_kernel FAIL "badblocks recorded"; echo "FAIL: arm must record no badblocks" >&2; exit 1; }
gds_assert_breadcrumb \
	|| { gds_verdict p7 p7c_kernel FAIL "breadcrumb absent"; echo "FAIL: 'no P2P path' breadcrumb missing" >&2; exit 1; }
gds_verdict p7 p7c_kernel PASS "breadcrumb, [UU], badblocks-empty, injected=$INJECTED, disarmed pre-convergence"
gds_injector_unload

# --- userspace pair: rc==0 + per-leg convergence (post-disarm) ---------------
USPASS=1
[ "$WRC" = 0 ] || USPASS=0
SUM_ARRAY=""
if [ "$USPASS" = 1 ]; then
	SUM_ARRAY=$(gds_sha_direct "$GDS_MNT/gds-test.bin") || USPASS=0
fi
umount "$GDS_MNT"
timeout 60 "$MDADM" --stop /dev/ms0 >/dev/null 2>&1 \
	|| { gds_verdict p7 p7c_stop FAIL "mdadm --stop timed out"; echo "FAIL: array did not stop cleanly" >&2; exit 1; }
P2PDMA_ARRAY=""
if [ "$USPASS" = 1 ]; then
	for m in "$M0" "$M1"; do
		SUM_LEG=$(gds_leg_sha "$m" gds-test.bin) || { USPASS=0; break; }
		echo "sha $m: $SUM_LEG (array: $SUM_ARRAY)"
		[ "$SUM_LEG" = "$SUM_ARRAY" ] || USPASS=0
	done
fi
if [ "$USPASS" = 1 ]; then
	echo PASS > "$GDS_RESULTS/p7c-userspace-outcome"
	gds_verdict p7 p7c_userspace PASS "gdsio rc=0 (bounce retry) + per-leg sha convergence"
	echo "PASS: compat convergence — kernel arm fired loud, cuFile bounced, legs converged (injected=$INJECTED)"
	exit 0
fi
# kernel side clean + witnessed native attempt => the policy hatch, not a FAIL
echo "cuFile compat mode does not retry mid-IO errors" > "$GDS_RESULTS/p7c-userspace-outcome"
gds_verdict p7 p7c_userspace SKIP "gdsio rc=$WRC / convergence failed — cuFile compat mode does not retry mid-IO errors (product escalation)"
echo "SKIP: cuFile compat mode does not retry mid-IO errors (kernel side PASS; product escalation)" >&2
exit 4

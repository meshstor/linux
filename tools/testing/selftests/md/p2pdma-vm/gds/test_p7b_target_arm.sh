#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# P7b: ERA KEYING — P7a with to_status=target. Stage-1 normalizes both
# INVAL (>=6.17 dma-map) and TARGET (-EREMOTEIO on older kernels/fabrics),
# so every assertion is identical to P7a.
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
JSON=$(gds_cufile_json strict "$GDS_RESULTS/p7b")

gds_dev_diskpart "$M1"
echo "injector target: disk=$GDS_INJ_DISK partno=$GDS_INJ_PARTNO majmin=$GDS_INJ_MAJMIN"
gds_injector_load raid1_ms:raid1_end_write_request "$GDS_INJ_DISK" "$GDS_INJ_PARTNO" \
	match=success to_status=target p2p_only=1 \
	|| { echo "SKIP: insmod inval_inject failed" >&2; exit 4; }
gds_dmesg_mark
gds_injector_arm 1

rc=0; "$WITNESS" --expect-ms nonzero --expect-rc nonzero -o "$GDS_RESULTS/p7b-witness.txt" -- \
	bash -c "$(declare -f gds_gdsio_write); GDSIO='$GDSIO' GDS_RESULTS='$GDS_RESULTS' gds_gdsio_write '$GDS_MNT' 0 '$JSON'" || rc=$?
case $rc in
	0) : ;;
	4) echo "SKIP: witness could not attach" >&2; exit 4;;
	*) gds_verdict p7 p7b FAIL "want p2p_bios>0 AND gdsio rc!=0; got: $(head -1 "$GDS_RESULTS/p7b-witness.txt" 2>/dev/null)"
	   echo "FAIL: TARGET-keyed arm did not surface EINVAL to a witnessed native write" >&2; exit 1;;
esac

INJECTED=$(gds_injector_injected); REMAINING=$(gds_injector_remaining)
gds_injector_disarm
[ "$INJECTED" -ge 1 ] || { gds_verdict p7 p7b FAIL "injected=0 (mis-aimed probe?)"; echo "FAIL: injector never fired" >&2; exit 1; }
[ "$REMAINING" -le 0 ] || { gds_verdict p7 p7b FAIL "remaining=$REMAINING after a failed write"; echo "FAIL: strict remaining=1 budget not all spent (<=0: all spent or over — injector counter is racy under 4-worker completion)" >&2; exit 1; }
awk '/^ms0 :/{print;getline;print}' /proc/msstat | grep -q '\[UU\]' \
	|| { gds_verdict p7 p7b FAIL "a leg was faulted"; echo "FAIL: arm must fault nothing" >&2; exit 1; }
gds_assert_no_badblocks /dev/ms0 \
	|| { gds_verdict p7 p7b FAIL "badblocks recorded"; echo "FAIL: arm must record no badblocks" >&2; exit 1; }
gds_assert_breadcrumb \
	|| { gds_verdict p7 p7b FAIL "breadcrumb absent"; echo "FAIL: 'no P2P path' breadcrumb missing" >&2; exit 1; }
gds_injector_unload
umount "$GDS_MNT"
timeout 60 "$MDADM" --stop /dev/ms0 >/dev/null 2>&1 \
	|| { gds_verdict p7 p7b FAIL "mdadm --stop timed out (writes_pending imbalance?)"; echo "FAIL: array did not stop cleanly" >&2; exit 1; }
P2PDMA_ARRAY=""
gds_verdict p7 p7b PASS "TARGET keyed: EINVAL surfaced injected=$INJECTED [UU] badblocks-empty breadcrumb"
echo "PASS: stage-1 TARGET arm on raid1 (injected=$INJECTED, write failed loud, no fault, no badblocks, breadcrumb)"
exit 0

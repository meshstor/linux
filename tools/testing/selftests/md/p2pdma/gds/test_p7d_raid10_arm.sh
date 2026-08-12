#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# P7d: RAID10 PARITY — P7a on a CSI raid10 (4 partitions, chunk=64 layout=n2)
# with the raid10_ms-qualified probe. Same assertions as P7a at [UUUU].
# SKIP with the exact P3 rule when fewer than 4 labeled partitions exist.
set -eu
DIR="$(dirname "$0")"; . "$DIR/lib.sh"
p2pdma_require_root; p2pdma_require_modules; p2pdma_require_tools
gds_require_gdsio
QF="$(gds_tool ms-queue-features)"
WITNESS="$(gds_tool gds-p2p-witness)"
trap gds_teardown EXIT

PARTS=()
if [ -n "${GDS_PART_LIST:-}" ]; then read -r -a PARTS <<< "$GDS_PART_LIST"
else
	for d in /dev/disk/by-partlabel/*-meshstor-test-*; do
		[ -e "$d" ] && PARTS+=("$d")
	done
fi
[ "${#PARTS[@]}" -ge 4 ] || { echo "SKIP: fewer than 4 test partitions" >&2; exit 4; }
PARTS=("${PARTS[@]:0:4}")

gds_injector_require raid10_end_write_request raid10_ms

rc=0; "$QF" "${PARTS[0]}" >/dev/null || rc=$?
[ "$rc" != 4 ] || { echo "SKIP: cannot probe member advertise (bpftrace)" >&2; exit 4; }
[ "$rc" = 0 ] || { echo "SKIP: members do not advertise P2P on this box" >&2; exit 4; }
gds_csi_mdadm_create /dev/ms0 10 "${PARTS[@]}" >/dev/null 2>&1 \
	|| { echo "SKIP: raid10 array create failed" >&2; exit 4; }
P2PDMA_ARRAY=/dev/ms0
rc=0; "$QF" /dev/ms0 >/dev/null || rc=$?
[ "$rc" != 4 ] || { echo "SKIP: cannot probe queue features on /dev/ms0 (rc=4)" >&2; exit 4; }
[ "$rc" = 0 ] || { echo "SKIP: /dev/ms0 does not advertise P2P (qf rc=$rc)" >&2; exit 4; }

gds_mkfs_mount /dev/ms0 "$GDS_MNT" || { echo "SKIP: mkfs/mount failed" >&2; exit 4; }
JSON=$(gds_cufile_json strict "$GDS_RESULTS/p7d")

gds_dev_diskpart "${PARTS[3]}"
echo "injector target: disk=$GDS_INJ_DISK partno=$GDS_INJ_PARTNO majmin=$GDS_INJ_MAJMIN"
gds_injector_load raid10_ms:raid10_end_write_request "$GDS_INJ_DISK" "$GDS_INJ_PARTNO" \
	match=success to_status=inval p2p_only=1 \
	|| { echo "SKIP: insmod inval_inject failed" >&2; exit 4; }
gds_dmesg_mark
gds_injector_arm 1

rc=0; "$WITNESS" --expect-ms nonzero --expect-rc nonzero -o "$GDS_RESULTS/p7d-witness.txt" -- \
	bash -c "$(declare -f gds_gdsio_write); GDSIO='$GDSIO' GDS_RESULTS='$GDS_RESULTS' gds_gdsio_write '$GDS_MNT' 0 '$JSON'" || rc=$?
case $rc in
	0) : ;;
	4) echo "SKIP: witness could not attach" >&2; exit 4;;
	*) gds_verdict p7 p7d FAIL "want p2p_bios>0 AND gdsio rc!=0; got: $(head -1 "$GDS_RESULTS/p7d-witness.txt" 2>/dev/null)"
	   echo "FAIL: raid10 stage-1 arm did not surface EINVAL to a witnessed native write" >&2; exit 1;;
esac

INJECTED=$(gds_injector_injected); REMAINING=$(gds_injector_remaining)
gds_injector_disarm
[ "$INJECTED" -ge 1 ] || { gds_verdict p7 p7d FAIL "injected=0 (mis-aimed probe?)"; echo "FAIL: injector never fired" >&2; exit 1; }
[ "$REMAINING" -eq 0 ] || { gds_verdict p7 p7d FAIL "remaining=$REMAINING after a failed write"; echo "FAIL: strict remaining=1 budget not consumed" >&2; exit 1; }
awk '/^ms0 :/{print;getline;print}' /proc/msstat | grep -q '\[UUUU\]' \
	|| { gds_verdict p7 p7d FAIL "a leg was faulted"; echo "FAIL: arm must fault nothing" >&2; exit 1; }
gds_assert_no_badblocks /dev/ms0 \
	|| { gds_verdict p7 p7d FAIL "badblocks recorded"; echo "FAIL: arm must record no badblocks" >&2; exit 1; }
gds_assert_breadcrumb \
	|| { gds_verdict p7 p7d FAIL "breadcrumb absent"; echo "FAIL: 'no P2P path' breadcrumb missing" >&2; exit 1; }
gds_injector_unload
umount "$GDS_MNT"
timeout 60 "$MDADM" --stop /dev/ms0 >/dev/null 2>&1 \
	|| { gds_verdict p7 p7d FAIL "mdadm --stop timed out (writes_pending imbalance?)"; echo "FAIL: array did not stop cleanly" >&2; exit 1; }
P2PDMA_ARRAY=""
gds_verdict p7 p7d PASS "raid10: EINVAL surfaced injected=$INJECTED [UUUU] badblocks-empty breadcrumb"
echo "PASS: stage-1 INVAL arm on raid10 (injected=$INJECTED, write failed loud, no fault, no badblocks, breadcrumb)"
exit 0

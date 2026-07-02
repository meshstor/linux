#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# P2 HEADLINE: GDS-native on an ms raid1 (both legs local NVMe, exact CSI
# shape), kernel-witnessed (P2P pages through ms_submit_bio + member map hits),
# with cross-leg integrity through the filesystem on each leg.
set -eu
DIR="$(dirname "$0")"; . "$DIR/lib.sh"
p2pdma_require_root; p2pdma_require_modules; p2pdma_require_tools
gds_require_gdsio
QF="$(gds_tool ms-queue-features)"
WITNESS="$(gds_tool gds-p2p-witness)"
trap gds_teardown EXIT

p2pdma_pick_members raid1
[ "$P2PDMA_SUBSTRATE" = nvme ] || { echo "SKIP: needs real NVMe test partitions" >&2; exit 4; }
M0="$P2PDMA_M0"; M1="$P2PDMA_M1"
"$QF" "$M0" || { echo "SKIP: members do not advertise P2P on this box" >&2; exit 4; }

gds_csi_mdadm_create /dev/ms0 1 "$M0" "$M1" >/dev/null 2>&1 \
	|| { echo "SKIP: array create failed" >&2; exit 4; }
P2PDMA_ARRAY=/dev/ms0

rc=0; "$QF" /dev/ms0 >/dev/null || rc=$?
case $rc in
	0) : ;;
	1) gds_verdict p2 advertise FAIL "all-NVMe array not advertising"; exit 1;;
	*) echo "SKIP: cannot probe /dev/ms0 (rc=$rc)" >&2; exit 4;;
esac
gds_verdict p2 advertise PASS "array advertises with all-P2P members"

gds_mkfs_mount /dev/ms0 "$GDS_MNT" || { echo "SKIP: mkfs/mount failed" >&2; exit 4; }
JSON_S=$(gds_cufile_json strict "$GDS_RESULTS/p2")

rc=0; "$WITNESS" --expect-ms nonzero --expect-map nonzero -o "$GDS_RESULTS/p2-witness.txt" -- \
	bash -c "$(declare -f gds_gdsio_write); GDSIO='$GDSIO' GDS_RESULTS='$GDS_RESULTS' gds_gdsio_write '$GDS_MNT' 0 '$JSON_S'" || rc=$?
case $rc in
	0) gds_verdict p2 native PASS "$(tail -1 "$GDS_RESULTS/p2-witness.txt" 2>/dev/null || true)";;
	4) gds_verdict p2 native SKIP "witness could not attach"; echo "SKIP: witness attach failed" >&2; exit 4;;
	*) gds_verdict p2 native FAIL "P2P pages did not traverse ms_submit_bio (see p2-witness.txt, cufile.log)"; echo "FAIL: GDS write on /dev/ms0 was not kernel-native" >&2; exit 1;;
esac

gds_gdsio_readverify "$GDS_MNT" "$JSON_S" \
	|| { gds_verdict p2 verify FAIL "gdsio read-verify failed"; exit 1; }
SUM_ARRAY=$(gds_sha_direct "$GDS_MNT/gds-test.bin")

umount "$GDS_MNT"
"$MDADM" --stop /dev/ms0 >/dev/null 2>&1; P2PDMA_ARRAY=""

for m in "$M0" "$M1"; do
	SUM_LEG=$(gds_leg_sha "$m" gds-test.bin) \
		|| { gds_verdict p2 legs FAIL "cannot read leg $m"; exit 1; }
	[ "$SUM_LEG" = "$SUM_ARRAY" ] \
		|| { gds_verdict p2 legs FAIL "leg $m sha mismatch (divergence!)"; exit 1; }
done
gds_verdict p2 legs PASS "both legs hold identical, correct file content"
echo "PASS: GDS-native on ms raid1 with cross-leg integrity (kernel-witnessed)"
exit 0

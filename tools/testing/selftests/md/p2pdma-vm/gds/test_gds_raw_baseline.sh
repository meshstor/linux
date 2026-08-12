#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# P1 gate: can this box do native GDS at all, on a RAW local NVMe partition?
# Two runs calibrate the kernel witness before it judges md:
#   control: gdsio -x 1 (POSIX/CPU)  -> map_hits MUST be 0
#   native:  gdsio -x 0, strict json -> map_hits MUST be > 0
# If this fails, nothing md-related is testable (campaign pivots to diagnosis).
set -eu
DIR="$(dirname "$0")"; . "$DIR/lib.sh"
p2pdma_require_root; p2pdma_require_tools
gds_require_gdsio
WITNESS="$(gds_tool gds-p2p-witness)"
trap gds_teardown EXIT

p2pdma_pick_members raid1
[ "$P2PDMA_SUBSTRATE" = nvme ] || { echo "SKIP: needs a real NVMe test partition" >&2; exit 4; }
gds_mkfs_mount "$P2PDMA_M0" "$GDS_MNT" || { echo "SKIP: mkfs/mount failed" >&2; exit 4; }

JSON_L=$(gds_cufile_json lenient "$GDS_RESULTS/p1-control")
"$WITNESS" --expect-map zero -o "$GDS_RESULTS/p1-witness-control.txt" -- \
	bash -c "$(declare -f gds_gdsio_write); GDSIO='$GDSIO' GDS_RESULTS='$GDS_RESULTS' gds_gdsio_write '$GDS_MNT' 1 '$JSON_L'" \
	|| { gds_verdict p1 control FAIL "CPU control run had nonzero map_hits or failed"; exit 1; }

JSON_S=$(gds_cufile_json strict "$GDS_RESULTS/p1-native")
if ! "$WITNESS" --expect-map nonzero -o "$GDS_RESULTS/p1-witness-native.txt" -- \
	bash -c "$(declare -f gds_gdsio_write); GDSIO='$GDSIO' GDS_RESULTS='$GDS_RESULTS' gds_gdsio_write '$GDS_MNT' 0 '$JSON_S'"; then
	gds_verdict p1 native FAIL "no kernel-side P2P map activity (or gdsio failed) -- see p1-witness-native.txt + cufile.log"
	echo "FAIL: native GDS did not take the P2PDMA path on a raw partition" >&2
	exit 1
fi
gds_gdsio_readverify "$GDS_MNT" "$JSON_S" \
	|| { gds_verdict p1 verify FAIL "gdsio read-verify failed"; exit 1; }

gds_verdict p1 native PASS "control map=0, native map>0, read-verify ok"
echo "PASS: native GDS works on raw NVMe; witness calibrated"
exit 0

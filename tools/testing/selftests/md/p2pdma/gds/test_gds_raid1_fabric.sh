#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# P3: the CSI production topology on one node -- local NVMe leg + loopback
# NVMe-oF leg (GDS_TRANSPORT=tcp|rdma). Records the empirical answer to
# "does nvme-rdma advertise P2P on this rig" (Finding E, rdma side), asserts
# advertise CONSISTENCY (array == AND of members), and when the array
# advertises runs the full witnessed GDS battery + leg integrity.
# GDS_RAID10=1: raid10 n2 chunk=64 over 4 members (needs GDS_PART_LIST with 4).
set -eu
DIR="$(dirname "$0")"; . "$DIR/lib.sh"
p2pdma_require_root; p2pdma_require_modules; p2pdma_require_tools
command -v nvme >/dev/null || { echo "SKIP: nvme-cli missing" >&2; exit 4; }
QF="$(gds_tool ms-queue-features)"
WITNESS="$(gds_tool gds-p2p-witness)"
TR="${GDS_TRANSPORT:-tcp}"
trap gds_teardown EXIT

# qf_probe DEV -> echoes ms-queue-features' raw exit code (0 advertised,
# 1 not advertised, 4 cannot probe). Kept distinct from a plain boolean so a
# probe FLAKE (rc=4) can never be folded into "not advertised" by callers --
# that would silently corrupt the member-AND comparison below (a rc=4 read
# as 0 makes an array that doesn't advertise look "consistent" even when the
# flake hid a real advertise). Callers must check for 4 and SKIP before
# using the value in an assertion.
qf_probe() {
	local rc=0
	"$QF" "$1" >/dev/null 2>&1 || rc=$?
	echo "$rc"
}

# members: GDS_PART_LIST override, else the labeled pair
PARTS=()
if [ -n "${GDS_PART_LIST:-}" ]; then read -r -a PARTS <<< "$GDS_PART_LIST"
else
	p2pdma_pick_members raid1
	[ "$P2PDMA_SUBSTRATE" = nvme ] || { echo "SKIP: needs real NVMe test partitions" >&2; exit 4; }
	PARTS=("$P2PDMA_M0" "$P2PDMA_M1")
fi

if [ "${GDS_RAID10:-0}" = 1 ]; then
	[ "${#PARTS[@]}" -ge 4 ] || { echo "SKIP: raid10 needs 4 members in GDS_PART_LIST" >&2; exit 4; }
	LOCALS=("${PARTS[0]}" "${PARTS[1]}"); EXPORTS=("${PARTS[2]}" "${PARTS[3]}"); LEVEL=10
else
	LOCALS=("${PARTS[0]}"); EXPORTS=("${PARTS[1]}"); LEVEL=1
fi

gds_nvmet_export "$TR" "${EXPORTS[@]}"

LOCAL_RC=$(qf_probe "${LOCALS[0]}")
[ "$LOCAL_RC" != 4 ] \
	|| { echo "SKIP: cannot probe queue features on local member ${LOCALS[0]} (rc=4)" >&2; exit 4; }
LOCAL_ADV=$(( LOCAL_RC == 0 ))

REMOTE_ADV=1
for r in "${GDS_REMOTE_DEVS[@]}"; do
	RC=$(qf_probe "$r")
	[ "$RC" != 4 ] || { echo "SKIP: cannot probe queue features on remote $r (rc=4)" >&2; exit 4; }
	[ "$RC" = 0 ] || REMOTE_ADV=0
done
gds_verdict p3 "remote_ns_advertise_$TR" INFO "local=$LOCAL_ADV remote=$REMOTE_ADV (Finding E, $TR)"

# CSI member order: local first in each mirror pair
MEMBERS=()
for i in "${!LOCALS[@]}"; do MEMBERS+=("${LOCALS[$i]}" "${GDS_REMOTE_DEVS[$i]}"); done
gds_csi_mdadm_create /dev/ms0 "$LEVEL" "${MEMBERS[@]}" >/dev/null 2>&1 \
	|| { echo "SKIP: $LEVEL fabric array create failed" >&2; exit 4; }
P2PDMA_ARRAY=/dev/ms0

ARRAY_RC=$(qf_probe /dev/ms0)
[ "$ARRAY_RC" != 4 ] \
	|| { echo "SKIP: cannot probe queue features on /dev/ms0 (rc=4)" >&2; exit 4; }
ARRAY_ADV=$(( ARRAY_RC == 0 ))
WANT=$(( LOCAL_ADV && REMOTE_ADV ))
if [ "$ARRAY_ADV" -ne "$WANT" ]; then
	gds_verdict p3 advertise_consistency FAIL "array=$ARRAY_ADV want=$WANT (local=$LOCAL_ADV remote=$REMOTE_ADV)"
	echo "FAIL: array advertise state inconsistent with member AND" >&2
	exit 1
fi
gds_verdict p3 advertise_consistency PASS "array=$ARRAY_ADV == AND(members)"

[ -x "$GDSIO" ] || { echo "PASS (advertise-only: no gdsio)"; exit 0; }
gds_mkfs_mount /dev/ms0 "$GDS_MNT" || { echo "SKIP: mkfs/mount failed" >&2; exit 4; }

if [ "$ARRAY_ADV" = 1 ]; then
	JSON=$(gds_cufile_json strict "$GDS_RESULTS/p3")
	rc=0; "$WITNESS" --expect-ms nonzero --expect-map nonzero -o "$GDS_RESULTS/p3-witness.txt" -- \
		bash -c "$(declare -f gds_gdsio_write); GDSIO='$GDSIO' GDS_RESULTS='$GDS_RESULTS' gds_gdsio_write '$GDS_MNT' 0 '$JSON'" || rc=$?
	case $rc in
		0) gds_verdict p3 native PASS "$(tail -1 "$GDS_RESULTS/p3-witness.txt" 2>/dev/null || true)";;
		4) gds_verdict p3 native SKIP "witness could not attach"; echo "SKIP: witness attach failed" >&2; exit 4;;
		*) gds_verdict p3 native FAIL "fabric array advertised but GDS was not kernel-native"; exit 1;;
	esac
else
	JSON=$(gds_cufile_json lenient "$GDS_RESULTS/p3")
	"$WITNESS" --expect-ms zero -o "$GDS_RESULTS/p3-witness.txt" -- \
		bash -c "$(declare -f gds_gdsio_write); GDSIO='$GDSIO' GDS_RESULTS='$GDS_RESULTS' gds_gdsio_write '$GDS_MNT' 0 '$JSON'" \
		|| { gds_verdict p3 fallback FAIL "compat fallback failed or leaked P2P bios"; exit 1; }
	gds_verdict p3 fallback PASS "non-advertising fabric array served GDS via compat cleanly"
fi
gds_gdsio_readverify "$GDS_MNT" "$JSON" \
	|| { gds_verdict p3 verify FAIL "gdsio read-verify failed"; exit 1; }
SUM_ARRAY=$(gds_sha_direct "$GDS_MNT/gds-test.bin")
umount "$GDS_MNT"
"$MDADM" --stop /dev/ms0 >/dev/null 2>&1; P2PDMA_ARRAY=""

# raid1 only: per-leg fs integrity (raid10 stripes -- legs are not full copies)
if [ "$LEVEL" = 1 ]; then
	for m in "${LOCALS[0]}" "${EXPORTS[0]}"; do   # remote leg readable locally: loopback
		SUM_LEG=$(gds_leg_sha "$m" gds-test.bin) \
			|| { gds_verdict p3 legs FAIL "cannot read leg $m"; exit 1; }
		[ "$SUM_LEG" = "$SUM_ARRAY" ] \
			|| { gds_verdict p3 legs FAIL "leg $m sha mismatch (divergence!)"; exit 1; }
	done
	gds_verdict p3 legs PASS "both legs consistent through the fs"
fi
echo "PASS: fabric topology ($TR, raid$LEVEL) behaved consistently"
exit 0

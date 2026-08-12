#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# P7g: NATIVE RDMA BOTH-LEGS (gated). CSI raid1 of [local NVMe partition,
# nvme-of RDMA-connected namespace]. Strict config, witnessed write that
# must SUCCEED NATIVELY — compat fallback or a non-advertising array is a
# FAIL-shaped gate here only after all SKIP gates pass (unlike P3, which
# stays data-driven). Both legs must carry the data (remote leg read via
# its nvmet backing device). Gates (each SKIP names the exact unmet
# condition — the campaign's INCOMPLETE escalation whitelists them):
#   - GDS_TRANSPORT=rdma on a hardware HCA (rxe/siw excluded)
#   - nvme_core.multipath=N boot (head split hides the feature otherwise)
#   - rdma leg advertises + mixed array advertises (P4c positive branch)
#   - cuFile registers the mixed array (else: policy hatch, SKIP + escalation)
set -eu
DIR="$(dirname "$0")"; . "$DIR/lib.sh"
p2pdma_require_root; p2pdma_require_modules; p2pdma_require_tools
command -v nvme >/dev/null || { echo "SKIP: nvme-cli missing" >&2; exit 4; }
gds_require_gdsio
QF="$(gds_tool ms-queue-features)"
WITNESS="$(gds_tool gds-p2p-witness)"
trap gds_teardown EXIT

[ "${GDS_TRANSPORT:-}" = rdma ] \
	|| { echo "SKIP: no hardware RDMA transport (GDS_TRANSPORT=${GDS_TRANSPORT:-unset})" >&2; exit 4; }
MP=$(cat /sys/module/nvme_core/parameters/multipath 2>/dev/null || echo Y)
[ "$MP" = N ] \
	|| { echo "SKIP: fabrics member would be a multipath head (nvme_core.multipath=$MP) — boot nvme_core.multipath=N and rerun" >&2; exit 4; }

p2pdma_pick_members raid1
[ "$P2PDMA_SUBSTRATE" = nvme ] || { echo "SKIP: needs real NVMe test partitions" >&2; exit 4; }
M0="$P2PDMA_M0"; M1="$P2PDMA_M1"
rc=0; "$QF" "$M0" >/dev/null || rc=$?
[ "$rc" != 4 ] || { echo "SKIP: cannot probe member advertise (bpftrace)" >&2; exit 4; }
[ "$rc" = 0 ] || { echo "SKIP: local member does not advertise P2P" >&2; exit 4; }

gds_nvmet_export rdma "$M1"
case "${GDS_RDMA_IBDEV:-}" in rxe*|siw*)
	echo "SKIP: $GDS_RDMA_IBDEV is virt-DMA — no hardware RDMA transport" >&2; exit 4;;
esac
REMOTE="${GDS_REMOTE_DEVS[0]}"
rc=0; "$QF" "$REMOTE" >/dev/null || rc=$?
[ "$rc" != 4 ] || { echo "SKIP: cannot probe queue features on $REMOTE (rc=4)" >&2; exit 4; }
[ "$rc" = 0 ] || { echo "SKIP: rdma leg does not advertise (override/hw gate unmet — see P4c ladder)" >&2; exit 4; }

gds_csi_mdadm_create /dev/ms0 1 "$M0" "$REMOTE" >/dev/null 2>&1 \
	|| { echo "SKIP: mixed array create failed" >&2; exit 4; }
P2PDMA_ARRAY=/dev/ms0
rc=0; "$QF" /dev/ms0 >/dev/null || rc=$?
[ "$rc" != 4 ] || { echo "SKIP: cannot probe queue features on /dev/ms0 (rc=4)" >&2; exit 4; }
[ "$rc" = 0 ] || { echo "SKIP: mixed [local,rdma] array does not advertise (member-AND gate unmet)" >&2; exit 4; }

gds_mkfs_mount /dev/ms0 "$GDS_MNT" || { echo "SKIP: mkfs/mount failed" >&2; exit 4; }
JSON=$(gds_cufile_json strict "$GDS_RESULTS/p7g")
gds_dmesg_mark

rc=0; "$WITNESS" --expect-ms nonzero --expect-map nonzero --expect-rc zero \
	-o "$GDS_RESULTS/p7g-witness.txt" -- \
	bash -c "$(declare -f gds_gdsio_write); GDSIO='$GDSIO' GDS_RESULTS='$GDS_RESULTS' gds_gdsio_write '$GDS_MNT' 0 '$JSON'" || rc=$?
WREPORT=$(head -1 "$GDS_RESULTS/p7g-witness.txt" 2>/dev/null || echo "")
P2P=$(echo "$WREPORT" | sed -n 's/^p2p_bios=\([0-9]*\).*/\1/p'); P2P=${P2P:-0}
case $rc in
	0) : ;;
	4) echo "SKIP: witness could not attach" >&2; exit 4;;
	*)	# cuFile-policy escape hatch: userspace refusal = witness-zero + clean dmesg
		if [ "$P2P" -eq 0 ] && gds_assert_no_breadcrumb 2>/dev/null \
		   && ! gds_dmesg_delta | grep -Eq 'I/O error|Buffer I/O error'; then
			gds_verdict p7 p7g SKIP "cuFile member-transport policy (rdma) — product escalation, P5-manual precedent"
			echo "SKIP: cuFile member-transport policy (rdma) — registration refused in userspace; bank as product escalation" >&2
			exit 4
		fi
		gds_verdict p7 p7g FAIL "native write on mixed [local,rdma] failed: $WREPORT"
		echo "FAIL: native GPU write over local+RDMA legs did not succeed natively" >&2; exit 1;;
esac

gds_gdsio_readverify "$GDS_MNT" "$JSON" \
	|| { gds_verdict p7 p7g FAIL "gdsio -I 0 -V read-verify failed"; echo "FAIL: read-verify" >&2; exit 1; }
SUM_ARRAY=$(gds_sha_direct "$GDS_MNT/gds-test.bin")
umount "$GDS_MNT"
timeout 60 "$MDADM" --stop /dev/ms0 >/dev/null 2>&1 \
	|| { gds_verdict p7 p7g FAIL "mdadm --stop timed out"; echo "FAIL: array did not stop cleanly" >&2; exit 1; }
P2PDMA_ARRAY=""
# both legs carry the data: local directly; remote via its nvmet BACKING dev
for m in "$M0" "$M1"; do
	SUM_LEG=$(gds_leg_sha "$m" gds-test.bin) \
		|| { gds_verdict p7 p7g FAIL "cannot read leg $m"; echo "FAIL: leg unreadable" >&2; exit 1; }
	echo "sha $m: $SUM_LEG (array: $SUM_ARRAY)"
	[ "$SUM_LEG" = "$SUM_ARRAY" ] \
		|| { gds_verdict p7 p7g FAIL "leg $m sha mismatch (divergence!)"; echo "FAIL: leg divergence" >&2; exit 1; }
done
gds_verdict p7 p7g PASS "native both-legs: $WREPORT; legs identical"
echo "PASS: native GPU write over [local, rdma] legs — witnessed native, read-verified, both legs identical"
exit 0

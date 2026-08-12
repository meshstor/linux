#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# P7e (rig only): A/B CONTRAST on gds1 (pre-fix module). The orchestrator
# owns the swap to gds1 before this test and the P5-grade restore to gdsM
# after it (matching how P5 owns its baseline swap). This file repeats
# P7a's exact rig; FOUR explicit discriminators, ALL required (a mis-aimed
# injector must not produce a vacuous rc=0 pass):
#   1. injected >= 1   (disk=/partno= RE-DERIVED after the swap — names move)
#   2. witness P2P bios nonzero
#   3. gdsio rc == 0   (the old silent swallow)
#   4. NO breadcrumb   (the arm does not exist on gds1)
# Plus a variant guard: loaded raid1_ms srcversion == the gds1 manifest row
# (GDS_KIT_MANIFEST env). Evidence is STATUS-LEVEL only: with match=success
# the data reached media on both legs before the rewrite — unlike P6's
# dm-flakey rig there is no stale leg to assert.
set -eu
DIR="$(dirname "$0")"; . "$DIR/lib.sh"
p2pdma_require_root; p2pdma_require_modules; p2pdma_require_tools
gds_require_gdsio
QF="$(gds_tool ms-queue-features)"
WITNESS="$(gds_tool gds-p2p-witness)"
trap gds_teardown EXIT

# variant guard: this rig is only meaningful on gds1
if [ -n "${GDS_KIT_MANIFEST:-}" ] && [ -e "$GDS_KIT_MANIFEST" ]; then
	WANT=$(awk -F'\t' '$1=="gds1"{print $4}' "$GDS_KIT_MANIFEST" | tr ' ' '\n' | sed -n 's/^raid1_ms=//p')
	modprobe raid1_ms 2>/dev/null || true
	HAVE=$(cat /sys/module/raid1_ms/srcversion 2>/dev/null || echo none)
	[ -n "$WANT" ] || { echo "FAIL: gds1 row missing from $GDS_KIT_MANIFEST" >&2; exit 1; }
	[ "$HAVE" = "$WANT" ] \
		|| { echo "FAIL: loaded raid1_ms srcversion $HAVE != gds1 manifest $WANT (swap did not take?)" >&2; exit 1; }
	echo "variant guard: raid1_ms srcversion $HAVE == gds1 manifest"
else
	echo "WARN: GDS_KIT_MANIFEST unset — variant unverified (repo-mode rehearsal only)" >&2
fi

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
JSON=$(gds_cufile_json strict "$GDS_RESULTS/p7e")

gds_dev_diskpart "$M1"    # re-derived post-swap by construction (fresh run)
echo "injector target: disk=$GDS_INJ_DISK partno=$GDS_INJ_PARTNO majmin=$GDS_INJ_MAJMIN"
gds_injector_load raid1_ms:raid1_end_write_request "$GDS_INJ_DISK" "$GDS_INJ_PARTNO" \
	match=success to_status=inval p2p_only=1 \
	|| { echo "SKIP: insmod inval_inject failed" >&2; exit 4; }
gds_dmesg_mark
gds_injector_arm 1

rc=0; "$WITNESS" --expect-ms nonzero --expect-rc zero -o "$GDS_RESULTS/p7e-witness.txt" -- \
	bash -c "$(declare -f gds_gdsio_write); GDSIO='$GDSIO' GDS_RESULTS='$GDS_RESULTS' gds_gdsio_write '$GDS_MNT' 0 '$JSON'" || rc=$?
case $rc in
	0) : ;;
	4) echo "SKIP: witness could not attach" >&2; exit 4;;
	*) gds_verdict p7 p7e FAIL "want p2p_bios>0 AND gdsio rc==0 on gds1; got: $(head -1 "$GDS_RESULTS/p7e-witness.txt" 2>/dev/null)"
	   echo "FAIL: gds1 did not silently swallow the injected INVAL (contrast broken)" >&2; exit 1;;
esac

INJECTED=$(gds_injector_injected); REMAINING=$(gds_injector_remaining)
gds_injector_disarm
[ "$INJECTED" -ge 1 ] || { gds_verdict p7 p7e FAIL "injected=0 (mis-aimed injector — vacuous rc=0)"; echo "FAIL: injector never fired" >&2; exit 1; }
[ "$REMAINING" -le 0 ] || { gds_verdict p7 p7e FAIL "remaining=$REMAINING"; echo "FAIL: strict remaining=1 budget not all spent (<=0: all spent or over — injector counter is racy under 4-worker completion)" >&2; exit 1; }
gds_assert_no_breadcrumb \
	|| { gds_verdict p7 p7e FAIL "breadcrumb PRESENT on gds1"; echo "FAIL: gds1 has no arm — a breadcrumb means the wrong module is loaded" >&2; exit 1; }
gds_injector_unload
umount "$GDS_MNT"
timeout 60 "$MDADM" --stop /dev/ms0 >/dev/null 2>&1 \
	|| { gds_verdict p7 p7e FAIL "mdadm --stop timed out"; echo "FAIL: array did not stop cleanly" >&2; exit 1; }
P2PDMA_ARRAY=""
gds_verdict p7 p7e PASS "gds1 contrast: injected=$INJECTED p2p-witnessed rc=0 no-breadcrumb"
echo "PASS: gds1 A/B contrast — old silent swallow reproduced (injected=$INJECTED, rc=0, no breadcrumb)"
exit 0

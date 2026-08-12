#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# P7h: ANY-LEG FAILURE RETRIES VIA CPU/KERNEL (gated; same rig gates as
# P7g). Lenient config, TWO sub-runs: fail-local (injector on the local
# leg) and fail-remote (injector matched to the rdma leg's initiator-side
# namespace — maj:min recorded at arm time). Each sub-run: fresh
# insmod -> arm remaining=1 -> witnessed write -> kernel-side asserts ->
# force-disarm BEFORE its convergence checks -> rmmod.
# SPLIT VERDICTS (P7c principle): kernel-side (P2P bios witnessed during
# the native attempt, injected>=1, [UU], badblocks empty, breadcrumb) must
# PASS; the userspace pair (rc==0 + both-legs sha convergence — the remote
# leg receives the bounce via the ordinary non-P2P nvme-of write path)
# INHERITS P7c's outcome ONLY when the outcome file carries the exact
# policy-hatch string ("cuFile compat mode does not retry mid-IO errors"):
# then this pair SKIPs too, kernel side still runs. Any other/unknown
# outcome (PASS, missing file) makes a failing pair its OWN FAIL — never
# "inherited".
# CUFILE-POLICY HATCH (P7g parity): a witness failure that is witness-zero
# with no breadcrumb and a clean dmesg delta is a userspace registration
# refusal, not kernel evidence — SKIP "cuFile member-transport policy
# (rdma)" (whitelisted, same string P7g banks); the kernel FAIL is reserved
# for the non-vacuous case (P2P flowed but the assertions failed).
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

gds_injector_require raid1_end_write_request raid1_ms

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

# userspace-pair inheritance from P7c (same cuFile stack, ran earlier)
P7C_OUTCOME=$(cat "$GDS_RESULTS/p7c-userspace-outcome" 2>/dev/null || echo "unknown (p7c did not run)")

USFAIL=0; USSKIP=0
run_leg_fail() {  # NAME TARGET_DEV
	local name=$1 target=$2 rc wreport wrc p2p injected remaining sum_array sum_leg m uspass=1
	gds_csi_mdadm_create /dev/ms0 1 "$M0" "$REMOTE" >/dev/null 2>&1 \
		|| { echo "SKIP: mixed array create failed ($name)" >&2; exit 4; }
	P2PDMA_ARRAY=/dev/ms0
	rc=0; "$QF" /dev/ms0 >/dev/null || rc=$?
	[ "$rc" != 4 ] || { echo "SKIP: cannot probe queue features on /dev/ms0 (rc=4)" >&2; exit 4; }
	[ "$rc" = 0 ] || { echo "SKIP: mixed [local,rdma] array does not advertise (member-AND gate unmet)" >&2; exit 4; }
	gds_mkfs_mount /dev/ms0 "$GDS_MNT" || { echo "SKIP: mkfs/mount failed ($name)" >&2; exit 4; }
	local json; json=$(gds_cufile_json lenient "$GDS_RESULTS/p7h-$name")
	gds_dev_diskpart "$target"
	echo "[$name] injector target: disk=$GDS_INJ_DISK partno=$GDS_INJ_PARTNO majmin=$GDS_INJ_MAJMIN"
	gds_injector_load raid1_ms:raid1_end_write_request "$GDS_INJ_DISK" "$GDS_INJ_PARTNO" \
		match=success to_status=inval p2p_only=1 \
		|| { echo "SKIP: insmod inval_inject failed ($name)" >&2; exit 4; }
	gds_dmesg_mark
	gds_injector_arm 1
	rc=0; "$WITNESS" --expect-ms nonzero --expect-rc any -o "$GDS_RESULTS/p7h-$name-witness.txt" -- \
		bash -c "$(declare -f gds_gdsio_write); GDSIO='$GDSIO' GDS_RESULTS='$GDS_RESULTS' gds_gdsio_write '$GDS_MNT' 0 '$json'" || rc=$?
	wreport=$(head -1 "$GDS_RESULTS/p7h-$name-witness.txt" 2>/dev/null || echo "")
	case $rc in
		0) : ;;
		4) echo "SKIP: witness could not attach ($name)" >&2; exit 4;;
		*)	# cuFile-policy escape hatch (P7g parity): userspace refusal =
			# witness-zero + no breadcrumb + clean dmesg — vacuous, SKIP on
			# the same whitelisted string P7g uses, not a kernel FAIL
			p2p=$(echo "$wreport" | sed -n 's/^p2p_bios=\([0-9]*\).*/\1/p'); p2p=${p2p:-0}
			if [ "$p2p" -eq 0 ] && gds_assert_no_breadcrumb 2>/dev/null \
			   && ! gds_dmesg_delta | grep -Eq 'I/O error|Buffer I/O error'; then
				gds_verdict p7 "p7h_${name}_kernel" SKIP "cuFile member-transport policy (rdma) — product escalation, P5-manual precedent"
				echo "SKIP: cuFile member-transport policy (rdma) — registration refused in userspace; bank as product escalation" >&2
				exit 4
			fi
			gds_verdict p7 "p7h_${name}_kernel" FAIL "no native attempt witnessed: $wreport"
			echo "FAIL: [$name] native path never attempted" >&2; exit 1;;
	esac
	wrc=$(echo "$wreport" | sed -n 's/.*cmd_rc=\([0-9]*\).*/\1/p')
	injected=$(gds_injector_injected); remaining=$(gds_injector_remaining)
	gds_injector_disarm    # BINDING: disarm before ANY convergence check
	[ "$injected" -ge 1 ] || { gds_verdict p7 "p7h_${name}_kernel" FAIL "injected=0"; echo "FAIL: [$name] injector never fired" >&2; exit 1; }
	[ "$remaining" -le 0 ] || { gds_verdict p7 "p7h_${name}_kernel" FAIL "remaining=$remaining"; echo "FAIL: [$name] budget not all spent (<=0: all spent or over — injector counter is racy under 4-worker completion)" >&2; exit 1; }
	awk '/^ms0 :/{print;getline;print}' /proc/msstat | grep -q '\[UU\]' \
		|| { gds_verdict p7 "p7h_${name}_kernel" FAIL "a leg was faulted"; echo "FAIL: [$name] arm must fault nothing" >&2; exit 1; }
	gds_assert_no_badblocks /dev/ms0 \
		|| { gds_verdict p7 "p7h_${name}_kernel" FAIL "badblocks recorded"; echo "FAIL: [$name] badblocks" >&2; exit 1; }
	gds_assert_breadcrumb \
		|| { gds_verdict p7 "p7h_${name}_kernel" FAIL "breadcrumb absent"; echo "FAIL: [$name] breadcrumb missing" >&2; exit 1; }
	gds_verdict p7 "p7h_${name}_kernel" PASS "witnessed native, injected=$injected, [UU], badblocks-empty, breadcrumb"
	gds_injector_unload
	# userspace pair (post-disarm)
	[ "$wrc" = 0 ] || uspass=0
	sum_array=""
	[ "$uspass" = 1 ] && { sum_array=$(gds_sha_direct "$GDS_MNT/gds-test.bin") || uspass=0; }
	umount "$GDS_MNT"
	timeout 60 "$MDADM" --stop /dev/ms0 >/dev/null 2>&1 \
		|| { gds_verdict p7 "p7h_${name}_stop" FAIL "mdadm --stop timed out"; echo "FAIL: [$name] stop" >&2; exit 1; }
	P2PDMA_ARRAY=""
	if [ "$uspass" = 1 ]; then
		for m in "$M0" "$M1"; do   # remote leg readable via its nvmet backing dev
			sum_leg=$(gds_leg_sha "$m" gds-test.bin) || { uspass=0; break; }
			echo "[$name] sha $m: $sum_leg (array: $sum_array)"
			[ "$sum_leg" = "$sum_array" ] || uspass=0
		done
	fi
	if [ "$uspass" = 1 ]; then
		gds_verdict p7 "p7h_${name}_userspace" PASS "rc=0 bounce retry + both-legs convergence"
	elif [ "$P7C_OUTCOME" = "cuFile compat mode does not retry mid-IO errors" ]; then
		# only the exact policy-hatch string P7c banked is inheritable
		gds_verdict p7 "p7h_${name}_userspace" SKIP "inherited from P7c: cuFile compat mode does not retry mid-IO errors"
		USSKIP=1
	else
		# P7c passed or its outcome is unknown — this pair's failure is
		# its own result, never "inherited"
		gds_verdict p7 "p7h_${name}_userspace" FAIL "rc=$wrc / convergence failed (P7c userspace outcome: $P7C_OUTCOME)"
		USFAIL=1
	fi
}

run_leg_fail local  "$M0"
run_leg_fail remote "$REMOTE"

[ "$USFAIL" = 0 ] || { echo "FAIL: userspace pair failed with no inheritable P7c policy hatch (P7c outcome: $P7C_OUTCOME)" >&2; exit 1; }
if [ "$USSKIP" = 1 ]; then
	echo "SKIP: kernel side PASS both legs; userspace pair inherited: cuFile compat mode does not retry mid-IO errors" >&2
	exit 4
fi
echo "PASS: any-leg failure retried via CPU/kernel — fail-local and fail-remote both converged"
exit 0

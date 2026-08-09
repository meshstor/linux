#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# leg2 is P2P-unreachable from the CMB: the write must fail -EINVAL,
# fault nothing, and record no badblocks. On the UNFIXED base this
# observes the bug: the write reports SUCCESS (silent divergence).
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -z "${P2P_IN_VM:-}" ]; then
	exec "$DIR/run_vm.sh" asymmetric \
		env P2P_IN_VM=1 MS_MOD_DIR="${MS_MOD_DIR:-}" \
		MDADM="${MDADM:-}" MD_SUBSYS="${MD_SUBSYS:-}" \
		"$DIR/$(basename "$0")"
fi
. "$DIR/lib.sh"
p2p_require_root; p2p_require_rig
trap p2p_cleanup EXIT
p2p_load_ms_modules
ARR="$(p2p_make_array 1 "$(p2p_nvme_by_serial leg1)" "$(p2p_nvme_by_serial leg2)")"
RC="$(p2p_io write "$ARR" "$(p2p_bdf_by_serial cmb0)")"
[ "$RC" = "-22" ] || p2p_fail "asymmetric p2p write returned errno=$RC, want -22 (EINVAL)"
p2p_member_state "$ARR" | grep -q "Failed Devices : 0" \
	|| p2p_fail "healthy member was faulted for a topology miss"
for bb in /sys/block/$(basename "$ARR")/$P2P_SYSFS/rd*/bad_blocks; do
	[ -e "$bb" ] || p2p_fail "bad_blocks sysfs missing at $bb"
	[ -z "$(cat "$bb")" ] || p2p_fail "badblocks recorded at $bb: $(cat "$bb")"
done
dmesg | grep -q "no P2P path" || p2p_fail "expected pr_warn breadcrumb missing"
p2p_pass "asymmetric p2p write failed loud, faulted nothing"

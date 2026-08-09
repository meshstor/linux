#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# All legs P2P-reachable (one switch): a p2p write through raid1 succeeds.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -z "${P2P_IN_VM:-}" ]; then
	exec "$DIR/run_vm.sh" symmetric \
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
[ "$RC" = "0" ] || p2p_fail "symmetric p2p write returned errno=$RC, want 0"
p2p_member_state "$ARR" | grep -q "Failed Devices : 0" \
	|| p2p_fail "a member faulted on a fully-reachable write"
p2p_pass "symmetric p2p write ok"

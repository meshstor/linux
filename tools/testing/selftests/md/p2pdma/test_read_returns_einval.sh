#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# NO leg is P2P-reachable: a p2p READ must fail -EINVAL (topology miss,
# not a medium error). On the UNFIXED base it returns -5: raid1's read
# retry path clobbers the status into EIO. The `unreachable` topology is
# required here — on `asymmetric` a read may legitimately succeed because
# read_balance can pick the reachable leg.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -z "${P2P_IN_VM:-}" ]; then
	exec "$DIR/run_vm.sh" unreachable \
		env P2P_IN_VM=1 MS_MOD_DIR="${MS_MOD_DIR:-}" \
		MDADM="${MDADM:-}" MD_SUBSYS="${MD_SUBSYS:-}" \
		"$DIR/$(basename "$0")"
fi
. "$DIR/lib.sh"
p2p_require_root; p2p_require_rig
trap p2p_cleanup EXIT
p2p_load_ms_modules
ARR="$(p2p_make_array 1 "$(p2p_nvme_by_serial leg1)" "$(p2p_nvme_by_serial leg2)")"
RC="$(p2p_io read "$ARR" "$(p2p_bdf_by_serial cmb0)")"
[ "$RC" = "-22" ] || p2p_fail "all-unreachable p2p read returned errno=$RC, want -22 (EINVAL)"
p2p_pass "all-unreachable p2p read failed -EINVAL"

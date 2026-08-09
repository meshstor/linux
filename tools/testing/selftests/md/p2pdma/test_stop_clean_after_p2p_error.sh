#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# After a p2p write on an asymmetric topology the array must still stop
# cleanly — guards the close_write/writes_pending balance on the p2p
# error-out path. No assertion on the write's errno:
# this test must stay meaningful on the unfixed base too (where it is 0).
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
timeout 15 "$MDADM" --stop "$ARR" || p2p_fail "array stop hung after p2p error (writes_pending leak?)"
P2P_ARRAY=""
p2p_pass "array stopped clean after p2p-error write"

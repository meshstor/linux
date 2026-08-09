#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# After a p2p write on an asymmetric topology the array must still stop
# cleanly -- guards the close_write/writes_pending balance on the
# P2PDMA-badblock completion path (handle_write_finished()'s fail=true
# branch defers close_write() to the retry-list drain; a leaked
# writes_pending would hang --stop forever).
#
# Under v6 semantics the write itself succeeds (RC=0, badblock recorded
# on leg2, no fault -- see test_topology_single_leg_unreachable.sh for
# that assertion in full); this test only cares that the array can still
# be torn down afterwards.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
if [ -z "${P2P_IN_VM:-}" ]; then
	p2p_require_rig
	exec "$DIR/run_vm.sh" asymmetric \
		env P2P_IN_VM=1 MS_MOD_DIR="${MS_MOD_DIR:-}" \
		MDADM="${MDADM:-}" MD_SUBSYS="${MD_SUBSYS:-}" \
		"$DIR/$(basename "$0")"
fi
p2p_require_root; p2p_require_rig
trap p2p_cleanup EXIT
p2p_load_ms_modules
ARR="$(p2p_make_array 1 "$(p2p_nvme_by_serial leg1)" "$(p2p_nvme_by_serial leg2)")"
p2p_io write "$ARR" "$(p2p_bdf_by_serial cmb0)" >/dev/null
timeout 15 "$MDADM" --stop "$ARR" || p2p_fail "array stop hung after p2p error (writes_pending leak?)"
P2P_ARRAY=""
p2p_pass "array stopped clean after p2p-error write"

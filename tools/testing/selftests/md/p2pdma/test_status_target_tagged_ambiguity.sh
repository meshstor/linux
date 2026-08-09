#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# A P2P-TAGGED write (built from real CMB pages via p2p_io/md_p2p_test)
# that fails with a genuine BLK_STS_TARGET on one leg. Companion to
# test_status_matrix_injected.sh's untagged TARGET cell, which asserts
# WantReplacement gets set unambiguously.
#
# Here it does not, on every kernel: per Task 8's review of hunk 5 (see
# docs/superpowers/sdd/2026-07-29-p2pdma-v6-rework/progress.md, "Task 8:
# Important 2"), a genuinely-TARGET completion on a P2P-tagged bio is, on
# a compat kernel (6.12/6.14 -- ones lacking native BLK_STS_P2PDMA),
# translated to P2PDMA by the DKMS compat layer: those kernels cannot
# tell a real target-class error apart from a topology miss on a tagged
# bio, and the design deliberately errs toward treating it as a P2P miss
# (fencing the range, not escalating to WantReplacement/failfast) rather
# than risk mis-escalating a topology issue. On a native kernel (7.2+, or
# any kernel where the ambiguity does not apply) TARGET is unambiguous and
# WantReplacement gets set normally, same as the untagged case.
#
# So, per this file's own instructions (record actual behaviour, don't
# assert a single universal outcome): the universally-true invariants
# (write succeeds, range fenced, nothing faulted) are hard-asserted;
# WantReplacement is recorded, not asserted either way.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
if [ -z "${P2P_IN_VM:-}" ]; then
	p2p_require_rig
	exec "$DIR/run_vm.sh" symmetric \
		env P2P_IN_VM=1 MS_MOD_DIR="${MS_MOD_DIR:-}" \
		MDADM="${MDADM:-}" MD_SUBSYS="${MD_SUBSYS:-}" \
		"$DIR/$(basename "$0")"
fi
p2p_require_root; p2p_require_rig
trap 'p2p_cleanup; dmsetup remove legB 2>/dev/null; rmmod dm_errstat 2>/dev/null; rmmod brd 2>/dev/null' EXIT
p2p_load_ms_modules
modprobe brd rd_nr=2 rd_size=65536
p2p_load_dm_errstat
dmsetup create legB --table "0 $(blockdev --getsz /dev/ram1) errstat /dev/ram1 121"
ARR="$(p2p_make_array 1 /dev/ram0 /dev/mapper/legB)"
dmsetup message legB 0 arm
RC="$(p2p_io write "$ARR" "$(p2p_bdf_by_serial cmb0)")"
dmsetup message legB 0 disarm

[ "$RC" = "0" ] || p2p_fail "tagged TARGET write returned errno=$RC, want 0 (should still succeed off legA)"

RDB="$(p2p_rd_dir_for_dev "$ARR" /dev/mapper/legB)" || p2p_fail "cannot find legB's rdev sysfs dir"
p2p_bb_nonempty "$RDB/bad_blocks" || p2p_fail "no badblock recorded on legB"
p2p_is_faulty "$RDB" && p2p_fail "legB was faulted (failfast not configured)"

if p2p_wants_replacement "$RDB"; then
	echo "note: legB got WantReplacement -- this kernel treated the tagged TARGET as an ordinary error (unambiguous / native-status kernel)"
else
	echo "note: legB did NOT get WantReplacement -- this kernel's compat layer translated the tagged TARGET to a P2P miss (Task 8 ambiguity)"
fi
p2p_pass "tagged TARGET write: succeeded, legB fenced, nothing faulted (WantReplacement recorded above, not asserted)"

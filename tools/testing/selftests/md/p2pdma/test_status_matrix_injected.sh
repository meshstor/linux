#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# The core status/personality/scope matrix from the v6 rework's test plan:
# {INVAL, TARGET, P2PDMA} x {raid1, raid10} x {one leg, all legs} for
# WRITE, plus P2PDMA x {raid1, raid10} x {one leg, all legs} for READ.
# Legs are brd ram disks wrapped in dm-errstat, so every status is
# injected deterministically -- no real PCIe topology is involved here
# (see test_topology_*.sh for the real-hardware arm of this suite).
#
# INVAL and TARGET writes use an ORDINARY (non-P2P-tagged) pwrite: those
# two statuses are handled by raid1's pre-existing, P2P-unrelated
# write-error logic (raid1_should_handle_error()'s INVAL carve-out, and
# ordinary narrow_write_error() for TARGET), so this matrix confirms that
# logic is untouched by the P2P rework, with unambiguous assertions.
# P2PDMA writes go through p2p_io (a real P2P-tagged payload via the CMB
# provider) to match how the brief frames the P2P-specific cells; the
# TARGET-tagged compat-layer ambiguity from Task 8's review has its own
# dedicated test in test_status_target_tagged_ambiguity.sh.
#
# v6 semantics under test (see docs/superpowers/plans/2026-07-29-p2pdma-v6-rework.md):
#   P2PDMA: badblock, no WantReplacement, no fault; master write succeeds
#     iff at least one leg is unaffected (one-leg scope), else an honest
#     failure (all-legs scope) -- never a false success.
#   TARGET: ordinary write-error handling -- badblock AND WantReplacement;
#     still no fault (this suite never sets failfast); same success
#     pattern by scope as P2PDMA.
#   INVAL: upstream's pre-existing "user error, don't retry, don't record"
#     carve-out -- no badblock, no WantReplacement, and the write is
#     always treated as successful REGARDLESS of scope (even an
#     all-legs-INVAL write "succeeds": each leg's ignored completion
#     independently satisfies R1BIO_Uptodate). This is untouched,
#     pre-existing upstream behaviour, asserted here only so a future
#     change to it doesn't slip by unnoticed.
#
# READ coverage is P2PDMA-only: ordinary (TARGET/INVAL) read-error
# handling goes through the pre-existing fix_read_error()/freeze_array()
# machinery, which is out of scope for this task's rework and not
# re-verified here.
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
p2p_require_tool xfs_io
p2p_require_tool dmsetup

cleanup_all() {
	p2p_cleanup
	dmsetup remove legA 2>/dev/null
	dmsetup remove legB 2>/dev/null
	rmmod dm_errstat 2>/dev/null
	rmmod brd 2>/dev/null
}
trap cleanup_all EXIT
p2p_load_ms_modules
modprobe brd rd_nr=2 rd_size=65536
p2p_load_dm_errstat
dmsetup create legA --table "0 $(blockdev --getsz /dev/ram0) errstat /dev/ram0 5"
dmsetup create legB --table "0 $(blockdev --getsz /dev/ram1) errstat /dev/ram1 5"

fails=0
note() { echo "  $*"; }
check() {   # check <description> <got> <want>
	if [ "$2" = "$3" ]; then
		note "ok: $1 ($2)"
	else
		echo "FAIL: $1: got '$2' want '$3'" >&2
		fails=$((fails + 1))
	fi
}

# arm_status <target> <status>: reprogram legA/legB with a fresh status
# (dm-errstat's status is fixed at table-load time, so reload the table).
arm_status() {
	local tgt="$1" status="$2" sz
	sz=$(blockdev --getsz "/dev/$([ "$tgt" = legA ] && echo ram0 || echo ram1)")
	dmsetup suspend "$tgt"
	dmsetup load "$tgt" --table "0 $sz errstat /dev/$([ "$tgt" = legA ] && echo ram0 || echo ram1) $status"
	dmsetup resume "$tgt"
}

for LEVEL in 1 10; do
	for SCOPE in one all; do
		echo "=== level=$LEVEL scope=$SCOPE ==="
		for STATUS in p2pdma target inval; do
			case "$STATUS" in
			p2pdma) SPEC=p2pdma ;;
			target) SPEC=121 ;;
			inval)  SPEC=22 ;;
			esac
			arm_status legA "$SPEC"
			arm_status legB "$SPEC"
			dmsetup message legA 0 disarm
			dmsetup message legB 0 disarm
			ARR="$(p2p_make_array "$LEVEL" /dev/mapper/legA /dev/mapper/legB)"
			if [ "$SCOPE" = all ]; then
				dmsetup message legA 0 arm write
			fi
			dmsetup message legB 0 arm write

			if [ "$STATUS" = p2pdma ]; then
				RC="$(p2p_io write "$ARR" "$(p2p_bdf_by_serial cmb0)")"
			else
				RC=0
				p2p_ordinary_write "$ARR" 0 4096 || RC=1
			fi

			RDB="$(p2p_rd_dir_for_dev "$ARR" /dev/mapper/legB)" \
				|| p2p_fail "cannot find legB's rdev sysfs dir (level=$LEVEL scope=$SCOPE status=$STATUS)"
			BBB="$RDB/bad_blocks"
			case "$STATUS:$SCOPE" in
			p2pdma:one)
				check "$STATUS/$SCOPE/$LEVEL write succeeds"    "$RC" "0"
				check "$STATUS/$SCOPE/$LEVEL legB badblocked"    "$(p2p_bb_nonempty "$BBB" && echo yes || echo no)" "yes"
				check "$STATUS/$SCOPE/$LEVEL legB want_replacement" "$(p2p_wants_replacement "$RDB" && echo yes || echo no)" "no"
				;;
			p2pdma:all)
				check "$STATUS/$SCOPE/$LEVEL write fails honestly" "$([ "$RC" != 0 ] && echo yes || echo no)" "yes"
				check "$STATUS/$SCOPE/$LEVEL legB badblocked"    "$(p2p_bb_nonempty "$BBB" && echo yes || echo no)" "yes"
				;;
			target:one)
				check "$STATUS/$SCOPE/$LEVEL write succeeds"    "$RC" "0"
				check "$STATUS/$SCOPE/$LEVEL legB badblocked"    "$(p2p_bb_nonempty "$BBB" && echo yes || echo no)" "yes"
				check "$STATUS/$SCOPE/$LEVEL legB want_replacement" "$(p2p_wants_replacement "$RDB" && echo yes || echo no)" "yes"
				;;
			target:all)
				check "$STATUS/$SCOPE/$LEVEL write fails honestly" "$([ "$RC" != 0 ] && echo yes || echo no)" "yes"
				check "$STATUS/$SCOPE/$LEVEL legB badblocked"    "$(p2p_bb_nonempty "$BBB" && echo yes || echo no)" "yes"
				check "$STATUS/$SCOPE/$LEVEL legB want_replacement" "$(p2p_wants_replacement "$RDB" && echo yes || echo no)" "yes"
				;;
			inval:*)
				check "$STATUS/$SCOPE/$LEVEL write still succeeds (upstream carve-out)" "$RC" "0"
				check "$STATUS/$SCOPE/$LEVEL legB NOT badblocked" "$(p2p_bb_nonempty "$BBB" && echo yes || echo no)" "no"
				check "$STATUS/$SCOPE/$LEVEL legB no want_replacement" "$(p2p_wants_replacement "$RDB" && echo yes || echo no)" "no"
				;;
			esac
			p2p_is_faulty "$RDB" && { echo "FAIL: $STATUS/$SCOPE/$LEVEL legB was faulted (failfast not configured)" >&2; fails=$((fails + 1)); }

			dmsetup message legA 0 disarm
			dmsetup message legB 0 disarm
			"$MDADM" --stop "$ARR" >/dev/null 2>&1
			P2P_ARRAY=""
		done

		# READ, P2PDMA-only (see file header for why).
		arm_status legA p2pdma
		arm_status legB p2pdma
		dmsetup message legA 0 disarm
		dmsetup message legB 0 disarm
		ARR="$(p2p_make_array "$LEVEL" /dev/mapper/legA /dev/mapper/legB)"
		if [ "$SCOPE" = all ]; then
			dmsetup message legA 0 arm read
		fi
		dmsetup message legB 0 arm read
		RC="$(p2p_io read "$ARR" "$(p2p_bdf_by_serial cmb0)")"
		if [ "$SCOPE" = one ]; then
			check "p2pdma/$SCOPE/$LEVEL read succeeds (served from other leg)" "$RC" "0"
		else
			check "p2pdma/$SCOPE/$LEVEL read fails honestly" "$([ "$RC" != 0 ] && echo yes || echo no)" "yes"
		fi
		dmsetup message legA 0 disarm
		dmsetup message legB 0 disarm
		"$MDADM" --stop "$ARR" >/dev/null 2>&1
		P2P_ARRAY=""
	done
done

[ "$fails" -eq 0 ] || p2p_fail "$fails assertion(s) failed in the status matrix"
p2p_pass "status/personality/scope matrix: all cells matched v6 semantics"

#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# The p2pdma_advertise=always knob must survive a hot-add of a member
# that cannot itself do P2P: raid1_p2pdma_reeval_on_change() re-runs
# raid1_can_advertise_p2pdma() on every add/remove, and under "always"
# that function short-circuits to true regardless of member capability
# (raid1-10.c: `if (p2pdma_advertise == 1) return true;`), so the array's
# own advertise bit must stay set. Without Task 5 (the reeval-on-change
# wiring), a naive re-derivation would clear it on this add.
#
# p2pdma_status_show() (md.c) now emits a leading array-level line
# ("array advertise=yes|no policy=auto|always|never") reflecting the
# array's own gendisk queue's BLK_FEAT_PCI_P2PDMA bit -- the same bit
# raid1_p2pdma_is_advertising() reads from the completion path -- ahead
# of the per-member lines. This asserts against that line directly.
#
# Fix-round history: an earlier version of this test fell back to a
# behavioural proxy (a P2P write still succeeds after the hot-add) when
# no array-level sysfs attribute could be found. That proxy could not
# fail: md_p2p_test's bio is built directly via bio_alloc()/bio_add_page(),
# bypassing bio_iov_iter_get_pages()/ITER_ALLOW_P2PDMA -- the only place
# the array's own BLK_FEAT_PCI_P2PDMA bit is actually consulted -- so a
# regressed build that silently cleared the advertise bit on hot-add
# would still pass. The array-level status line closes that gap; the
# proxy has been dropped rather than kept as a fallback.
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
trap 'p2p_advertise_set auto 2>/dev/null; p2p_cleanup; rmmod brd 2>/dev/null' EXIT
p2p_load_ms_modules
LEG1="$(p2p_nvme_by_serial leg1)"
LEG2="$(p2p_nvme_by_serial leg2)"
ARR="$(p2p_make_array 1 "$LEG1" "$LEG2")"
SFILE="$(p2p_status_file "$ARR")"

p2p_advertise_set always
[ "$(p2p_advertise_get)" = "always" ] || p2p_fail "p2pdma_advertise did not read back as 'always'"

# The array's queue bit was computed at run() time under whatever policy
# was in effect THEN (auto, both legs p2p-capable -> also "yes"); setting
# the module parameter here does not retroactively re-evaluate it -- only
# raid1_p2pdma_reeval_on_change() does that, on the add/remove below. This
# is a baseline sanity check (the line parses, and starts "yes"), not yet
# a check that "always" itself is in effect.
grep -q '^array advertise=yes policy=always$' "$SFILE" \
	|| p2p_fail "expected 'array advertise=yes policy=always' before the hot-add, got: $(head -1 "$SFILE")"

modprobe brd rd_nr=1 rd_size=65536
p2p_hot_remove "$ARR" "$LEG2" || p2p_fail "hot-remove of leg2 failed"
p2p_hot_add "$ARR" /dev/ram0 || p2p_fail "hot-add of the non-advertising replacement (brd) failed"

STATUS_LINE="$(grep -F "$(basename /dev/ram0)" "$SFILE" || true)"
echo "note: new member's p2pdma_status line: ${STATUS_LINE:-<not found by name>}"
case "$STATUS_LINE" in
*advertise=no*) : ;;
*) p2p_fail "new member (brd, no P2P support) does not read advertise=no: ${STATUS_LINE:-<missing>}" ;;
esac

grep -q '^array advertise=yes policy=always$' "$SFILE" \
	|| p2p_fail "array advertise dropped after hot-add of a non-advertising member under 'always' (Task 5 regression): $(head -1 "$SFILE")"

p2p_pass "p2pdma_advertise=always survived a hot-add of a non-advertising member (array advertise=yes throughout)"

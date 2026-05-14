#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Logical-block-size stability across the create -> stop -> assemble cycle.
#
# Closes the test-coverage gap called out in the mount-EINVAL review
# (.full-review finding P4 / issue #13): the existing reproducers are
# create-only and pin every member's logical block size, so they never
# exercise `mdadm --assemble` and never let member geometry vary across
# the stop/assemble boundary -- exactly the path DKMS patch 0003 gates.
#
# DKMS patch 0003 compiles out the mdp_superblock_1.logical_block_size
# read+write whenever the running kernel lacks that field. On such a
# kernel an md array does NOT persist its logical block size: it is
# recomputed as max() over the member devices on every md_run(). The
# upstream 6.18 superblock field exists to make it stable instead.
#
# This test branches on whether the running kernel has the field:
#
#   field PRESENT  (>= 6.18, or a vendor backport):
#       the array LBS MUST be pinned by the superblock -- unchanged across
#       an assemble even if the members now report a different LBS.
#       This is the assertion that fails on a version-gated 0003 and
#       passes on the HAVE_*-gated 0003. SKIPPED on pre-6.18 kernels.
#
#   field ABSENT   (the current el10_1 / pre-6.18 fleet):
#       the array LBS tracks max(member LBS), recomputed per assembly.
#       That is locked in as the documented contract -- and, crucially,
#       the XFS filesystem still assembles and mounts with no EINVAL in
#       every reachable case (a downward LBS drift is safe; set_blocksize
#       requires sb_sectsize >= bdev LBS, and 4096 >= {512,4096}).
#
# Either way: every create/assemble must succeed and every mount must
# succeed -- a regression that made assembly or mount EINVAL is caught.

set -eu

DIR="$(dirname "$0")"
# shellcheck source=tools/testing/selftests/md/llbitmap/lib.sh
. "$DIR/lib.sh"

llbitmap_require_root
llbitmap_require_modules
llbitmap_require_tools

command -v mkfs.xfs >/dev/null 2>&1 || llbitmap_skip "mkfs.xfs not available"
command -v mount    >/dev/null 2>&1 || llbitmap_skip "mount not available"
modprobe xfs >/dev/null 2>&1 || true
grep -qw xfs /proc/filesystems || llbitmap_skip "kernel has no xfs filesystem support"

# --- helpers -------------------------------------------------------------

# make_loop_lbs SIZE_MB SECTOR_SIZE  -> sets RET_LOOP and RET_FILE
RET_LOOP=""
RET_FILE=""
make_loop_lbs() {
	local size_mb="$1" sector="$2"
	RET_FILE="$(mktemp "${TMPDIR:-/tmp}/lbs-selftest.XXXXXX.img")"
	truncate -s "${size_mb}M" "$RET_FILE"
	RET_LOOP="$(losetup -f --show --sector-size "$sector" "$RET_FILE")"
	LLBITMAP_TEST_LOOPS+=("$RET_LOOP")
	LLBITMAP_TEST_FILES+=("$RET_FILE")
}

# reattach_loop OLD_LOOP FILE SECTOR_SIZE  -> sets RET_LOOP to the new loop
reattach_loop() {
	local old="$1" file="$2" sector="$3"
	losetup -d "$old" 2>/dev/null || true
	RET_LOOP="$(losetup -f --show --sector-size "$sector" "$file")"
	LLBITMAP_TEST_LOOPS+=("$RET_LOOP")
}

# array_lbs MS_DEV  -> logical block size the array reports
array_lbs() { blockdev --getss "$1"; }

# sb_lbs_field_state  -> "present" | "absent" | "unknown"
# Struct-scoped scan of the running kernel's mdp_superblock_1, mirroring
# the HAVE_MDP_SB1_LOGICAL_BLOCK_SIZE detector in dkms/Makefile.in.
sb_lbs_field_state() {
	local hdr
	hdr="/lib/modules/$(uname -r)/build/include/uapi/linux/raid/md_p.h"
	if [ ! -f "$hdr" ]; then
		echo unknown
		return 0
	fi
	if awk '/^struct[[:space:]]+mdp_superblock_1[[:space:]]*\{/{in_s=1; next}
		in_s && /^\};/{in_s=0; exit}
		in_s && /\<logical_block_size\>[[:space:]]*;/{print "found"; exit}' \
		"$hdr" | grep -q found; then
		echo present
	else
		echo absent
	fi
}

dump_dmesg_tail() {
	echo "INFO: recent dmesg tail:" >&2
	dmesg | tail -25 | sed 's/^/  /' >&2
}

MARKER="meshstor-lbs-stability $$ $(date -u +%s)"
ARRAY_MB=600

FIELD="$(sb_lbs_field_state)"
echo "INFO: running kernel $(uname -r): mdp_superblock_1.logical_block_size = $FIELD"

# ========================================================================
# Scenario A -- create -> mkfs -> mount -> stop -> ASSEMBLE -> mount cycle.
# The reproducers never did the assemble half of this. Members pinned 4096.
# ========================================================================
echo "INFO: === scenario A: create/stop/assemble/mount cycle (members @4096) ==="

make_loop_lbs "$ARRAY_MB" 4096; A_LA="$RET_LOOP"
make_loop_lbs "$ARRAY_MB" 4096; A_LB="$RET_LOOP"
llbitmap_alloc_ms_dev >/dev/null
A_DEV="$LLBITMAP_TEST_MS_DEV"
echo "INFO: ms_dev=$A_DEV LA=$A_LA LB=$A_LB"

"$MDADM" --create "$A_DEV" \
	--level=1 --metadata=1.2 --raid-devices=2 --homehost=any \
	--bitmap=internal "$A_LA" "$A_LB" --run --force </dev/null >/dev/null 2>&1 \
	|| { dump_dmesg_tail; llbitmap_fail "scenario A: mdadm --create failed"; }
"$MDADM" --wait "$A_DEV" >/dev/null 2>&1 || true

lbs_create="$(array_lbs "$A_DEV")"
echo "INFO: array LBS after create = $lbs_create"
[ "$lbs_create" = "4096" ] \
	|| llbitmap_fail "scenario A: expected array LBS 4096 after create, got $lbs_create"

mkfs.xfs -f -K -s size=4096 -b size=4096 "$A_DEV" >/dev/null 2>&1 \
	|| { dump_dmesg_tail; llbitmap_fail "scenario A: mkfs.xfs failed"; }

A_MNT="$(mktemp -d "${TMPDIR:-/tmp}/lbs-mnt.XXXXXX")"
LLBITMAP_TEST_MOUNT="$A_MNT"
mount -t xfs "$A_DEV" "$A_MNT" 2>/dev/null \
	|| { dump_dmesg_tail; llbitmap_fail "scenario A: first mount failed (EINVAL?)"; }
printf '%s\n' "$MARKER" > "$A_MNT/marker"
sync
umount "$A_MNT"
"$MDADM" --stop "$A_DEV" >/dev/null 2>&1

# the half no reproducer covered: assemble it back
"$MDADM" --assemble "$A_DEV" "$A_LA" "$A_LB" --run --force >/dev/null 2>&1 \
	|| { dump_dmesg_tail; llbitmap_fail "scenario A: mdadm --assemble failed"; }
"$MDADM" --wait "$A_DEV" >/dev/null 2>&1 || true

lbs_assemble="$(array_lbs "$A_DEV")"
echo "INFO: array LBS after assemble = $lbs_assemble"
[ "$lbs_assemble" = "4096" ] \
	|| llbitmap_fail "scenario A: expected array LBS 4096 after assemble, got $lbs_assemble"

mount -t xfs "$A_DEV" "$A_MNT" 2>/dev/null \
	|| { dump_dmesg_tail; llbitmap_fail "scenario A: remount after assemble failed (EINVAL?)"; }
got="$(cat "$A_MNT/marker" 2>/dev/null || echo "")"
[ "$got" = "$MARKER" ] \
	|| llbitmap_fail "scenario A: marker file did not survive the assemble cycle"
umount "$A_MNT"
"$MDADM" --stop "$A_DEV" >/dev/null 2>&1
rmdir "$A_MNT"
LLBITMAP_TEST_MOUNT=""
echo "INFO: scenario A passed"

# ========================================================================
# Scenario C -- member backing LBS *changes* across the stop/assemble
# boundary. This is the path patch 0003 gates: with the superblock field
# absent, the array LBS is recomputed from the (now different) members.
# ========================================================================
echo "INFO: === scenario C: member LBS changes across assemble (4096 -> 512) ==="

make_loop_lbs "$ARRAY_MB" 4096; C_LA="$RET_LOOP"; C_LA_FILE="$RET_FILE"
make_loop_lbs "$ARRAY_MB" 4096; C_LB="$RET_LOOP"; C_LB_FILE="$RET_FILE"
llbitmap_alloc_ms_dev >/dev/null
C_DEV="$LLBITMAP_TEST_MS_DEV"
echo "INFO: ms_dev=$C_DEV LA=$C_LA ($C_LA_FILE) LB=$C_LB ($C_LB_FILE)"

"$MDADM" --create "$C_DEV" \
	--level=1 --metadata=1.2 --raid-devices=2 --homehost=any \
	--bitmap=internal "$C_LA" "$C_LB" --run --force </dev/null >/dev/null 2>&1 \
	|| { dump_dmesg_tail; llbitmap_fail "scenario C: mdadm --create failed"; }
"$MDADM" --wait "$C_DEV" >/dev/null 2>&1 || true

lbs_c_create="$(array_lbs "$C_DEV")"
[ "$lbs_c_create" = "4096" ] \
	|| llbitmap_fail "scenario C: expected array LBS 4096 at create, got $lbs_c_create"

mkfs.xfs -f -K -s size=4096 -b size=4096 "$C_DEV" >/dev/null 2>&1 \
	|| { dump_dmesg_tail; llbitmap_fail "scenario C: mkfs.xfs failed"; }
C_MNT="$(mktemp -d "${TMPDIR:-/tmp}/lbs-mnt.XXXXXX")"
LLBITMAP_TEST_MOUNT="$C_MNT"
mount -t xfs "$C_DEV" "$C_MNT" 2>/dev/null \
	|| { dump_dmesg_tail; llbitmap_fail "scenario C: initial mount failed"; }
printf '%s\n' "$MARKER" > "$C_MNT/marker"
sync
umount "$C_MNT"
"$MDADM" --stop "$C_DEV" >/dev/null 2>&1

# Re-attach both members' backing files at a *different* logical block
# size. The bytes are unchanged; only the LBS the block device reports
# changes -- the NVMe-oF "geometry varies across re-import" case, modelled
# locally. (loop cannot exceed PAGE_SIZE, so 4096->512 is the reachable
# direction; an 8192 member -- the only LBS that fails a 4096 XFS mount --
# is unreachable here, exactly as the review established.)
reattach_loop "$C_LA" "$C_LA_FILE" 512; C_LA="$RET_LOOP"
reattach_loop "$C_LB" "$C_LB_FILE" 512; C_LB="$RET_LOOP"
echo "INFO: re-attached members at LBS 512: LA=$C_LA LB=$C_LB"

"$MDADM" --assemble "$C_DEV" "$C_LA" "$C_LB" --run --force >/dev/null 2>&1 \
	|| { dump_dmesg_tail; llbitmap_fail "scenario C: assemble after LBS change failed"; }
"$MDADM" --wait "$C_DEV" >/dev/null 2>&1 || true

lbs_c_assemble="$(array_lbs "$C_DEV")"
echo "INFO: array LBS after assemble with 512-LBS members = $lbs_c_assemble"

case "$FIELD" in
present)
	# Superblock persists the LBS: it must be pinned, not recomputed.
	# This is the assertion a version-gated 0003 fails.
	[ "$lbs_c_assemble" = "4096" ] || {
		dump_dmesg_tail
		llbitmap_fail "scenario C: kernel HAS the superblock LBS field, so the array LBS must stay pinned at 4096 across assembly; got $lbs_c_assemble (patch 0003 is gating the field out -- check HAVE_MDP_SB1_LOGICAL_BLOCK_SIZE)"
	}
	echo "INFO: field present -> LBS correctly pinned at 4096 across assembly"
	;;
absent)
	# Documented pre-6.18 contract: LBS = max(member LBS), recomputed.
	# Both members now 512 -> array LBS 512.
	[ "$lbs_c_assemble" = "512" ] || {
		dump_dmesg_tail
		llbitmap_fail "scenario C: pre-6.18 kernel should recompute array LBS = max(member LBS) = 512 after re-attach; got $lbs_c_assemble"
	}
	echo "INFO: field absent -> LBS recomputed to 512 (documented pre-6.18 de-pinning)"
	;;
*)
	# Unknown: don't pin the exact value, just require it sane.
	case "$lbs_c_assemble" in
		512|4096) : ;;
		*) llbitmap_fail "scenario C: array LBS $lbs_c_assemble is not a sane value" ;;
	esac
	echo "INFO: field state unknown -> LBS $lbs_c_assemble accepted as sane"
	;;
esac

# The decisive check for BOTH branches: the XFS-4096 filesystem must still
# mount -- no mount-EINVAL -- and the data must survive.
mount -t xfs "$C_DEV" "$C_MNT" 2>/dev/null \
	|| { dump_dmesg_tail; llbitmap_fail "scenario C: mount after member-LBS change failed (mount-EINVAL regression)"; }
got="$(cat "$C_MNT/marker" 2>/dev/null || echo "")"
[ "$got" = "$MARKER" ] \
	|| llbitmap_fail "scenario C: marker file did not survive the LBS-change assemble cycle"
umount "$C_MNT"
"$MDADM" --stop "$C_DEV" >/dev/null 2>&1
rmdir "$C_MNT"
LLBITMAP_TEST_MOUNT=""
echo "INFO: scenario C passed"

llbitmap_pass "LBS stable across create/stop/assemble; XFS mounts with no EINVAL (field=$FIELD)"

#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# P6: stage-1 NARROWNESS PROOF. Stage-1 fail-the-write keys on the R1BIO_P2P
# bit; this test injects INVAL into plain (non-P2P) CPU writes, so upstream's
# swallow semantics MUST still hold on a stage-1 module: the injected
# plain-bio INVAL is counted as success (rc=0), [UU] preserved, the flakey
# leg silently stale — and the stage-1 arm must NOT fire ("no P2P path"
# breadcrumb absent from the dmesg delta). A PASS proves the guard is
# correctly narrow; a breadcrumb here means the arm fired for a non-P2P bio
# — kernel bug, escalate, do not loosen.
#
# Rig: leg1 sits behind dm-flakey; for the divergence write flakey
# error_writes makes the write fail (IOERR, never reaches media) and
# inval_inject rewrites that completion to INVAL at raid1_ms's
# raid1_end_write_request (module-qualified probe — in-tree raid1 being
# loaded no longer matters, which un-SKIPs this test on root-on-md boxes).
# GPU-independent (the swallow is status-based).
#
# DELIBERATE non-CSI rig: bare no-bitmap create + safe_mode_delay=0 keep
# superblock/bitmap traffic off the flakey leg during the error window (a
# failed SB write would fault the leg through md_error and mask the
# data-path swallow under test). Do not normalize to the CSI shape.
set -eu
DIR="$(dirname "$0")"; . "$DIR/lib.sh"
p2pdma_require_root; p2pdma_require_modules; p2pdma_require_tools
command -v dmsetup >/dev/null || { echo "SKIP: dmsetup missing" >&2; exit 4; }
modprobe dm-flakey 2>/dev/null || true
dmsetup targets | grep -q '^flakey' || { echo "SKIP: dm-flakey unavailable" >&2; exit 4; }
gds_injector_require raid1_end_write_request raid1_ms

PAT_A=/tmp/gds-div-A.$$; PAT_C=/tmp/gds-div-C.$$
FLAKE=gdsflake$$
cleanup() {
	gds_injector_unload
	[ -n "$P2PDMA_ARRAY" ] && "$MDADM" --stop "$P2PDMA_ARRAY" >/dev/null 2>&1 || true
	P2PDMA_ARRAY=""
	dmsetup remove "$FLAKE" 2>/dev/null || true
	gds_teardown
	rm -f "$PAT_A" "$PAT_C"
}
trap cleanup EXIT

p2pdma_pick_members raid1
M0="$P2PDMA_M0"; M1="$P2PDMA_M1"
SZ=$(blockdev --getsz "$M1")

# Defensive: a leftover 1.2 superblock on either member (e.g. a prior
# interrupted run) lets udev incremental-assembly grab the freshly created
# dm-flakey device the instant it appears, autoloading the in-tree raid1
# personality module -- which silently reintroduces the exact
# kprobe-symbol ambiguity the SKIP guard above exists to prevent (observed
# live: the kprobe bound to in-tree raid1's raid1_end_write_request instead
# of raid1_ms's, so it never fired for our array's completions).
"$MDADM" --zero-superblock "$M0" >/dev/null 2>&1 || true
"$MDADM" --zero-superblock "$M1" >/dev/null 2>&1 || true

# leg1 behind dm-flakey, initially always-up
dmsetup create "$FLAKE" --table "0 $SZ flakey $M1 0 3600 0"
FLAKEDEV=/dev/mapper/$FLAKE
DMKN=$(dmsetup info -c --noheadings -o blkdevname "$FLAKE")

# No bitmap and safe_mode_delay=0: keeps superblock/bitmap traffic off the
# flakey leg during the error window (a failed SB write would fault the leg
# through md_error and mask the data-path bug under test).
"$MDADM" --create /dev/ms0 --level=1 --raid-devices=2 --metadata=1.2 \
	--homehost=any --assume-clean --run "$M0" "$FLAKEDEV" >/dev/null 2>&1 \
	|| { echo "SKIP: array create failed" >&2; exit 4; }
P2PDMA_ARRAY=/dev/ms0
echo 0 > /sys/block/ms0/ms/safe_mode_delay

# Pattern A while healthy -> both legs hold A (also performs the dirty-SB write)
dd if=/dev/urandom of="$PAT_A" bs=1M count=8 status=none
dd if="$PAT_A" of=/dev/ms0 bs=1M count=8 oflag=direct status=none
sync

# Flip flakey to error_writes (writes fail instantly, reads pass through)
dmsetup suspend "$FLAKE"
dmsetup reload "$FLAKE" --table "0 $SZ flakey $M1 0 0 3600 1 error_writes"
dmsetup resume "$FLAKE"
command -v udevadm >/dev/null && udevadm settle --timeout=5 2>/dev/null || true

# The module-qualified probe (raid1_ms:raid1_end_write_request) resolves
# within raid1_ms regardless of udev's 64-md-raid-assembly.rules autoloading
# the in-tree raid1 module on dm change events (the old bare-symbol
# ambiguity that used to force a SKIP here). p2p_only=0 EXPLICIT: this rig
# injects into plain bios by design — that IS the narrowness proof.
gds_injector_load raid1_ms:raid1_end_write_request "$DMKN" -1 p2p_only=0 \
	|| { echo "SKIP: insmod inval_inject failed" >&2; exit 4; }
gds_dmesg_mark
gds_injector_arm 1000000

# --- the divergence write ---------------------------------------------------
dd if=/dev/urandom of="$PAT_C" bs=1M count=8 status=none  # reused as B then C
RC=0
dd if="$PAT_C" of=/dev/ms0 bs=1M count=8 oflag=direct conv=notrunc status=none || RC=$?
INJECTED=$(gds_injector_injected)
gds_injector_disarm

[ "$INJECTED" -gt 0 ] || { echo "FAIL: injector never fired (vacuous run)" >&2; exit 1; }
# Stage-1 is P2P-keyed: a plain-bio INVAL keeps upstream swallow semantics.
[ "$RC" -eq 0 ] || { echo "FAIL: non-P2P INVAL write returned rc=$RC — swallow semantics changed (stage-1 guard too wide?)" >&2; exit 1; }
ms0line=$(awk '/^ms0 :/{print;getline;print}' /proc/msstat)
echo "$ms0line" | grep -q '\[UU\]' \
	|| { echo "FAIL: a leg was faulted -- non-P2P INVAL was not swallowed" >&2; exit 1; }
# The stage-1 arm must NOT fire for non-P2P bios (narrowness).
gds_assert_no_breadcrumb \
	|| { echo "FAIL: stage-1 arm fired for a NON-P2P bio — kernel bug, escalate, do not loosen this test" >&2; exit 1; }

# --- contrast control: same failure WITHOUT the rewrite -> IOERR faults leg --
dd if="$PAT_A" of=/dev/ms0 bs=1M count=8 oflag=direct conv=notrunc status=none || true
ok=0
for _ in $(seq 50); do
	ms0line=$(awk '/^ms0 :/{print;getline;print}' /proc/msstat)
	echo "$ms0line" | grep -q '\[U_\]\|\[_U\]' && { ok=1; break; }
	sleep 0.2
done
[ "$ok" = 1 ] || { echo "FAIL: control IOERR write did not fault the leg" >&2; exit 1; }

"$MDADM" --stop /dev/ms0 >/dev/null 2>&1; P2PDMA_ARRAY=""

# Leg contents: M1 (read RAW, bypassing flakey) must still hold A -- the
# divergence-write data (PAT_C) never reached it although md reported success.
gds_cmp_legs "$PAT_A" $((8*1024*1024)) "$M1" \
	|| { echo "FAIL: leg1 does not hold pattern A -- rig assumption broken" >&2; exit 1; }

gds_verdict p6 divergence PASS "narrowness: injected=$INJECTED rc=0 msstat=[UU] leg1=stale(A) no-breadcrumb"
echo "PASS: non-P2P INVAL swallowed (narrowness proof) -- rc=0, [UU], leg1 stale, no breadcrumb (injected=$INJECTED)"
exit 0

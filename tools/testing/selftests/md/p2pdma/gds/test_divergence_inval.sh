#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# P6: reproduce the silent-divergence gap (p2pdma follow-up spec S2, Finding L).
# raid1_should_handle_error() treats BLK_STS_INVAL as benign, so a leg write
# that FAILED with INVAL is counted as success: master bio reports 0, no leg is
# faulted, and the legs silently diverge.
#
# Rig: leg1 sits behind dm-flakey; for the divergence write flakey error_writes
# makes the write fail (IOERR, never reaches media) and inval_inject rewrites
# that completion to INVAL at raid1_end_write_request -- exactly the shape of a
# P2P partial-reachability failure. GPU-independent (the swallow is
# status-based); the L40S adds the same run under real GDS writes.
#
# PASS here means THE BUG REPRODUCED (this is an evidence test). When the
# fail-the-write follow-up lands, flip the expectations marked [FLIP].
set -eu
DIR="$(dirname "$0")"; . "$DIR/lib.sh"
p2pdma_require_root; p2pdma_require_modules; p2pdma_require_tools
command -v dmsetup >/dev/null || { echo "SKIP: dmsetup missing" >&2; exit 4; }
modprobe dm-flakey 2>/dev/null || true
dmsetup targets | grep -q '^flakey' || { echo "SKIP: dm-flakey unavailable" >&2; exit 4; }
[ -d /sys/module/raid1 ] && { echo "SKIP: in-tree raid1 loaded (kprobe symbol ambiguity)" >&2; exit 4; }
INJ="$GDS_DIR_SELF/../../../../../../dkms/inval-inject"
[ -d "$INJ" ] || INJ="${GDS_INJ_DIR:-}"
[ -n "$INJ" ] && [ -d "$INJ" ] || { echo "SKIP: inval-inject source not found (set GDS_INJ_DIR)" >&2; exit 4; }
[ -d "/lib/modules/$(uname -r)/build" ] || { echo "SKIP: kernel headers missing" >&2; exit 4; }

PAT_A=/tmp/gds-div-A.$$; PAT_C=/tmp/gds-div-C.$$
FLAKE=gdsflake$$
cleanup() {
	rmmod inval_inject 2>/dev/null || true
	[ -n "$P2PDMA_ARRAY" ] && "$MDADM" --stop "$P2PDMA_ARRAY" >/dev/null 2>&1 || true
	P2PDMA_ARRAY=""
	dmsetup remove "$FLAKE" 2>/dev/null || true
	gds_teardown
	rm -f "$PAT_A" "$PAT_C"
}
trap cleanup EXIT

make -C "$INJ" >/dev/null 2>&1 || { echo "SKIP: inval_inject build failed" >&2; exit 4; }

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

# Re-check: 64-md-raid-assembly.rules fires mdadm --incremental on *every*
# udev "change" event a dm-* device gets (not just "add"), and the reload
# above is such an event. Even though our own array holds the superblock
# busy, the incremental probe still autoloads the in-tree raid1 personality
# module as a side effect (observed live), which silently steals the
# kprobe's symbol resolution (raid1_end_write_request exists in both
# modules) so it binds to the wrong one and never fires. The module isn't
# actually in use (no array runs under it), so remove it and re-arm; retry a
# few times since request_module() can lag the uevent handler that queued it.
for _ in $(seq 10); do
	[ -d /sys/module/raid1 ] || break
	modprobe -r raid1 2>/dev/null || true
	sleep 0.2
done
[ -d /sys/module/raid1 ] && { echo "SKIP: in-tree raid1 reappeared and would not unload (kprobe symbol ambiguity)" >&2; exit 4; }
insmod "$INJ/inval_inject.ko" disk="$DMKN" partno=-1 \
	|| { echo "SKIP: insmod inval_inject failed" >&2; exit 4; }
echo 1000000 > /sys/module/inval_inject/parameters/remaining

# --- the divergence write ---------------------------------------------------
dd if=/dev/urandom of="$PAT_C" bs=1M count=8 status=none  # reused as B then C
RC=0
dd if="$PAT_C" of=/dev/ms0 bs=1M count=8 oflag=direct conv=notrunc status=none || RC=$?
INJECTED=$(cat /sys/module/inval_inject/parameters/injected)
echo 0 > /sys/module/inval_inject/parameters/remaining

[ "$INJECTED" -gt 0 ] || { echo "FAIL: injector never fired (vacuous run)" >&2; exit 1; }
# [FLIP] with fail-the-write shipped, RC must be nonzero (EINVAL) instead.
[ "$RC" -eq 0 ] || { echo "FAIL: write returned rc=$RC, expected silent success (bug gone?)" >&2; exit 1; }
grep -q '\[UU\]' /proc/msstat \
	|| { echo "FAIL: a leg was faulted -- INVAL was not swallowed (bug gone?)" >&2; exit 1; }

# --- contrast control: same failure WITHOUT the rewrite -> IOERR faults leg --
dd if="$PAT_A" of=/dev/ms0 bs=1M count=8 oflag=direct conv=notrunc status=none || true
ok=0
for _ in $(seq 50); do grep -q '\[U_\]\|\[_U\]' /proc/msstat && { ok=1; break; }; sleep 0.2; done
[ "$ok" = 1 ] || { echo "FAIL: control IOERR write did not fault the leg" >&2; exit 1; }

"$MDADM" --stop /dev/ms0 >/dev/null 2>&1; P2PDMA_ARRAY=""

# Leg contents: M1 (read RAW, bypassing flakey) must still hold A -- the
# divergence-write data (PAT_C) never reached it although md reported success.
gds_cmp_legs "$PAT_A" $((8*1024*1024)) "$M1" \
	|| { echo "FAIL: leg1 does not hold pattern A -- rig assumption broken" >&2; exit 1; }

gds_verdict p6 divergence PASS "injected=$INJECTED rc=0 msstat=[UU] leg1=stale(A)"
echo "PASS: BLK_STS_INVAL swallowed -- write reported success, leg1 silently stale (injected=$INJECTED)"
exit 0

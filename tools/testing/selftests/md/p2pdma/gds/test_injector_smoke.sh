#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Injector smoke (GPU-free): module-qualified resolver + match=success +
# p2p_only filter, per the stage-1 validation design §5. Runs with the
# in-tree raid1 module CO-LOADED when possible — regression-testing the
# resolver against the exact ambiguity it exists to solve.
# NB deliberately non-P2P: only INVAL is swallowed for plain bios; TARGET
# would take the real-error path and fault a FailFast leg — never test
# non-P2P TARGET here.
set -eu
DIR="$(dirname "$0")"; . "$DIR/lib.sh"
p2pdma_require_root; p2pdma_require_modules; p2pdma_require_tools
[ -d "/lib/modules/$(uname -r)/build" ] || { echo "SKIP: kernel headers missing" >&2; exit 4; }
INJ="$GDS_DIR_SELF/../../../../../../dkms/inval-inject"
[ -d "$INJ" ] || INJ="${GDS_INJ_DIR:-}"
[ -n "$INJ" ] && [ -d "$INJ" ] || { echo "SKIP: inval-inject source not found (set GDS_INJ_DIR)" >&2; exit 4; }
make -C "$INJ" >/dev/null 2>&1 || { echo "SKIP: inval_inject build failed" >&2; exit 4; }

COLOADED=0
cleanup() {
	# brace group so 2>/dev/null also covers a failed > open (module gone):
	# bash reports a failed redirection before later redirects are applied.
	{ echo 0 > /sys/module/inval_inject/parameters/remaining; } 2>/dev/null || true
	rmmod inval_inject 2>/dev/null || true
	[ -n "$P2PDMA_ARRAY" ] && "$MDADM" --stop "$P2PDMA_ARRAY" >/dev/null 2>&1 || true
	P2PDMA_ARRAY=""
	[ "$COLOADED" = 1 ] && modprobe -r raid1 2>/dev/null || true
	p2pdma_teardown
}
trap cleanup EXIT

# Co-load the in-tree raid1 so the bare symbol is genuinely ambiguous.
if [ ! -d /sys/module/raid1 ]; then
	modprobe raid1 2>/dev/null && COLOADED=1 || true
fi
N=$(grep -c ' raid1_end_write_request' /proc/kallsyms || true)
echo "raid1_end_write_request copies in kallsyms: $N (in-tree co-loaded: $([ -d /sys/module/raid1 ] && echo yes || echo no))"

p2pdma_pick_members raid1
M0="$P2PDMA_M0"; M1="$P2PDMA_M1"
DISK=$(lsblk -dno KNAME "$M1" | head -1)
PARTNO=$(cat "/sys/class/block/$DISK/partition" 2>/dev/null || echo 0)
PK=$(lsblk -dno PKNAME "$M1" | head -1)
[ -n "$PK" ] && { DISK=$PK; }

gds_csi_mdadm_create /dev/ms0 1 "$M0" "$M1" >/dev/null 2>&1 \
	|| { echo "SKIP: array create failed" >&2; exit 4; }
P2PDMA_ARRAY=/dev/ms0

# --- (d) refuse rule: bare symbol + match=success must be refused ------------
if insmod "$INJ/inval_inject.ko" symbol=raid1_end_write_request \
	disk="$DISK" partno="$PARTNO" match=success 2>/dev/null; then
	rmmod inval_inject
	echo "FAIL: bare-symbol match=success insmod was NOT refused" >&2; exit 1
fi
echo "ok: bare-symbol match=success refused at insmod"

# --- (a)+(b) module-qualified resolver + plain-write INVAL swallow -----------
insmod "$INJ/inval_inject.ko" symbol=raid1_ms:raid1_end_write_request \
	disk="$DISK" partno="$PARTNO" match=success to_status=inval p2p_only=0 \
	|| { echo "FAIL: module-qualified insmod failed" >&2; exit 1; }
echo 8 > /sys/module/inval_inject/parameters/remaining
RC=0
dd if=/dev/urandom of=/dev/ms0 bs=1M count=8 oflag=direct status=none || RC=$?
echo 0 > /sys/module/inval_inject/parameters/remaining
INJECTED=$(cat /sys/module/inval_inject/parameters/injected)
[ "$INJECTED" -ge 1 ] || { echo "FAIL: resolver did not fire (injected=0) with in-tree raid1 co-loaded" >&2; exit 1; }
[ "$RC" -eq 0 ] || { echo "FAIL: plain-write INVAL was not swallowed (rc=$RC)" >&2; exit 1; }
awk '/^ms0 :/{print;getline;print}' /proc/msstat | grep -q '\[UU\]' \
	|| { echo "FAIL: a leg was faulted by a swallowed plain INVAL" >&2; exit 1; }
rmmod inval_inject
echo "ok: module-qualified probe fired (injected=$INJECTED), plain INVAL swallowed, [UU]"

# --- (c) p2p_only=1 filters plain writes to injected==0 ----------------------
insmod "$INJ/inval_inject.ko" symbol=raid1_ms:raid1_end_write_request \
	disk="$DISK" partno="$PARTNO" match=success to_status=inval p2p_only=1 \
	|| { echo "FAIL: p2p_only=1 insmod failed" >&2; exit 1; }
echo 8 > /sys/module/inval_inject/parameters/remaining
dd if=/dev/urandom of=/dev/ms0 bs=1M count=8 oflag=direct status=none \
	|| { echo "FAIL: plain write failed under p2p_only=1 (filter rewrote it?)" >&2; exit 1; }
echo 0 > /sys/module/inval_inject/parameters/remaining
INJECTED=$(cat /sys/module/inval_inject/parameters/injected)
[ "$INJECTED" -eq 0 ] \
	|| { echo "FAIL: p2p_only=1 rewrote $INJECTED plain-write completions (filter dead)" >&2; exit 1; }
rmmod inval_inject
echo "ok: p2p_only=1 filtered all plain writes (injected=0)"

"$MDADM" --stop /dev/ms0 >/dev/null 2>&1 || { echo "FAIL: array did not stop" >&2; exit 1; }
P2PDMA_ARRAY=""
gds_verdict smoke injector PASS "resolver+matrix+filter ok (kallsyms copies=$N)"
echo "PASS: injector smoke (module-qualified resolver, swallow, p2p filter, refuse rule)"
exit 0

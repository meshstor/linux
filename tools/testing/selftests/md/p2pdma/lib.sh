# SPDX-License-Identifier: GPL-2.0
# Guest-side helpers for the p2pdma selftests. Sourced, never executed.
# Conventions match ../llbitmap/lib.sh: MD_SUBSYS=ms by default, exit 4 = SKIP.
set -u

MD_SUBSYS="${MD_SUBSYS:-ms}"
case "$MD_SUBSYS" in
ms) P2P_DEV_PREFIX="ms";  P2P_SYSFS="ms";  P2P_CORE_MOD="ms_mod"
    P2P_RAID1_MOD="raid1_ms"; P2P_RAID10_MOD="raid10_ms" ;;
md) P2P_DEV_PREFIX="md";  P2P_SYSFS="md";  P2P_CORE_MOD="md_mod"
    P2P_RAID1_MOD="raid1";    P2P_RAID10_MOD="raid10" ;;
*)  echo "FAIL: unknown MD_SUBSYS=$MD_SUBSYS" >&2; exit 1 ;;
esac

MDADM="${MDADM:-/usr/local/bin/mdadm}"
MS_MOD_DIR="${MS_MOD_DIR:-}"
MODULES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/modules"

p2p_pass() { echo "PASS: $*"; exit 0; }
p2p_fail() { echo "FAIL: $*" >&2; exit 1; }
p2p_skip() { echo "SKIP: $*" >&2; exit 4; }

p2p_require_root() { [ "$(id -u)" -eq 0 ] || p2p_skip "must run as root"; }

p2p_require_rig() {
	[ -x "$MDADM" ] || p2p_skip "mdadm not found at $MDADM"
	[ -n "$MS_MOD_DIR" ] && [ -d "$MS_MOD_DIR" ] \
		|| p2p_skip "MS_MOD_DIR not set (directory with the built md modules)"
}

p2p_load_ms_modules() {
	insmod "$MS_MOD_DIR/$P2P_CORE_MOD.ko" 2>/dev/null || true
	insmod "$MS_MOD_DIR/$P2P_RAID1_MOD.ko" 2>/dev/null || true
	insmod "$MS_MOD_DIR/$P2P_RAID10_MOD.ko" 2>/dev/null || true
	grep -q "^$P2P_CORE_MOD " /proc/modules || p2p_fail "cannot load $P2P_CORE_MOD"
}

# nvme device node by qemu serial (cmb0/leg1/leg2) -> /dev/nvmeXn1
p2p_nvme_by_serial() {
	local want="$1" c
	for c in /sys/class/nvme/nvme*; do
		[ "$(cat "$c/serial" | tr -d ' ')" = "$want" ] || continue
		echo "/dev/$(basename "$c")n1"; return 0
	done
	return 1
}

# PCI BDF of the nvme controller with the given serial (p2pmem provider)
p2p_bdf_by_serial() {
	local want="$1" c
	for c in /sys/class/nvme/nvme*; do
		[ "$(cat "$c/serial" | tr -d ' ')" = "$want" ] || continue
		basename "$(readlink -f "$c/device")"; return 0
	done
	return 1
}

P2P_ARRAY=""
p2p_make_array() {   # p2p_make_array <level> <dev1> <dev2>  -> echoes /dev/ms0
	local level="$1" d1="$2" d2="$3" dev="/dev/${P2P_DEV_PREFIX}0"
	"$MDADM" --create "$dev" --run --force --level="$level" \
		--raid-devices=2 --assume-clean --bitmap=none \
		--metadata=1.2 "$d1" "$d2" >/dev/null 2>&1 \
		|| p2p_fail "mdadm --create $dev failed"
	P2P_ARRAY="$dev"
	echo "$dev"
}

p2p_cleanup() {
	[ -n "$P2P_ARRAY" ] && "$MDADM" --stop "$P2P_ARRAY" >/dev/null 2>&1
	rmmod md_p2p_test 2>/dev/null || true
	return 0
}

# errno of the last md_p2p_test run, from its dmesg result line:
#   md_p2p_test: result op=write target=/dev/ms0 status=8 errno=-22
p2p_last_result() {
	dmesg | grep 'md_p2p_test: result' | tail -1 \
		| sed -n 's/.*errno=\(-\?[0-9]*\).*/\1/p'
}

# Submit one p2p I/O via the test module. Usage:
#   p2p_io <op> <target-dev> <provider-bdf>   -> echoes errno (0 = success)
# Runs in command substitution, so on failure it returns 1 (never exits)
# and echoes nothing, printing a FAIL line to stderr instead.
p2p_io() {
	local op="$1" tgt="$2" prov="$3" before after
	[ -e "$MODULES_DIR/md_p2p_test.ko" ] || p2p_fail "md_p2p_test.ko not built (run make in modules/)"
	rmmod md_p2p_test 2>/dev/null || true
	before=$(dmesg | grep -c 'md_p2p_test: result' || true)
	insmod "$MODULES_DIR/md_p2p_test.ko" \
		provider="$prov" target="$tgt" op="$op" >/dev/null 2>&1 || true
	after=$(dmesg | grep -c 'md_p2p_test: result' || true)
	if [ "$after" -le "$before" ]; then
		echo "FAIL: p2p_io: no new result line (insmod failed before I/O?)" >&2
		return 1
	fi
	p2p_last_result
}

p2p_member_state() {   # p2p_member_state /dev/ms0 -> mdadm -D output
	"$MDADM" --detail "$1"
}

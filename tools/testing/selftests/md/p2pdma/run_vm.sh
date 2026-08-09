#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# run_vm.sh <symmetric|asymmetric|unreachable> <inner command...>
#
# Boots the RUNNING host kernel in QEMU (virtme-ng) with three emulated
# NVMe controllers and runs the inner command as root in the guest.
# The host filesystem is shared read-only, so MS_MOD_DIR / MDADM paths
# from the host work unchanged inside the guest.
#
# Topologies (q35, provider = CMB nvme "cmb0"):
#   symmetric   - cmb0, leg1, leg2 all behind ONE PCIe switch
#                 -> p2pdma map type BUS_ADDR for both legs (P2P works)
#   asymmetric  - cmb0+leg1 behind the switch, leg2 on a separate root
#                 port -> leg2 is PCI_P2PDMA_MAP_NOT_SUPPORTED (QEMU host
#                 bridge is not in the p2pdma whitelist)
#   unreachable - cmb0 behind the switch, leg1+leg2 both on separate
#                 root ports -> NO leg reachable
set -eu
TOPO="${1:?usage: run_vm.sh <symmetric|asymmetric|unreachable> <cmd...>}"; shift

# No virtme-ng on this host: SKIP (kselftest exit 4) so the suite degrades
# gracefully on boxes without the VM rig instead of failing at exit 127.
command -v vng >/dev/null 2>&1 \
	|| { echo "SKIP: virtme-ng (vng) not found in PATH" >&2; exit 4; }

SCRATCH="${TMPDIR:-/tmp}/p2pdma-vm.$$"; mkdir -p "$SCRATCH"
trap 'rm -rf "$SCRATCH"' EXIT
for img in cmb leg1 leg2; do
	truncate -s 64M "$SCRATCH/$img.img"
done

# One switch with three downstream ports; extra root ports for far legs.
COMMON="-machine q35
 -device pcie-root-port,id=rp1,slot=1
 -device pcie-root-port,id=rp2,slot=2
 -device pcie-root-port,id=rp3,slot=3
 -device x3130-upstream,id=sw,bus=rp1
 -device xio3130-downstream,id=swdp1,bus=sw,chassis=11
 -device xio3130-downstream,id=swdp2,bus=sw,chassis=12
 -device xio3130-downstream,id=swdp3,bus=sw,chassis=13
 -drive file=$SCRATCH/cmb.img,if=none,id=dcmb,format=raw
 -drive file=$SCRATCH/leg1.img,if=none,id=dleg1,format=raw
 -drive file=$SCRATCH/leg2.img,if=none,id=dleg2,format=raw
 -device nvme,serial=cmb0,drive=dcmb,cmb_size_mb=16,bus=swdp1"

case "$TOPO" in
symmetric)
	NVME="-device nvme,serial=leg1,drive=dleg1,bus=swdp2
	      -device nvme,serial=leg2,drive=dleg2,bus=swdp3" ;;
asymmetric)
	NVME="-device nvme,serial=leg1,drive=dleg1,bus=swdp2
	      -device nvme,serial=leg2,drive=dleg2,bus=rp2" ;;
unreachable)
	NVME="-device nvme,serial=leg1,drive=dleg1,bus=rp2
	      -device nvme,serial=leg2,drive=dleg2,bus=rp3" ;;
*)	echo "unknown topology: $TOPO" >&2; exit 1 ;;
esac

# virtme-ng 1.41 specifics (verified against `vng --help` + --dry-run):
#  - --qemu-opts must be ONE bundled string in the = form; a separate
#    argument starting with '-' is parsed as a new vng option.
#  - vng hands the QEMU command line to /bin/sh, so the readable
#    multi-line blocks above must be flattened to a single line first.
#  - the guest command goes via --exec (vng positional args are kernel
#    Makefile variables, not a command); %q-join preserves the argv.
#  - no `exec`: it would skip the EXIT trap that removes $SCRATCH.
#    vng propagates the guest command's exit status; hand it through.
#  - stdin from /dev/null: QEMU's console is a `-chardev stdio,signal=on`
#    backend, so with a controlling TTY on stdin it drives the terminal into
#    raw mode (tcsetattr). When a harness runs this test in a background
#    process group (e.g. `sudo ... | cat`, as the selftest runner does) that
#    tcsetattr raises SIGTTOU and QEMU is *stopped* (state T) before it boots
#    — the run then hangs until the caller's per-test timeout kills it. A
#    non-TTY stdin skips the terminal handling entirely, so detach it here.
set -f
QOPTS="$(printf '%s ' $COMMON $NVME)"
set +f
INNER="$(printf '%q ' "$@")"
rc=0
vng --run "$(uname -r)" --user root --cpus 2 --memory 2G \
	--qemu-opts="$QOPTS" \
	--exec "$INNER" </dev/null || rc=$?
exit "$rc"

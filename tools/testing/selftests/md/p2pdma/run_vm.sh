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

# vng being installed does not mean a guest can boot. Settle both remaining
# preconditions here, before anything is launched, or the retry loop below
# spends five futile boots reaching the same answer and reports it as a FAIL.
# Neither can move into lib.sh's p2p_require_rig: that also runs inside the
# guest, where there is no QEMU at all.
#
# 1. Find the emulator. virtme-ng searches PATH for `qemu-system-<arch>` then
#    `qemu-kvm`, and aborts with "cannot find qemu for x86_64" otherwise --
#    which RHEL/Rocky do, shipping it only as /usr/libexec/qemu-kvm. Resolve
#    it here, covering that layout, and pass it to vng via --qemu.
QEMU="${P2P_QEMU:-}"
if [ -z "$QEMU" ]; then
	for cand in "qemu-system-$(uname -m)" qemu-kvm \
		    "/usr/libexec/qemu-system-$(uname -m)" /usr/libexec/qemu-kvm; do
		if found="$(command -v "$cand" 2>/dev/null)"; then
			QEMU="$found"; break
		fi
	done
fi
[ -n "$QEMU" ] || {
	echo "SKIP: no QEMU for $(uname -m) in PATH or /usr/libexec (set P2P_QEMU=)" >&2
	exit 4
}
# command -v vetted the searched candidates; P2P_QEMU is taken on trust.
[ -x "$QEMU" ] || { echo "SKIP: QEMU at $QEMU is not executable" >&2; exit 4; }

# 2. Check it has the device the rig is made of -- every topology below is
#    `-device nvme,...`. RHEL's qemu-kvm carries a cut-down device list with
#    no nvme model, so it boots a guest fine and dies on the first -device.
devs="$("$QEMU" -device help 2>/dev/null)" \
	|| { echo "SKIP: $QEMU -device help failed (not a QEMU system emulator?)" >&2; exit 4; }
case "$devs" in
*'"nvme"'*) ;;
*)	echo "SKIP: $QEMU has no emulated NVMe device model (the rig needs -device nvme)" >&2
	exit 4 ;;
esac

SCRATCH="${TMPDIR:-/tmp}/p2pdma-vm.$$"; mkdir -p "$SCRATCH"
trap 'rm -rf "$SCRATCH"' EXIT
for img in cmb leg1 leg2; do
	truncate -s 64M "$SCRATCH/$img.img"
done

# The vout chardev is the test's verdict channel: the guest command's
# output and exit status go to /dev/ttyS1 (isa-serial at the standard
# COM2 resources), which QEMU writes host-side to $SCRATCH/vout.log.
# The DEFAULT console (ttyS0) is unreliable for these fast-exiting
# guests — whole streams vanish ~half the time under back-to-back
# boots, taking vng's exit-status marker with them (rc=255, zero
# bytes). A --rwdir file channel is not an option: vng implements extra
# shares via 9p, which the RHEL 10 guest kernel does not have (only
# virtiofs), and the mount fails silently.
#
# One switch with three downstream ports; extra root ports for far legs.
#
# -cpu host,vendor=GenuineIntel: the topology semantics REQUIRE the guest's
# cpu_supports_p2pdma() to be false, so that cross-host-bridge pairs resolve
# to PCI_P2PDMA_MAP_NOT_SUPPORTED (QEMU's q35 host bridge is not in the
# p2pdma whitelist). With plain `-cpu host` on an AMD >= Zen host the guest
# inherits AuthenticAMD family >= 0x17, the gate opens, and the asymmetric/
# unreachable topologies silently stop producing mapping failures (verified
# on meshstor-pc: the leg even "succeeds" while DMAing from guest-phys 0 --
# an el10 kernel bug tracked separately). Overriding only the CPUID vendor
# keeps the full host feature set (RHEL 10 userspace needs x86-64-v3, so
# feature-reduced models like qemu64 do not boot) while closing the gate on
# every host vendor.
# P2P_TOPO_CPU=host drops the vendor pin (below) so the guest keeps the
# real CPU identity: on an AMD >= Zen host that OPENS the cross-bridge
# gate — the precondition for reproducing the el10 dma_address=0 graft
# bug and for exercising the ms route fence against it. Only
# test_route_fence_el10.sh uses it; everything else needs the pin.
#
# The vendor pin has one side effect that has to be paid for right here.
# Linux picks its KVM hypercall INSTRUCTION from the CPUID vendor, so a guest
# told it is Intel emits `vmcall` (0f 01 c1). On an AMD host that instruction
# #UDs; KVM then rewrites it in place (emulator_fix_hypercall), the write
# lands on the guest's write-protected kernel text, and the guest dies:
#   BUG: unable to handle page fault for address: ffffffff...
#   #PF: supervisor write access in kernel mode
#   RIP: 0010:kvm_hypercall2...   Call Trace: kvm_kick_cpu <-
#     __pv_queued_spin_unlock_slowpath <- pci_conf1_write <- nvme_probe
# then a CPU#0 soft lockup and a panic ~62s in, leaving an EMPTY vout.log.
# That is precisely the "vng intermittently fails to launch the guest (rc=255,
# empty vout.log, silent stderr)" flake the retry loop below was built around:
# it only fires when a paravirt spinlock kick or PV IPI actually happens during
# boot, which is contention-dependent -- hence bursty under back-to-back boots
# and rare when spaced out. Measured on a Ryzen 7700X host: 5 of 10 boots dead,
# ~63s burned each; a single test could spend 146s (63 + 5 + 63 + 10 + 5) and
# blow a 120s per-test budget while actually PASSING.
#
# Disabling the paravirt features that ISSUE hypercalls removes the only code
# path that can execute the mismatched instruction. What survives is kvm-clock
# and PV EOI, which are MSR-based and never execute vmcall/vmmcall at all --
# so the guest is correct on an Intel host and an AMD host alike, and this
# needs no host detection. On an Intel host the pin was truthful and nothing
# was broken to begin with; the flags cost only paravirt tuning that a
# 3-second, 2-vCPU test VM has no use for. Verified in-guest: "kvm-guest: PV
# spinlocks disabled, no host support", no PV IPI, no async PF. The pin itself
# is untouched, so cpu_supports_p2pdma() stays false and every topology
# semantic above still holds. Measured after this change: 10 clean boots out
# of 10, 3-4s each, and the full suite green in 76s.
PV_NO_HYPERCALL="-kvm-pv-unhalt,-kvm-pv-ipi,-kvm-pv-sched-yield,-kvm-pv-tlb-flush"
CPUOPT="-cpu host,vendor=GenuineIntel,$PV_NO_HYPERCALL"
# No pin, no mismatch: an unpinned guest keeps the host's real vendor and so
# emits the instruction that host expects (`vmmcall` on AMD). Leave its
# paravirt alone. test_route_fence_el10.sh, the only user, already requires an
# AMD >= Zen HOST and skips elsewhere, so this arm never runs vendor-mismatched.
[ "${P2P_TOPO_CPU:-}" = host ] && CPUOPT="-cpu host"

COMMON="-machine q35
 $CPUOPT
 -device pcie-root-port,id=rp1,slot=1
 -device pcie-root-port,id=rp2,slot=2
 -device pcie-root-port,id=rp3,slot=3
 -device x3130-upstream,id=sw,bus=rp1
 -device xio3130-downstream,id=swdp1,bus=sw,chassis=11
 -device xio3130-downstream,id=swdp2,bus=sw,chassis=12
 -device xio3130-downstream,id=swdp3,bus=sw,chassis=13
 -chardev file,id=vout,path=$SCRATCH/vout.log
 -device isa-serial,chardev=vout,iobase=0x2f8,irq=3
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
# Route the command's output and exit status through the vout serial
# (see the chardev note above): everything lands in $SCRATCH/vout.log
# host-side, terminated by a P2PRC=<n> marker line. The trailing marker
# doubles as proof the guest command actually completed.
INNER="{ $INNER; } >/dev/ttyS1 2>&1; echo P2PRC=\$? >/dev/ttyS1"
#  - --disable-microvm: vng otherwise emits `-M microvm,...,pcie=on`;
#    our trailing `-machine q35` then switches the type while microvm's
#    pcie=on property assignment survives, and QEMU dies with
#    "Property 'pc-q35-*-machine.pcie' not found" before boot.
# vng intermittently fails to launch the guest at all under back-to-back
# boots (rc=255, empty vout.log, silent stderr; ~half the attempts on
# meshstor-pc, while spaced/solo runs are reliable). The P2PRC marker
# cleanly separates that infrastructure failure from a genuine test
# verdict -- a guest command that RAN always leaves the marker, whatever
# its exit code -- so retrying on a missing marker can never mask a real
# FAIL. The guest serial adds CRs (ONLCR); strip them on replay.
attempt=0
while :; do
	attempt=$((attempt + 1))
	: >"$SCRATCH/vout.log"
	rc=0
	vng --run "$(uname -r)" --user root --cpus 2 --memory 2G \
		--disable-microvm ${P2P_VNG_VERBOSE:+--verbose} \
		--qemu "$QEMU" \
		--qemu-opts="$QOPTS" \
		--exec "$INNER" </dev/null >/dev/null || rc=$?
	MARK="$(tail -1 "$SCRATCH/vout.log" 2>/dev/null | tr -d '\r\0')"
	case "$MARK" in
	P2PRC=*)
		sed '$d' "$SCRATCH/vout.log" | tr -d '\r\0'
		exit "${MARK#P2PRC=}"
		;;
	esac
	if [ "$attempt" -ge 5 ]; then
		echo "run_vm.sh: guest verdict never arrived after $attempt boots (last vng rc=$rc)" >&2
		exit 255
	fi
	echo "run_vm.sh: no guest verdict (vng rc=$rc), retrying boot ($attempt/5)" >&2
	sleep $((attempt * 5))	# bursty flake: back off harder each boot
done

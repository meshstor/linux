#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# el10 route-fence canary — and, on an unfenced build, the reproducer for
# the el10 DMA-graft bug itself.
#
# Every el10_2 kernel maps THRU_HOST_BRIDGE P2PDMA sg segments to
# dma_address=0 while returning success: the leg then writes guest-phys
# page 0 (IVT garbage) to media with no error status anywhere. That path
# only opens when the guest CPU satisfies cpu_supports_p2pdma() (AMD
# family >= 0x17), so this test drops run_vm.sh's GenuineIntel vendor pin
# (P2P_TOPO_CPU=host) and therefore REQUIRES an AMD >= Zen host — SKIP
# elsewhere. It also SKIPs when the built modules carry no fence (the
# p2pdma_route_fence parameter only exists on graft kernels).
#
# With the fence (dkms/patches/0013): the cross-bridge leg is never
# submitted to — its range is badblocked, the member is not faulted, the
# master write succeeds off the switch leg, and the leg's media stays
# byte-for-byte UNCHANGED (all zeroes on a fresh image; the IVT garbage
# is exactly what an unfenced build would leave there).
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
if [ -z "${P2P_IN_VM:-}" ]; then
	p2p_require_rig
	vendor="$(sed -n 's/^vendor_id[[:space:]]*: //p' /proc/cpuinfo | head -1)"
	family="$(sed -n 's/^cpu family[[:space:]]*: //p' /proc/cpuinfo | head -1)"
	[ "$vendor" = AuthenticAMD ] && [ "${family:-0}" -ge 23 ] \
		|| p2p_skip "needs an AMD >= Zen host (cpu_supports_p2pdma gate; host is $vendor family ${family:-?})"
	exec env P2P_TOPO_CPU=host "$DIR/run_vm.sh" asymmetric \
		env P2P_IN_VM=1 MS_MOD_DIR="${MS_MOD_DIR:-}" \
		MDADM="${MDADM:-}" MD_SUBSYS="${MD_SUBSYS:-}" \
		"$DIR/$(basename "$0")"
fi
p2p_require_root; p2p_require_rig
trap p2p_cleanup EXIT
p2p_load_ms_modules

FENCE_PARAM="/sys/module/$P2P_CORE_MOD/parameters/p2pdma_route_fence"
[ -f "$FENCE_PARAM" ] \
	|| p2p_skip "modules carry no route fence (not a graft kernel build)"
[ "$(cat "$FENCE_PARAM")" = "Y" ] \
	|| p2p_fail "p2pdma_route_fence unexpectedly defaults off"

grep -q AuthenticAMD /proc/cpuinfo \
	|| p2p_fail "guest lost the AMD identity — P2P_TOPO_CPU plumbing broken"

LEG1="$(p2p_nvme_by_serial leg1)"
LEG2="$(p2p_nvme_by_serial leg2)"
ARR="$(p2p_make_array 1 "$LEG1" "$LEG2")"
FILL=a5
NSEC=16   # md_p2p_test default kib=8 -> 16 sectors

RC="$(p2p_io write "$ARR" "$(p2p_bdf_by_serial cmb0)" fill=0x$FILL)"
[ "$RC" = "0" ] || p2p_fail "fenced write returned errno=$RC, want 0 (succeeds off leg1)"

OFF1="$(p2p_data_offset_sectors "$LEG1")"
OFF2="$(p2p_data_offset_sectors "$LEG2")"
[ -n "$OFF1" ] && [ -n "$OFF2" ] || p2p_fail "cannot resolve data offsets"
RD2="$(p2p_rd_dir_for_dev "$ARR" "$LEG2")" || p2p_fail "cannot find leg2's rdev sysfs dir"

p2p_raw_all_byte "$LEG1" "$OFF1" "$NSEC" "$FILL" \
	|| p2p_fail "leg1 (switch leg) does not have the written pattern"
# THE core assertion: the fenced leg's media is untouched. An unfenced
# build leaves IVT bytes (53 ff 00 f0 ...) here — the el10 bug itself.
p2p_raw_all_byte "$LEG2" "$OFF2" "$NSEC" 00 \
	|| p2p_fail "leg2 media CHANGED — fence failed, el10 graft corruption reached the disk"
p2p_bb_covers "$RD2/bad_blocks" "$OFF2" "$NSEC" \
	|| p2p_fail "leg2 badblocks do not cover the fenced range"
p2p_is_faulty "$RD2" && p2p_fail "leg2 was faulted by the fence"
p2p_wants_replacement "$RD2" && p2p_fail "leg2 got WantReplacement from the fence"
grep -q "observed=p2pdma" "$(p2p_status_file "$ARR")" \
	|| p2p_fail "p2pdma_status did not latch the fenced leg"

p2p_pass "el10 route fence: cross-bridge leg fenced (badblocked, media untouched), write succeeded off the switch leg"

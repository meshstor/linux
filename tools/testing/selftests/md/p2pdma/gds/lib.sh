# SPDX-License-Identifier: GPL-2.0
# Shared helpers for the GDS (Layer-C) p2pdma selftests and bin/gds-campaign.
# Sourced, never executed. Extends ../lib.sh (Layer-B). Exit: 0 pass 1 fail 4 skip.
set -u

GDS_DIR_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/testing/selftests/md/p2pdma/lib.sh
. "$GDS_DIR_SELF/../lib.sh"

GDS_RESULTS="${GDS_RESULTS:-/tmp/gds-results.$$}"
# repo layout: gds/ is 6 levels below the root; kit layout overrides GDS_BIN.
GDS_BIN="${GDS_BIN:-$(cd "$GDS_DIR_SELF/../../../../../.." && pwd)/bin}"
GDSIO="${GDSIO:-$(command -v gdsio || echo /usr/local/cuda/gds/tools/gdsio)}"
GDSCHECK="${GDSCHECK:-$(command -v gdscheck || echo /usr/local/cuda/gds/tools/gdscheck)}"
GDS_XFS_OPTS="noatime,nodiratime,logbufs=8,logbsize=256k,inode64,noquota"

# gds_tool NAME -> path (repo bin/ first, kit/bin via GDS_BIN, else PATH)
gds_tool() {
	if [ -x "$GDS_BIN/$1" ]; then printf '%s/%s\n' "$GDS_BIN" "$1"
	else command -v "$1"; fi
}

# gds_verdict PHASE TEST STATUS DETAIL...
gds_verdict() {
	local phase=$1 test=$2 status=$3; shift 3
	mkdir -p "$GDS_RESULTS"
	printf '%s\t%s\t%s\t%s\n' "$phase" "$test" "$status" "$*" \
		>> "$GDS_RESULTS/verdict.tsv"
}

# gds_cufile_json strict|lenient DIR -> writes DIR/cufile.json, prints path.
# strict: allow_compat_mode=false so a failed native path is a LOUD error,
# never a silent CPU bounce (spec: false-pass hazard).
gds_cufile_json() {
	local mode=$1 dir=$2 compat=false
	[ "$mode" = lenient ] && compat=true
	mkdir -p "$dir"
	cat > "$dir/cufile.json" <<JSON
{
  "logging": { "dir": "$dir", "level": "TRACE" },
  "properties": { "use_pci_p2pdma": true, "allow_compat_mode": $compat },
  "fs": {
    "generic": { "posix_unaligned_writes": false },
    "block": {
      "nvme":   { "use_pci_p2pdma": true },
      "nvmeof": { "use_pci_p2pdma": true },
      "raid":   { "use_pci_p2pdma": true }
    }
  }
}
JSON
	printf '%s/cufile.json\n' "$dir"
}

# gds_csi_mdadm_create DEV LEVEL MEMBER... [-- EXTRA...]
# The exact meshstor-csi array shape (meshstor-csi internal/mdraid/mdraid.go):
# metadata 1.2, internal bitmap @128M chunk, consistency-policy bitmap,
# failfast, assume-clean, homehost=any; raid10 adds --chunk=64 --layout=n2.
# EXTRA args (after --) are inserted before --run (e.g. --size=131072).
gds_csi_mdadm_create() {
	local dev=$1 level=$2; shift 2
	local members=() extra=()
	while [ $# -gt 0 ]; do
		if [ "$1" = -- ]; then shift; extra=("$@"); break; fi
		members+=("$1"); shift
	done
	local lvlextra=()
	[ "$level" = 10 ] && lvlextra=(--chunk=64 --layout=n2)
	local _m
	for _m in "${members[@]}"; do
		[ -b "$_m" ] && "$MDADM" --zero-superblock "$_m" >/dev/null 2>&1 || true
	done
	"$MDADM" --create "$dev" --level="$level" --raid-devices="${#members[@]}" \
		--metadata=1.2 --homehost=any --assume-clean \
		--bitmap=internal --bitmap-chunk=128M --consistency-policy=bitmap \
		--failfast "${lvlextra[@]}" "${extra[@]}" --run "${members[@]}"
}

# gds_data_offset_sectors MEMBER -> 1.2 superblock data offset (sectors)
gds_data_offset_sectors() {
	"$MDADM" --examine "$1" | awk '/Data Offset/ {print $4; exit}'
}

# gds_mkfs_mount DEV MNT — XFS with the CSI mount options
gds_mkfs_mount() {
	mkfs.xfs -f -q "$1" || return 1
	mkdir -p "$2"
	mount -t xfs -o "$GDS_XFS_OPTS" "$1" "$2"
}

# gds_cmp_legs PATFILE BYTES MEMBER... — every leg's data area must equal PATFILE
gds_cmp_legs() {
	local pat=$1 bytes=$2 m off
	shift 2
	for m in "$@"; do
		off=$(gds_data_offset_sectors "$m")
		[ -n "$off" ] || { echo "no data offset for $m" >&2; return 1; }
		cmp -n "$bytes" --ignore-initial=0:$((off * 512)) "$pat" "$m" \
			|| { echo "leg $m diverges from pattern" >&2; return 1; }
	done
}

# ---------------------------------------------------------------------------
# Loopback NVMe-oF: the single-node stand-in for the CSI's remote leg.
# Target = nvmet configfs on this node; initiator = nvme connect to self with
# the CSI's exact flags (meshstor-csi internal/nvmeof/host.go).
GDS_NVMET_NQN=""
GDS_NVMET_PORT_ID=7431          # unlikely to collide with a real deployment
GDS_REMOTE_DEVS=()
GDS_NVMET_BACKING=()            # local DEV args passed to gds_nvmet_export
GDS_MNT="${GDS_MNT:-/mnt/gds-test}"

# first IPv4 on an RDMA-capable netdev (hw NIC or rxe); rc 1 if none
gds_rdma_addr() {
	local ibdev netdev addr
	for ibdev in /sys/class/infiniband/*; do
		[ -e "$ibdev" ] || continue
		for netdev in "$ibdev"/device/net/*; do
			[ -e "$netdev" ] || continue
			addr=$(ip -4 -o addr show dev "$(basename "$netdev")" \
				| awk '{print $4}' | cut -d/ -f1 | head -1)
			[ -n "$addr" ] && { echo "$addr"; return 0; }
		done
	done
	return 1
}

# gds_nvmet_disarm_incremental DEV... -- every DEV is an ephemeral loopback
# namespace (e.g. /dev/nvme3n1). Its every re-connect is a fresh block-device
# "add" uevent, which races the distro's in-tree md incremental-assembly rule
# (system mdadm, *not* our ms_* stack) if the device still carries an mdadm
# 1.2 superblock from a prior test run -- observed live as the loopback
# namespace getting auto-grabbed into a stray upstream /dev/mdN out from
# under us before gds_csi_mdadm_create runs (surfaces as a spurious "array
# create failed", plus a dangling nvme-subsystem sysfs entry after disconnect
# because md still holds the namespace open). Stop any such array so the rest
# of the test (and the next run) gets a clean device.
gds_nvmet_disarm_incremental() {
	local dev bn mdn
	for dev in "$@"; do
		bn=$(basename "$dev")
		mdn=$(awk -v d="$bn" '$1 ~ /^md[0-9]+$/ { for (i=3;i<=NF;i++) if ($i ~ ("^" d "\\[")) { print $1; exit } }' /proc/mdstat 2>/dev/null)
		[ -n "$mdn" ] && mdadm --stop "/dev/$mdn" >/dev/null 2>&1 || true
	done
}

# gds_nvmet_export TRANSPORT DEV...  (TRANSPORT: tcp|rdma)
gds_nvmet_export() {
	local tr=$1; shift
	if [ -n "$GDS_NVMET_NQN" ]; then
		echo "gds_nvmet_export: prior export ($GDS_NVMET_NQN) still active -- call gds_nvmet_teardown first" >&2
		return 1
	fi
	local addr port i=1 dev
	modprobe nvmet "nvmet-$tr" nvme-fabrics "nvme-$tr" 2>/dev/null || true
	[ -d /sys/kernel/config/nvmet ] || { echo "SKIP: nvmet configfs unavailable" >&2; exit 4; }
	case "$tr" in
		tcp)  addr=127.0.0.1; port=4420;;
		rdma) addr=$(gds_rdma_addr) || { echo "SKIP: no RDMA-capable address" >&2; exit 4; }
		      port=4421;;
		*) echo "gds_nvmet_export: bad transport '$tr'" >&2; return 1;;
	esac
	GDS_NVMET_NQN="nqn.2025-12.io.meshstor:$tr:gdstest:$(hostname -s)"
	GDS_NVMET_BACKING=("$@")
	local ss=/sys/kernel/config/nvmet/subsystems/$GDS_NVMET_NQN
	mkdir -p "$ss" && echo 1 > "$ss/attr_allow_any_host"
	for dev in "$@"; do
		mkdir -p "$ss/namespaces/$i"
		echo -n "$dev" > "$ss/namespaces/$i/device_path"
		echo 1 > "$ss/namespaces/$i/enable"
		i=$((i + 1))
	done
	local p=/sys/kernel/config/nvmet/ports/$GDS_NVMET_PORT_ID
	mkdir -p "$p"
	echo "$tr"   > "$p/addr_trtype"
	echo ipv4    > "$p/addr_adrfam"
	echo "$addr" > "$p/addr_traddr"
	echo "$port" > "$p/addr_trsvcid"
	ln -s "$ss" "$p/subsystems/$GDS_NVMET_NQN"
	# CSI connect flags (nr-io-queues, aggressive timeouts). NOTE: the CSI Go
	# code (meshstor-csi internal/nvmeof/host.go) also passes
	# --fast_io_fail_tmo=1, but this nvme-cli (2.8, libnvme 1.8) has no such
	# option under any spelling (confirmed via `nvme connect --help` and
	# `strings` on the binary -- only --ctrl-loss-tmo is compiled in), so it
	# is omitted here; --ctrl-loss-tmo alone governs path-failure teardown.
	if ! nvme connect --transport "$tr" --traddr "$addr" --trsvcid "$port" \
		--nqn "$GDS_NVMET_NQN" \
		--hostnqn "nqn.2025-12.io.meshstor:$(hostname -s)" \
		--nr-io-queues=16 --keep-alive-tmo=1 \
		--ctrl-loss-tmo=3 --reconnect-delay=1 >/dev/null 2>&1; then
		gds_nvmet_teardown
		echo "SKIP: nvme connect ($tr) failed" >&2; exit 4
	fi
	# resolve initiator-side namespaces (NSID order == DEV order). NOTE: with
	# native NVMe multipathing on (nvme_core.multipath=Y, common default),
	# a fabrics namespace is split into a *hidden* per-controller-path device
	# (nvme<ctrl>c<ctrl>n<nsid>, no /dev node -- "hidden" sysfs attr = 1) and
	# a separate "head" device the kernel actually creates /dev/nvme<X>n<Y>
	# for, filed under /sys/class/nvme-subsystem/nvme-subsysN/ instead of
	# under the controller. Private (non-fabric, single-path) namespaces,
	# e.g. local PCIe test partitions, skip that split and stay directly
	# under the controller. So probe both locations and skip hidden ones.
	local want=$(( i - 1 )) tries c ctrl="" sd ns cand cands
	for tries in $(seq 100); do
		for c in /sys/class/nvme/nvme*; do
			[ -e "$c/subsysnqn" ] || continue
			[ "$(cat "$c/subsysnqn" 2>/dev/null)" = "$GDS_NVMET_NQN" ] && { ctrl=$c; break; }
		done
		if [ -n "$ctrl" ]; then
			sd=""
			for c in /sys/class/nvme-subsystem/*; do
				[ -e "$c/subsysnqn" ] || continue
				[ "$(cat "$c/subsysnqn" 2>/dev/null)" = "$GDS_NVMET_NQN" ] && { sd=$c; break; }
			done
			cands=("$ctrl"/nvme*n*)
			[ -n "$sd" ] && cands+=("$sd"/nvme*n*)
			GDS_REMOTE_DEVS=()
			for i in $(seq "$want"); do
				ns=""
				for cand in "${cands[@]}"; do
					[ -f "$cand/nsid" ] || continue
					[ "$(cat "$cand/nsid" 2>/dev/null)" = "$i" ] || continue
					[ "$(cat "$cand/hidden" 2>/dev/null || echo 0)" = 1 ] && continue
					ns=$cand; break
				done
				[ -n "$ns" ] && GDS_REMOTE_DEVS+=("/dev/$(basename "$ns")")
			done
			if [ "${#GDS_REMOTE_DEVS[@]}" -eq "$want" ]; then
				gds_nvmet_disarm_incremental "${GDS_REMOTE_DEVS[@]}"
				return 0
			fi
		fi
		sleep 0.2
	done
	gds_nvmet_teardown
	echo "SKIP: loopback namespaces never appeared" >&2; exit 4
}

gds_nvmet_teardown() {
	[ -n "$GDS_NVMET_NQN" ] || return 0
	[ "${#GDS_REMOTE_DEVS[@]}" -gt 0 ] && gds_nvmet_disarm_incremental "${GDS_REMOTE_DEVS[@]}"
	nvme disconnect -n "$GDS_NVMET_NQN" >/dev/null 2>&1 || true
	local p=/sys/kernel/config/nvmet/ports/$GDS_NVMET_PORT_ID
	local ss=/sys/kernel/config/nvmet/subsystems/$GDS_NVMET_NQN
	rm -f "$p/subsystems/$GDS_NVMET_NQN" 2>/dev/null || true
	rmdir "$p" 2>/dev/null || true
	if [ -d "$ss" ]; then
		local n
		for n in "$ss"/namespaces/*; do
			[ -d "$n" ] && { echo 0 > "$n/enable" 2>/dev/null; rmdir "$n" 2>/dev/null; }
		done
		rmdir "$ss" 2>/dev/null || true
	fi
	# Belt-and-suspenders for the incremental-assembly race described above
	# gds_nvmet_disarm_incremental: also erase the superblock on the local
	# backing device so a stray upstream array has nothing left to grab on
	# the *next* run, instead of relying solely on the just-in-time disarm.
	local b
	for b in "${GDS_NVMET_BACKING[@]}"; do
		[ -n "$b" ] && [ -e "$b" ] && "$MDADM" --zero-superblock "$b" >/dev/null 2>&1 || true
	done
	GDS_NVMET_NQN=""; GDS_REMOTE_DEVS=(); GDS_NVMET_BACKING=()
}

gds_teardown() {
	mountpoint -q "$GDS_MNT" 2>/dev/null && umount "$GDS_MNT" 2>/dev/null
	p2pdma_teardown
	gds_nvmet_teardown
}

# ---------------------------------------------------------------------------
# GDS I/O battery (needs gdsio + a GPU; callers SKIP via gds_require_gdsio)
gds_require_gdsio() {
	[ -x "$GDSIO" ] || { echo "SKIP: gdsio not found (set GDSIO=)" >&2; exit 4; }
}

# gds_gdsio_write MNT MODE JSON   (MODE: 0=GDS, 1=POSIX-through-CPU)
gds_gdsio_write() {
	local mnt=$1 mode=$2 json=$3
	mkdir -p "$GDS_RESULTS"
	CUFILE_ENV_PATH_JSON="$json" "$GDSIO" -f "$mnt/gds-test.bin" \
		-d 0 -w 4 -s 256M -i 1M -x "$mode" -I 1 \
		> "$GDS_RESULTS/gdsio-w.out" 2>&1
}

# gds_gdsio_readverify MNT JSON — read back with verification
gds_gdsio_readverify() {
	local mnt=$1 json=$2
	CUFILE_ENV_PATH_JSON="$json" "$GDSIO" -f "$mnt/gds-test.bin" \
		-d 0 -w 4 -s 256M -i 1M -x 0 -I 0 -V \
		> "$GDS_RESULTS/gdsio-r.out" 2>&1
}

# gds_sha_direct FILE -> sha256 via CPU O_DIRECT read (page cache dropped)
gds_sha_direct() {
	sync; echo 3 > /proc/sys/vm/drop_caches
	( set -o pipefail; dd if="$1" bs=1M iflag=direct status=none | sha256sum | awk '{print $1}' )
}

# gds_leg_sha MEMBER RELPATH -> sha256 of RELPATH on that leg's filesystem
# (loop at data offset, ro,nouuid so both legs of a mirror mount cleanly)
gds_leg_sha() {
	local member=$1 rel=$2 off lo mnt sha
	off=$(gds_data_offset_sectors "$member") || return 1
	lo=$(losetup --find --show -r -o $((off * 512)) "$member") || return 1
	mnt=$(mktemp -d)
	if ! mount -t xfs -o ro,nouuid "$lo" "$mnt" 2>/dev/null; then
		losetup -d "$lo"; rmdir "$mnt"; return 1
	fi
	sha=$(set -o pipefail; sha256sum "$mnt/$rel" | awk '{print $1}')
	umount "$mnt"; losetup -d "$lo"; rmdir "$mnt"
	echo "$sha"
}

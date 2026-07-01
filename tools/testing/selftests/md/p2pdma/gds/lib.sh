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

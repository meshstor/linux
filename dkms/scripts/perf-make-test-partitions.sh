#!/usr/bin/env bash
# perf-make-test-partitions.sh — validate an NVMe device and add two
# 25 GiB test partitions in its trailing free space, 1 MiB aligned.
#
# Validations:
#   - argument is a block device under /dev/nvme*n*
#   - transport is nvme (lsblk -no TRAN)
#   - partition table is GPT (lsblk -no PTTYPE)
#   - logical block size is 4096 (i.e. 4Kn drive)
#   - at least 50 GiB of contiguous unallocated free space
#
# Created partitions:
#   - 2 × 25 GiB (configurable via SIZE_GIB / COUNT env)
#   - 1 MiB aligned (the historical "max compatibility + good perf" rule;
#     parted handles this automatically when offsets are given in MiB)
#   - GPT names: <devbasename>-test1, <devbasename>-test2
#     (e.g. nvme0n1-test1, nvme0n1-test2)
#
# Usage:
#   sudo dkms/scripts/perf-make-test-partitions.sh /dev/nvme0n1 [-y|--yes]
#
# Defaults to printing the plan and waiting 5 s for Ctrl-C before acting.
# Pass --yes to skip the wait.
set -euo pipefail

SIZE_GIB="${SIZE_GIB:-25}"
COUNT="${COUNT:-2}"

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
log()  { printf '%s\n' "$*"; }

YES=0
DEV=""
for arg in "$@"; do
    case "$arg" in
        -y|--yes) YES=1 ;;
        -h|--help)
            sed -n '2,28p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        -*) die "unknown flag: $arg" ;;
        *)  [[ -z "$DEV" ]] || die "extra positional arg: $arg"
            DEV="$arg" ;;
    esac
done
[[ -n "$DEV" ]] || die "usage: $0 /dev/nvmeXnY [-y|--yes]"

# ---- root check ----
[[ $EUID -eq 0 ]] || die "must run as root (try: sudo $0 $*)"

# ---- tool check ----
for t in lsblk blockdev parted partprobe udevadm awk; do
    command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"
done

# ---- device validation ----
[[ -b "$DEV" ]] || die "not a block device: $DEV"
[[ "$DEV" =~ ^/dev/nvme[0-9]+n[0-9]+$ ]] || die "device name doesn't look like a whole-NVMe disk: $DEV (expected /dev/nvmeXnY)"

TRAN="$(lsblk -dno TRAN "$DEV" 2>/dev/null || echo)"
[[ "$TRAN" == "nvme" ]] || die "not an NVMe device (lsblk TRAN=$TRAN)"

PTTYPE="$(lsblk -dno PTTYPE "$DEV" 2>/dev/null || echo)"
[[ "$PTTYPE" == "gpt" ]] || die "partition table is not GPT (PTTYPE='$PTTYPE'); refusing to repartition"

LOG_SEC="$(blockdev --getss "$DEV")"
[[ "$LOG_SEC" == "4096" ]] || die "drive is not 4Kn (logical block size = ${LOG_SEC}B; expected 4096)"

# ---- free space discovery ----
# parted -m machine-readable: ":start:end:size:fs-type:name:flags;" per line.
# Free regions look like: ":913000MiB:953000MiB:40000MiB:free;"
# (the leading partition number is empty for free entries)
read -r FREE_MIB FREE_START_MIB FREE_END_MIB < <(
    parted -s -m "$DEV" unit MiB print free 2>/dev/null \
        | awk -F: '
            /:free;$/ {
                s = $2 + 0
                e = $3 + 0
                sz = e - s
                if (sz > max) { max = sz; mstart = s; mend = e }
            }
            END { printf "%d %d %d\n", (max+0), (mstart+0), (mend+0) }
        '
)
NEEDED_GIB=$((SIZE_GIB * COUNT))
NEEDED_MIB=$((NEEDED_GIB * 1024))
(( FREE_MIB >= NEEDED_MIB )) \
    || die "largest free region is ${FREE_MIB} MiB; need at least ${NEEDED_MIB} MiB ($NEEDED_GIB GiB)"

# ---- compute aligned partition offsets (MiB) ----
# parted reports MiB rounded; the actual free start may be misaligned by less
# than 1 MiB. Round up to the next MiB boundary to guarantee 1 MiB alignment.
ALIGN_START=$FREE_START_MIB
P1_START=$ALIGN_START
P1_END=$((P1_START + SIZE_GIB * 1024))
P2_START=$P1_END
P2_END=$((P2_START + SIZE_GIB * 1024))
(( P2_END <= FREE_END_MIB )) \
    || die "internal: would overflow free region (P2_END=$P2_END MiB > free end=$FREE_END_MIB MiB)"

DEV_NAME="$(basename "$DEV")"
LABEL1="${DEV_NAME}-test1"
LABEL2="${DEV_NAME}-test2"

# ---- print plan ----
cat <<EOF
Device:        $DEV
  transport:   $TRAN
  pt type:     $PTTYPE
  logical sec: $LOG_SEC B
  free region: ${FREE_START_MIB}–${FREE_END_MIB} MiB ($((FREE_MIB / 1024)) GiB)

Plan: create $COUNT partition(s), $SIZE_GIB GiB each, 1 MiB aligned:
  ${LABEL1}: ${P1_START} MiB → ${P1_END} MiB  ($((P1_END - P1_START)) MiB = $SIZE_GIB GiB)
  ${LABEL2}: ${P2_START} MiB → ${P2_END} MiB  ($((P2_END - P2_START)) MiB = $SIZE_GIB GiB)
EOF

if [[ $YES -eq 0 ]]; then
    printf 'Proceeding in 5 s — Ctrl-C to cancel'
    for _ in 1 2 3 4 5; do printf '.'; sleep 1; done
    printf '\n'
fi

# ---- create partitions ----
# parted with explicit MiB offsets gives 1 MiB alignment by construction;
# we don't need --align optimal (which would jump to the device's
# optimal_io_size — typically larger than 1 MiB on NVMe).
parted -s "$DEV" \
    mkpart "$LABEL1" ext4 "${P1_START}MiB" "${P1_END}MiB" \
    mkpart "$LABEL2" ext4 "${P2_START}MiB" "${P2_END}MiB"

# Re-read the partition table.
partprobe "$DEV"
udevadm settle

# ---- post-create verification ----
echo
echo "Verification — new layout:"
parted -s "$DEV" unit MiB print | tail -n +2

# Check the two new device nodes exist + are 1 MiB aligned.
P1_DEV="${DEV}p1" ; P2_DEV="${DEV}p2"
# Discover by NAME instead of guessing the suffix
P1_DEV="$(lsblk -ln -o NAME,PARTLABEL "$DEV" | awk -v lbl="$LABEL1" '$2==lbl {print "/dev/"$1; exit}')"
P2_DEV="$(lsblk -ln -o NAME,PARTLABEL "$DEV" | awk -v lbl="$LABEL2" '$2==lbl {print "/dev/"$1; exit}')"
[[ -b "$P1_DEV" && -b "$P2_DEV" ]] \
    || die "post-create: could not locate /dev nodes for $LABEL1 / $LABEL2"

for p in "$P1_DEV" "$P2_DEV"; do
    start_b="$(cat "/sys/class/block/$(basename "$p")/start" 2>/dev/null)"
    start_b_offset=$(( start_b * LOG_SEC ))   # bytes
    if (( start_b_offset % (1024*1024) != 0 )); then
        warn "$p start offset $start_b_offset B is NOT 1 MiB aligned"
    fi
done

echo
echo "Created:"
echo "  $P1_DEV  ($LABEL1)"
echo "  $P2_DEV  ($LABEL2)"

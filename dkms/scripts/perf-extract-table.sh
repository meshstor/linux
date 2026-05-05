#!/usr/bin/env bash
# perf-extract-table.sh — extract a markdown comparison table from a
# perf-feature-compare.sh results directory.
#
# Usage:
#   dkms/scripts/perf-extract-table.sh <results-base-dir> [variant ...]
#
# Where <results-base-dir> contains per-variant subdirs, each with
# results/<suite>/run.log files (fio --output-format=json).
# If no variants are given, walks every subdir that has a results/ dir.
#
# Robust against fio run.log files that have leading non-JSON lines
# (e.g., "open path: No such file or directory" from drop_caches plumbing
# on hosts with nvme_core.multipath=Y) — strips everything before the
# first '{' before passing to jq.
set -euo pipefail

usage() {
    sed -n '2,11p' "$0" | sed 's/^# \?//'
    exit 2
}

if (($# < 1)) || [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
fi

BASE="$1"; shift
[[ -d "$BASE" ]] || { echo "error: not a directory: $BASE" >&2; exit 1; }

# Discover variants if not specified.
if (($# > 0)); then
    VARIANTS=("$@")
else
    VARIANTS=()
    for d in "$BASE"/*/; do
        [[ -d "$d/results" ]] || continue
        VARIANTS+=("$(basename "${d%/}")")
    done
fi

if (( ${#VARIANTS[@]} == 0 )); then
    echo "error: no variants found under $BASE" >&2
    exit 1
fi

# Discover suites — union of all suite-named subdirs across variants.
declare -A _suite_seen
SUITES=()
for v in "${VARIANTS[@]}"; do
    [[ -d "$BASE/$v/results" ]] || continue
    for d in "$BASE/$v/results"/*/; do
        [[ -d "$d" ]] || continue
        s="$(basename "${d%/}")"
        if [[ -z "${_suite_seen[$s]:-}" ]]; then
            _suite_seen[$s]=1
            SUITES+=("$s")
        fi
    done
done
unset _suite_seen

# Extract iops + p99 from one run.log. Echoes "iops|p99" or "-|-" on miss.
# Reads either .read or .write (whichever is non-zero), so the same call
# works for randread and randwrite suites.
extract() {
    local f="$1"
    [[ -f "$f" ]] || { echo "-|-"; return; }
    local out
    out=$(sed -n '/^{/,$p' "$f" 2>/dev/null \
          | jq -r '
              .jobs[0] as $j |
              ($j.read.iops + $j.write.iops | floor) as $iops |
              ((($j.read.clat_ns.percentile."99.000000" // 0)
              + ($j.write.clat_ns.percentile."99.000000" // 0)) / 1000 | floor) as $p99 |
              "\($iops)|\($p99)"
          ' 2>/dev/null) || out=""
    [[ -z "$out" ]] && out="-|-"
    echo "$out"
}

# Header
{
    echo "# Per-Feature Perf Comparison"
    echo ""
    echo "Source: \`$BASE\`"
    echo ""
    for s in "${SUITES[@]}"; do
        echo "## $s"
        echo ""
        echo "| Variant | IOPS | p99 lat (us) |"
        echo "|---|---:|---:|"
        for v in "${VARIANTS[@]}"; do
            f="$BASE/$v/results/$s/run.log"
            res="$(extract "$f")"
            iops="${res%|*}"
            p99="${res#*|}"
            echo "| $v | $iops | $p99 |"
        done
        echo ""
    done
}

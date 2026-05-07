#!/usr/bin/env bash
# perf-extract-table.sh — render a unicode-box comparison table from a
# perf-feature-compare.sh results directory. Baseline row shows absolute
# values (iops + mean clat + p99 clat); other variants show percent
# delta vs baseline for all three.
#
# Mean is load-bearing for the latency-ewma branch: with asymmetric legs,
# baseline ~50/50 routing → mean ≈ midpoint of the two leg latencies;
# EWMA pinned to fast leg → mean ≈ fast-leg latency. p99 looks similar
# in both cases (occasional slow-leg routes), so mean is the headline.
#
# Usage:
#   dkms/scripts/perf-extract-table.sh [--dot] <results-base-dir> [variant ...]
#
# When variant args are omitted, walks every subdir of <results-base-dir>
# that has a results/ child; baseline (if present) is placed first.
#
# --dot replaces any percent-delta cell number whose absolute value is
# below 1% with "." — visual noise reduction for runs that are within
# baseline jitter.
#
# Robust against fio run.log files that have leading non-JSON lines
# (e.g., "open path: No such file or directory" from drop_caches plumbing
# on hosts with nvme_core.multipath=Y) — strips everything before the
# first '{' before passing to jq.
set -euo pipefail

DOT=0
_args=()
for _a in "$@"; do
    case "$_a" in
        --dot) DOT=1 ;;
        *) _args+=("$_a") ;;
    esac
done
set -- ${_args[@]+"${_args[@]}"}
unset _args _a

if (($# < 1)) || [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    sed -n '2,20p' "$0" | sed 's/^# \?//'
    exit 2
fi

BASE="$1"; shift
[[ -d "$BASE" ]] || { echo "error: not a directory: $BASE" >&2; exit 1; }

# ---- variant + suite discovery ----
if (($# > 0)); then
    VARIANTS=("$@")
else
    VARIANTS=()
    [[ -d "$BASE/baseline/results" ]] && VARIANTS+=(baseline)
    for d in "$BASE"/*/; do
        n="$(basename "${d%/}")"
        [[ "$n" == "baseline" ]] && continue
        [[ -d "$d/results" ]] && VARIANTS+=("$n")
    done
fi
(( ${#VARIANTS[@]} > 0 )) || { echo "error: no variants under $BASE" >&2; exit 1; }

# Suite enumeration: from baseline if present, else from the first variant.
discover_from=""
for v in "${VARIANTS[@]}"; do
    [[ -d "$BASE/$v/results" ]] && { discover_from="$v"; break; }
done
[[ -n "$discover_from" ]] || { echo "error: no results/ subdir found" >&2; exit 1; }

# Discover suites; respect a canonical order (matches perf-feature-compare's
# DEFAULT_SUITES) so iops cols come before lat cols and read before write.
# Unknown suites land at the end in lsblk-glob order.
declare -A _seen
DISCOVERED=()
for d in "$BASE/$discover_from/results"/*/; do
    [[ -d "$d" ]] || continue
    DISCOVERED+=("$(basename "${d%/}")")
done
PREFERRED_ORDER=(
    snia-randread-iops
    snia-randwrite-iops
    snia-randread-lat
    snia-randwrite-lat
    kp-asym-read
    kp-hot-region-write
    kp-hot-region-largeio-write
    kp-bucket-contention-write
)
SUITES=()
for s in "${PREFERRED_ORDER[@]}"; do
    for d in "${DISCOVERED[@]}"; do
        if [[ "$d" == "$s" ]]; then
            SUITES+=("$s"); _seen[$s]=1; break
        fi
    done
done
for d in "${DISCOVERED[@]}"; do
    [[ -z "${_seen[$d]:-}" ]] && SUITES+=("$d")
done
unset _seen DISCOVERED
(( ${#SUITES[@]} > 0 )) || { echo "error: no suites under $BASE/$discover_from/results/" >&2; exit 1; }

# ---- extraction + formatting ----

# Echo "iops mean_us p99_us"; all 0 if file missing/unparseable.
# Sums read+write fields — for our pure-read or pure-write suites only
# one side is non-zero; would be misleading for randrw mixes (none in
# default).
extract_raw() {
    local f="$1"
    if [[ ! -f "$f" ]]; then echo "0 0 0"; return; fi
    local out
    # sed strips leading non-JSON; awk strips the per-rdev trailer
    # (ewma-asymmetric-read appends `==== per-rdev latency_ewma_ns ...`
    # after its fio JSON, which would crash jq otherwise). grep strips
    # `[run] ...` runner echoes interleaved between back-to-back fio
    # JSON blobs (e.g., snia-randwrite-lat does WDPC then measurement,
    # producing two JSON objects with a `[run] measurement: ...` line
    # in between). Without that strip, jq parses the first object then
    # chokes on the `[run]` line. jq -s slurps the resulting stream
    # into an array and `.[-1]` selects the final measurement object,
    # discarding any preconditioning runs.
    out="$(sed -n '/^{/,$p' "$f" 2>/dev/null \
           | awk '/^==== per-rdev/{exit} 1' \
           | grep -v '^\[' \
           | jq -s -r '
               .[-1].jobs[0] as $j |
               (($j.read.iops + $j.write.iops)) as $iops |
               ((($j.read.clat_ns.mean // 0)
               + ($j.write.clat_ns.mean // 0)) / 1000) as $mean |
               ((($j.read.clat_ns.percentile."99.000000" // 0)
               + ($j.write.clat_ns.percentile."99.000000" // 0)) / 1000) as $p99 |
               "\($iops) \($mean) \($p99)"
           ' 2>/dev/null)" || out=""
    [[ -z "$out" ]] && out="0 0 0"
    echo "$out"
}

fmt_iops() {
    awk -v v="$1" 'BEGIN {
        if (v >= 100000) printf "%dk", int(v/1000 + 0.5)
        else if (v >= 10000) printf "%.1fk", v/1000
        else if (v >= 1000) printf "%.2fk", v/1000
        else printf "%d", v
    }'
}
fmt_lat_us() {
    awk -v v="$1" 'BEGIN {
        if (v >= 1000) {
            s = sprintf("%.2f", v/1000)
            sub(/\.?0+$/, "", s)
            printf "%sms", s
        } else {
            printf "%dus", int(v + 0.5)
        }
    }'
}
fmt_pct() {
    awk -v v="$1" -v dot="$DOT" 'BEGIN {
        av = (v < 0) ? -v : v
        if (dot == "1" && av < 1) { printf "."; exit }
        sign = (v >= 0) ? "+" : ""
        s = sprintf("%s%.2f", sign, v)
        sub(/\.?0+$/, "", s)
        printf "%s%%", s
    }'
}

# Suite labels: strip "snia-" prefix, append " (qd=1)" to lat suites.
SUITE_LABELS=()
for s in "${SUITES[@]}"; do
    label="${s#snia-}"
    case "$label" in
        *-lat) label="$label (qd=1)" ;;
    esac
    SUITE_LABELS+=("$label")
done

# Capture baseline values for delta calc.
declare -A BASE_IOPS BASE_MEAN BASE_P99
if [[ -d "$BASE/baseline/results" ]]; then
    for s in "${SUITES[@]}"; do
        read -r i m p < <(extract_raw "$BASE/baseline/results/$s/run.log")
        BASE_IOPS[$s]="$i"
        BASE_MEAN[$s]="$m"
        BASE_P99[$s]="$p"
    done
fi

# Build the cell matrix: CELL[variant|suite] -> display string.
declare -A CELL
for v in "${VARIANTS[@]}"; do
    for s in "${SUITES[@]}"; do
        f="$BASE/$v/results/$s/run.log"
        read -r iops mean p99 < <(extract_raw "$f")
        if [[ "$v" == "baseline" ]]; then
            if [[ "$iops" == "0" && "$p99" == "0" ]]; then
                CELL[$v|$s]="-"
            else
                CELL[$v|$s]="$(fmt_iops "$iops") / $(fmt_lat_us "$mean") / $(fmt_lat_us "$p99")"
            fi
        else
            local_base_iops="${BASE_IOPS[$s]:-0}"
            local_base_mean="${BASE_MEAN[$s]:-0}"
            local_base_p99="${BASE_P99[$s]:-0}"
            if [[ "$iops" == "0" && "$p99" == "0" ]]; then
                CELL[$v|$s]="-"
            elif [[ "$local_base_iops" == "0" \
                 || "$local_base_mean" == "0" \
                 || "$local_base_p99"  == "0" ]]; then
                # No baseline to diff against — show absolutes.
                CELL[$v|$s]="$(fmt_iops "$iops") / $(fmt_lat_us "$mean") / $(fmt_lat_us "$p99")"
            else
                pct_i="$(awk -v a="$iops" -v b="$local_base_iops" 'BEGIN {print (a-b)*100/b}')"
                pct_m="$(awk -v a="$mean" -v b="$local_base_mean" 'BEGIN {print (a-b)*100/b}')"
                pct_p="$(awk -v a="$p99"  -v b="$local_base_p99"  'BEGIN {print (a-b)*100/b}')"
                CELL[$v|$s]="$(fmt_pct "$pct_i") / $(fmt_pct "$pct_m") / $(fmt_pct "$pct_p")"
            fi
        fi
    done
done

# ---- rendering (unicode box) ----

# Column widths (col 0 = variant name, then 1 per suite).
N=$((1 + ${#SUITES[@]}))
declare -a W
header_v="Variant"
W[0]=${#header_v}
for v in "${VARIANTS[@]}"; do
    (( ${#v} > W[0] )) && W[0]=${#v}
done
for ((j=1; j<N; j++)); do
    s="${SUITES[$((j-1))]}"
    label="${SUITE_LABELS[$((j-1))]}"
    W[$j]=${#label}
    for v in "${VARIANTS[@]}"; do
        cell="${CELL[$v|$s]}"
        (( ${#cell} > W[$j] )) && W[$j]=${#cell}
    done
done

draw_sep() {
    local left="$1" mid="$2" right="$3"
    printf "%s" "$left"
    for ((j=0; j<N; j++)); do
        local k
        for ((k=0; k<W[$j]+2; k++)); do printf "─"; done
        if (( j < N-1 )); then printf "%s" "$mid"; else printf "%s\n" "$right"; fi
    done
}
draw_row() {
    # $1 is the variant column (left-aligned); $2..$N are data (right-aligned).
    printf "│ %-*s │" "${W[0]}" "$1"
    shift
    local j=1
    for cell in "$@"; do
        printf " %*s │" "${W[$j]}" "$cell"
        ((j++))
    done
    printf "\n"
}

draw_sep "┌" "┬" "┐"
draw_row "Variant" "${SUITE_LABELS[@]}"
draw_sep "├" "┼" "┤"
for ((vi=0; vi<${#VARIANTS[@]}; vi++)); do
    v="${VARIANTS[$vi]}"
    cells=()
    for s in "${SUITES[@]}"; do cells+=("${CELL[$v|$s]}"); done
    draw_row "$v" "${cells[@]}"
    (( vi < ${#VARIANTS[@]}-1 )) && draw_sep "├" "┼" "┤"
done
draw_sep "└" "┴" "┘"

#!/usr/bin/env bash
# perf-feature-compare.sh — orchestrate raid1 perf comparison across
# baseline + 4 single-feature meshstor-ms variants.
#
# Spec: docs/superpowers/specs/2026-05-05-perf-feature-comparison-design.md
# Plan: docs/superpowers/plans/2026-05-05-perf-feature-comparison.md
#
# Usage: sudo dkms/scripts/perf-feature-compare.sh PART_LOCAL PART_REMOTE [VARIANT ...]
set -euo pipefail

die() { echo "$*" 1>&2; exit 1; }

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
REBUILD_MAIN="$REPO_ROOT/dkms/scripts/rebuild-main"
BUILD_TARBALL="$REPO_ROOT/dkms/scripts/build-tarball.sh"
RUN_PERF="$REPO_ROOT/dkms/scripts/run-perf-bench-tcp.sh"
REBUILT_TREE="${REBUILT_TREE:-$(dirname "$REPO_ROOT")/linux-meshstor-rebuilt}"
MDADM_BIN="${MDADM_BIN:-/home/$SUDO_USER/mdadm/mdadm}"
MSADM_WRAPPER="/tmp/msadm"
# Use HTTPS for meshstor remote so SSH agent state inside sudo doesn't matter.
MESHSTOR_URL_FOR_REBUILD="${MESHSTOR_URL_FOR_REBUILD:-https://github.com/meshstor/linux.git}"

DATE_TAG="$(date -u +%F)"
OUT_BASE="$REPO_ROOT/notes/perf-rebuild-$DATE_TAG"

SUITES_BASE="${SUITES_BASE:-/home/$SUDO_USER/csi-perf-test/suites}"
# Default suite set. ewma-asymmetric-read is the right test for the
# latency-ewma branch — qd=8 single-thread random read so the read-balance
# choice between legs determines per-IO latency. The four SNIA suites at
# qd=64 saturate both legs and would hide EWMA's signal on their own.
# Override the list with the SUITES env var (space-separated suite names).
DEFAULT_SUITES=(
    snia-randread-iops
    snia-randwrite-iops
    snia-randread-lat
    snia-randwrite-lat
    ewma-asymmetric-read
)
read -r -a _suite_names <<< "${SUITES:-${DEFAULT_SUITES[*]}}"
SUITES=()
for _s in "${_suite_names[@]}"; do SUITES+=("$SUITES_BASE/$_s"); done
unset _s _suite_names

declare -a VARIANT_LABELS=(baseline per-bucket-arrays takeover latency-ewma llbitmap-fastpath)
declare -A VARIANT_ARGS=(
    [baseline]=""
    [per-bucket-arrays]="per-bucket-arrays"
    [takeover]="wip/md-raid1-to-raid10-takeover"
    [latency-ewma]="md-latency-ewma"
    [llbitmap-fastpath]="wip/md-llbitmap-hot-write-fast-path"
)
declare -A VARIANT_VER=(
    [baseline]="0.1.0-baseline"
    [per-bucket-arrays]="0.1.0-pba"
    [takeover]="0.1.0-takeover"
    [latency-ewma]="0.1.0-ewma"
    [llbitmap-fastpath]="0.1.0-llbitmap"
)

usage() {
    cat <<EOF
Usage:
  sudo $(basename "$0") PART_LOCAL PART_REMOTE [VARIANT ...]
  sudo $(basename "$0") --level=raid10 --local=A --local=B \\
                        --remote=C --remote=D [VARIANT ...]

Orchestrate raid1 or raid10 perf comparison across meshstor-ms variants.

Positional form (raid1, default): two partitions = one local + one remote
(nvme-tcp loopback). Backward-compatible.

Flag form (raid10): N --local + N --remote (>=2 each), interleaved into
N mirror pairs. Each mirror pair has one local + one nvme-tcp leg.

Variants: baseline per-bucket-arrays takeover latency-ewma llbitmap-fastpath
          (default: all 5)

Flags:
  --level=raid1|raid10  raid level (default: raid1)
  --local=PATH          local-leg partition (repeatable)
  --remote=PATH         tcp-leg partition (repeatable; same count as --local)
  --port=N              nvmet-tcp listen port (default: bench script's 4420)
  --cool-thresh-k=N     wait between variants until max sensor temp on every
                        leg's parent NVMe drops below N Kelvin (default:
                        348 = 75 °C; 0 disables). Devices to monitor are
                        derived from --local + --remote (their parent disks).
  --summary-only        regenerate SUMMARY.md from existing run.log files
                        and exit (no rebuild/bench)

Environment overrides:
  REBUILT_TREE   Path for rebuild-main output (default: ../linux-meshstor-rebuilt)
  MDADM_BIN      Path to mdadm-fork binary (default: /home/$SUDO_USER/mdadm/mdadm)
  SUITES_BASE    csi-perf-test suites directory (default: /home/$SUDO_USER/csi-perf-test/suites)
  SUITES         space-separated suite names override (default: 4 SNIA suites)

Output: $OUT_BASE/<variant>/results/...
        $OUT_BASE/SUMMARY.md
EOF
}

LEVEL="raid1"
LOCALS=()
REMOTES=()
SELECTED_VARIANTS=()
SYSTEM_DKMS_VER=""
SUMMARY_ONLY=0
PORT="7720"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 2
fi

_pos=()
while (($#)); do
    case "$1" in
        --summary-only) SUMMARY_ONLY=1; shift ;;
        --level=*)      LEVEL="${1#--level=}"; shift ;;
        --local=*)      LOCALS+=("${1#--local=}"); shift ;;
        --remote=*)     REMOTES+=("${1#--remote=}"); shift ;;
        --port=*)       PORT="${1#--port=}"; shift ;;
        --cool-thresh-k=*) COOL_THRESH_K="${1#--cool-thresh-k=}"; shift ;;
        --) shift; _pos+=("$@"); break ;;
        -*) echo "error: unknown flag: $1" >&2; usage >&2; exit 2 ;;
        *)  _pos+=("$1"); shift ;;
    esac
done

if [[ $SUMMARY_ONLY -eq 1 ]]; then
    # In summary-only mode, positionals are variant names.
    if (( ${#_pos[@]} > 0 )); then SELECTED_VARIANTS=("${_pos[@]}"); fi
elif (( ${#LOCALS[@]} > 0 )) || (( ${#REMOTES[@]} > 0 )); then
    # Flag form: positionals are variants only; legs come from --local/--remote.
    if (( ${#_pos[@]} > 0 )); then SELECTED_VARIANTS=("${_pos[@]}"); fi
else
    # Positional form (backward-compat raid1): pos[0] pos[1] are legs, rest are variants.
    if (( ${#_pos[@]} < 2 )); then usage >&2; exit 2; fi
    LOCALS=("${_pos[0]}")
    REMOTES=("${_pos[1]}")
    if (( ${#_pos[@]} > 2 )); then SELECTED_VARIANTS=("${_pos[@]:2}"); fi
fi
unset _pos

if (( ${#SELECTED_VARIANTS[@]} == 0 )); then
    SELECTED_VARIANTS=("${VARIANT_LABELS[@]}")
fi

if [[ $SUMMARY_ONLY -eq 0 ]]; then
    if (( ${#LOCALS[@]} != ${#REMOTES[@]} )); then
        die "--local count (${#LOCALS[@]}) must equal --remote count (${#REMOTES[@]})"
    fi
    case "$LEVEL" in
        raid1)
            (( ${#LOCALS[@]} == 1 )) || die "raid1 needs exactly 1 local + 1 remote (got ${#LOCALS[@]} + ${#REMOTES[@]})" ;;
        raid10)
            (( ${#LOCALS[@]} >= 2 )) || die "raid10 needs at least 2 local + 2 remote (got ${#LOCALS[@]} + ${#REMOTES[@]})" ;;
        *)  die "unsupported --level: $LEVEL (choices: raid1 raid10)" ;;
    esac
fi
# Convenience for older code paths in this script (single-leg display only):
PART_LOCAL="${LOCALS[0]:-}"
PART_REMOTE="${REMOTES[0]:-}"

# ----- helpers -----

log()  { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$(date -u +%FT%TZ)" "$*" >&2; exit 1; }

require_root() {
    [[ $EUID -eq 0 ]] || die "must run as root (try: sudo $0 ...)"
}

require_tools() {
    local missing=()
    for t in dkms modprobe lsmod fio jq awk; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    [[ -x "$MDADM_BIN" ]]   || missing+=("mdadm-fork at $MDADM_BIN")
    [[ -x "$REBUILD_MAIN" ]] || missing+=("$REBUILD_MAIN")
    [[ -x "$BUILD_TARBALL" ]] || missing+=("$BUILD_TARBALL")
    [[ -x "$RUN_PERF" ]]      || missing+=("$RUN_PERF")
    if (( ${#missing[@]} )); then
        die "missing: ${missing[*]}"
    fi
}

require_partitions() {
    local p
    for p in "${LOCALS[@]}" "${REMOTES[@]}"; do
        [[ -b "$p" ]] || die "$p is not a block device"
    done
}

require_suites() {
    for s in "${SUITES[@]}"; do
        [[ -d "$s" && -x "$s/run.sh" ]] || die "suite missing or not runnable: $s"
    done
}

setup_msadm_wrapper() {
    cat > "$MSADM_WRAPPER" <<EOF
#!/bin/sh
# autogenerated by perf-feature-compare.sh
exec "$MDADM_BIN" --subsys=ms "\$@"
EOF
    chmod +x "$MSADM_WRAPPER"
    log "msadm wrapper: $MSADM_WRAPPER -> $MDADM_BIN --subsys=ms"
}

# Wait until every parent NVMe of a leg partition cools below COOL_THRESH_K
# (default 75 °C). Monitors the composite + all sensors on each device, takes
# the max — different SSDs label the controller chip differently, and the
# controller often runs hotter than the composite without that being visible
# in id-ctrl thresholds. Set COOL_THRESH_K=0 to disable.
COOL_THRESH_K="${COOL_THRESH_K:-348}"

# Derive the unique set of parent NVMe devices from LOCALS + REMOTES
# (e.g., /dev/nvme0n1p4 + /dev/nvme1n1p2 -> /dev/nvme0n1 /dev/nvme1n1).
cool_devs() {
    local p parent dev
    declare -A seen
    for p in "${LOCALS[@]}" "${REMOTES[@]}"; do
        parent="$(lsblk -no PKNAME "$p" 2>/dev/null | head -1)"
        [[ -n "$parent" ]] || continue
        dev="/dev/$parent"
        if [[ -z "${seen[$dev]:-}" ]]; then
            seen[$dev]=1
            echo "$dev"
        fi
    done
}

# Read max(composite, sensor_1..4) from one device, in Kelvin. Empty on miss.
nvme_max_temp_k() {
    nvme smart-log "$1" -o json 2>/dev/null \
        | jq -r '[.temperature, .temperature_sensor_1, .temperature_sensor_2,
                  (.temperature_sensor_3 // 0), (.temperature_sensor_4 // 0)] | max' \
          2>/dev/null
}

wait_cool() {
    [[ "$COOL_THRESH_K" -gt 0 ]] || return 0
    local devs
    mapfile -t devs < <(cool_devs)
    if (( ${#devs[@]} == 0 )); then
        warn "wait_cool: no parent NVMe devices derivable from legs; skipping"
        return 0
    fi
    local cur waits=0 d hot
    while :; do
        hot=0
        for d in "${devs[@]}"; do
            cur="$(nvme_max_temp_k "$d")"
            [[ -z "$cur" || "$cur" == "null" ]] && continue
            (( cur > hot )) && hot=$cur
        done
        if (( hot == 0 )); then
            warn "wait_cool: could not read any temp; skipping"
            return 0
        fi
        if (( hot <= COOL_THRESH_K )); then
            (( waits > 0 )) && log "wait_cool: cooled to ${hot} K (target ${COOL_THRESH_K})"
            return 0
        fi
        log "wait_cool: max across ${devs[*]} = ${hot} K (target ${COOL_THRESH_K}); sleep 60"
        sleep 60
        waits=$((waits + 1))
    done
}

unload_ms_modules() {
    if [[ -e /proc/msstat ]]; then
        for dev in /dev/ms*; do
            [[ -b "$dev" ]] || continue
            "$MSADM_WRAPPER" --stop "$dev" 2>/dev/null || true
        done
    fi
    for m in raid1_ms raid10_ms ms_mod; do
        if lsmod | awk '{print $1}' | grep -qx "$m"; then
            modprobe -r "$m" || warn "rmmod $m failed (will continue)"
        fi
    done
}

dkms_remove_safe() {
    local pkg="$1"
    if dkms status | grep -q "^$pkg,"; then
        log "dkms remove $pkg"
        dkms remove "$pkg" --all >/dev/null 2>&1 || warn "dkms remove $pkg returned non-zero"
    fi
}

remove_existing_pkg() {
    SYSTEM_DKMS_VER="$(dkms status | awk -F'[/,]' '/^meshstor-ms\//{gsub(/ /,"",$2); print $2; exit}')"
    if [[ -n "$SYSTEM_DKMS_VER" ]]; then
        log "saving system meshstor-ms version: $SYSTEM_DKMS_VER (will restore at end)"
        unload_ms_modules
        dkms_remove_safe "meshstor-ms/$SYSTEM_DKMS_VER"
    else
        log "no existing system meshstor-ms found"
    fi
}

install_variant() {
    local label="$1" ver="$2" tarball="$3"
    log "dkms ldtarball $tarball"
    dkms ldtarball "$tarball" >/dev/null
    log "dkms install meshstor-ms/$ver"
    dkms install "meshstor-ms/$ver" >/dev/null
}

load_ms_modules() {
    log "modprobe ms_mod raid1_ms raid10_ms"
    modprobe ms_mod    || return 1
    modprobe raid1_ms  || return 1
    modprobe raid10_ms || return 1
}

# ----- summary parsers (fio JSON output) -----

# Returns total IOPS (read+write — only one is non-zero per suite).
extract_iops_json() {
    jq -r '[.jobs[0].read.iops, .jobs[0].write.iops] | add | floor' "$1" 2>/dev/null || echo "-"
}

# Returns p99 clat in microseconds (read+write — only one is non-zero per suite).
extract_lat_p99_us_json() {
    local p99_ns
    p99_ns="$(jq -r '[.jobs[0].read.clat_ns.percentile."99.000000" // 0,
                     .jobs[0].write.clat_ns.percentile."99.000000" // 0] | add' \
                "$1" 2>/dev/null)" || { echo "-"; return; }
    if [[ -z "$p99_ns" || "$p99_ns" == "0" || "$p99_ns" == "null" ]]; then
        echo "-"
        return
    fi
    awk -v n="$p99_ns" 'BEGIN{printf "%.0f", n/1000}'
}

write_summary() {
    local f="$OUT_BASE/SUMMARY.md"
    local tmp="$f.tmp.$$"
    # Build into a temp file, then mv. If we crash midway, SUMMARY.md is left
    # at its prior state and the trap won't pollute it via leaked redirects.
    {
        echo "# Per-Feature Perf Comparison — $DATE_TAG"
        echo ""
        echo "Host: $(hostname)  Kernel: $(uname -r)"
        echo "Level: $LEVEL  Local legs: ${LOCALS[*]:-(none)}  TCP legs: ${REMOTES[*]:-(none)}"
        echo "Bench: dkms/scripts/run-perf-bench-tcp.sh --bitmap=lockless --level=$LEVEL"
        echo ""
        local suite_dir suite_name label out status run_log iops lat
        for suite_dir in "${SUITES[@]}"; do
            suite_name="$(basename "$suite_dir")"
            echo "## $suite_name"
            echo ""
            echo "| Variant | Status | IOPS | p99 lat (us) |"
            echo "|---|---|---|---|"
            for label in "${SELECTED_VARIANTS[@]}"; do
                out="$OUT_BASE/$label"
                status="$(cat "$out/status" 2>/dev/null || echo MISSING)"
                run_log="$(find "$out/results" -path "*/$suite_name/run.log" 2>/dev/null | head -1 || true)"
                if [[ -n "$run_log" && -f "$run_log" ]]; then
                    iops="$(extract_iops_json "$run_log" 2>/dev/null || echo "-")"
                    lat="$(extract_lat_p99_us_json "$run_log" 2>/dev/null || echo "-")"
                else
                    iops="-"
                    lat="-"
                fi
                echo "| $label | $status | ${iops:--} | ${lat:--} |"
            done
            echo ""
        done
    } > "$tmp"
    mv "$tmp" "$f"
    log "summary: $f"
}

# ----- variant cycle -----

run_variant() {
    local label="$1"
    local args="${VARIANT_ARGS[$label]}"
    local ver="${VARIANT_VER[$label]}"
    local out_dir="$OUT_BASE/$label"
    local rebuild_log="$out_dir/rebuild.log"
    local build_log="$out_dir/build.log"
    local bench_dir="$out_dir/results"
    mkdir -p "$out_dir"

    log "=== variant: $label (args='$args' ver=$ver) ==="

    # 1. rebuild-main
    log "rebuild-main $args -> $REBUILT_TREE"
    # Disable git commit signing inside the rebuild-main subprocess: SSH_AUTH_SOCK
    # is stripped by sudo, so any 'commit.gpgsign=true' ssh-signing config would
    # fail at git am time with "Couldn't get agent socket?".
    local rebuild_env=(
        MESHSTOR_URL="$MESHSTOR_URL_FOR_REBUILD"
        GIT_CONFIG_COUNT=1
        GIT_CONFIG_KEY_0=commit.gpgsign
        GIT_CONFIG_VALUE_0=false
    )
    if [[ -n "${SUDO_USER:-}" ]]; then
        if ! sudo -u "$SUDO_USER" env "${rebuild_env[@]}" \
                "$REBUILD_MAIN" --no-fetch $args > "$rebuild_log" 2>&1; then
            warn "rebuild-main failed for $label (see $rebuild_log)"
            echo "REBUILD_FAILED" > "$out_dir/status"
            return 0
        fi
    else
        if ! env "${rebuild_env[@]}" "$REBUILD_MAIN" --no-fetch $args > "$rebuild_log" 2>&1; then
            warn "rebuild-main failed for $label (see $rebuild_log)"
            echo "REBUILD_FAILED" > "$out_dir/status"
            return 0
        fi
    fi

    # 2. build-tarball (must run inside the rebuilt tree)
    log "build-tarball $ver"
    if [[ -n "${SUDO_USER:-}" ]]; then
        if ! ( cd "$REBUILT_TREE" && sudo -u "$SUDO_USER" "$BUILD_TARBALL" "$ver" ) > "$build_log" 2>&1; then
            warn "build-tarball failed (see $build_log)"
            echo "BUILD_FAILED" > "$out_dir/status"
            return 0
        fi
    else
        if ! ( cd "$REBUILT_TREE" && "$BUILD_TARBALL" "$ver" ) > "$build_log" 2>&1; then
            warn "build-tarball failed (see $build_log)"
            echo "BUILD_FAILED" > "$out_dir/status"
            return 0
        fi
    fi
    local tarball="$REBUILT_TREE/build/meshstor-ms-$ver.dkms.tar.gz"
    if [[ ! -f "$tarball" ]]; then
        warn "tarball not found: $tarball"
        echo "BUILD_FAILED" > "$out_dir/status"
        return 0
    fi

    # 3. dkms install
    if ! install_variant "$label" "$ver" "$tarball" >> "$build_log" 2>&1; then
        warn "dkms install failed (see $build_log)"
        dkms_remove_safe "meshstor-ms/$ver"
        echo "INSTALL_FAILED" > "$out_dir/status"
        return 0
    fi

    # 4. modprobe
    if ! load_ms_modules; then
        warn "modprobe failed for $label"
        unload_ms_modules
        dkms_remove_safe "meshstor-ms/$ver"
        echo "LOAD_FAILED" > "$out_dir/status"
        return 0
    fi

    # 5. bench
    log "run-perf-bench-tcp ($LEVEL, ${#LOCALS[@]}+${#REMOTES[@]} legs) -> $bench_dir"
    local -a bench_args
    bench_args=(--bitmap=lockless --out-dir="$bench_dir" --msadm="$MSADM_WRAPPER" \
                --level="$LEVEL")
    [[ -n "$PORT" ]] && bench_args+=(--port="$PORT")
    for p in "${LOCALS[@]}";  do bench_args+=(--local="$p");  done
    for p in "${REMOTES[@]}"; do bench_args+=(--remote="$p"); done
    if ! "$RUN_PERF" "${bench_args[@]}" "${SUITES[@]}"; then
        warn "bench failed for $label"
        echo "BENCH_FAILED" > "$out_dir/status"
    else
        echo "OK" > "$out_dir/status"
    fi

    # 6. teardown variant
    unload_ms_modules
    dkms_remove_safe "meshstor-ms/$ver"
    log "=== $label done: $(cat "$out_dir/status") ==="
}

restore_system() {
    log "restore: cleaning up per-variant pkgs and reinstalling system meshstor-ms"
    unload_ms_modules || true
    for label in "${VARIANT_LABELS[@]}"; do
        dkms_remove_safe "meshstor-ms/${VARIANT_VER[$label]}"
    done
    if [[ -n "${SYSTEM_DKMS_VER:-}" ]]; then
        if dkms status | grep -q "^meshstor-ms/$SYSTEM_DKMS_VER,"; then
            log "system pkg already installed, skipping reinstall"
        else
            log "dkms install meshstor-ms/$SYSTEM_DKMS_VER"
            dkms install "meshstor-ms/$SYSTEM_DKMS_VER" >/dev/null 2>&1 \
                || warn "dkms install meshstor-ms/$SYSTEM_DKMS_VER failed; manual restore needed"
        fi
        load_ms_modules || warn "modprobe ms_mod failed; manual restore needed"
    fi
}

# ----- main -----

if [[ $SUMMARY_ONLY -eq 1 ]]; then
    log "summary-only: regenerating $OUT_BASE/SUMMARY.md from existing results"
    write_summary
    log "all done"
    exit 0
fi

require_root
require_tools
require_partitions
require_suites
setup_msadm_wrapper

mkdir -p "$OUT_BASE"
log "compare: parts=$PART_LOCAL+$PART_REMOTE variants=(${SELECTED_VARIANTS[*]})"
log "compare: out=$OUT_BASE"

remove_existing_pkg
trap restore_system EXIT

for label in "${SELECTED_VARIANTS[@]}"; do
    if [[ -z "${VARIANT_ARGS[$label]+x}" ]]; then
        die "unknown variant: $label (choices: ${VARIANT_LABELS[*]})"
    fi
    wait_cool
    run_variant "$label"
done

write_summary
log "all done"

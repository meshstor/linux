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

DATE_TAG="${DATE_TAG:-$(date -u +%F)}"
OUT_BASE="$REPO_ROOT/notes/perf-rebuild-$DATE_TAG"

SUITES_BASE="${SUITES_BASE:-/home/$SUDO_USER/csi-perf-test/suites}"
# Default suite set: 4 SNIA corners as a no-regression band, plus 2 kp-*
# suites that target per-branch claims:
#
#   kp-asym-read           latency-ewma headline. 5 ms netem on lo + qd=8
#                          single-thread randread — the only regime where
#                          read-balance choice dominates per-IO latency.
#                          Symmetric-leg SNIA suites show 0% gain by design.
#   kp-hot-region-write    llbitmap-fastpath headline. 4 KiB randwrite into
#                          a pre-seeded 64 MiB region — every IO hits the
#                          single-chunk fast-path (commit 1). SNIA randwrite
#                          dilutes this signal across the 10% SS noise floor.
#
# Branches without a default suite:
#   per-bucket-arrays — raid10-only (dormant on raid1). Headline is
#                       resync-overlap, not steady-state. Run separately;
#                       see ~/DOCS/per-bucket-arrays.md.
#   takeover          — no-regression-only per design. Steady-state raid1
#                       paths are unchanged; SNIA band is the broad
#                       insurance check.
#
# Planned but not yet written: kp-hot-region-write-seq256k (multi-chunk
# fast-path probe — commit 2 of llbitmap-fastpath). See ~/DOCS/seq256k.md.
#
# Override the list with the SUITES env var (space-separated suite names).
DEFAULT_SUITES=(
    snia-randread-iops
    snia-randwrite-iops
    snia-randread-lat
    snia-randwrite-lat
    kp-asym-read
    kp-hot-region-write
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
  --no-cache            do not read from or write to build/cache/ for this run
                        (forces a fresh rebuild-main + build-tarball per variant)

Environment overrides:
  REBUILT_TREE   Path for rebuild-main output (default: ../linux-meshstor-rebuilt)
  MDADM_BIN      Path to mdadm-fork binary (default: /home/$SUDO_USER/mdadm/mdadm)
  SUITES_BASE    csi-perf-test suites directory (default: /home/$SUDO_USER/csi-perf-test/suites)
  SUITES         space-separated suite names override (default: 4 SNIA suites)

Output: $OUT_BASE/<variant>/results/...
        $OUT_BASE/SUMMARY.md
Cache:  $REPO_ROOT/build/cache/<key>/  (per-variant DKMS tarballs;
        rm -rf to reset; bypass with --no-cache)
EOF
}

LEVEL="raid1"
LOCALS=()
REMOTES=()
SELECTED_VARIANTS=()
SYSTEM_DKMS_VER=""
SUMMARY_ONLY=0
PORT="7720"
NO_CACHE=0

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 2
fi

_pos=()
while (($#)); do
    case "$1" in
        --summary-only) SUMMARY_ONLY=1; shift ;;
        --no-cache)     NO_CACHE=1; shift ;;
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

setup_nvmet() {
    # run-perf-bench-tcp needs /sys/kernel/config/nvmet (created when nvmet
    # is loaded). On a fresh boot the module isn't loaded; load it eagerly so
    # the bench doesn't bail with "configfs not mounted at /sys/kernel/config/nvmet".
    if [[ ! -d /sys/kernel/config/nvmet ]]; then
        log "modprobe nvmet nvmet-tcp"
        modprobe nvmet      || die "modprobe nvmet failed"
        modprobe nvmet-tcp  || die "modprobe nvmet-tcp failed"
    fi
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

# ----- cache helpers -----
#
# The cache stores per-variant DKMS source tarballs keyed by the inputs that
# determine the tarball's content. See spec:
#   docs/superpowers/specs/2026-05-07-perf-feature-compare-tarball-cache-design.md

# shellcheck disable=SC2034  # populated by resolve_shas, read by cache_key_for
declare -gA _SHA_CACHE
_UPSTREAM_MASTER_SHA=""
_HARNESS_SHA=""
_CACHE_SHAS_RESOLVED=0

# Resolve and memoize upstream master + meshstor branch SHAs needed for cache
# keys across all SELECTED_VARIANTS. Idempotent. Fails the run if any required
# remote ref cannot be resolved (the same network would fail rebuild-main).
resolve_shas() {
    (( _CACHE_SHAS_RESOLVED == 1 )) && return 0
    # When this script runs under sudo, $HOME is /root — but the upstream
    # bare mirror was bootstrapped under the invoking user. Use SUDO_USER's
    # home dir, falling back to $HOME only when not run under sudo.
    local user_home
    if [[ -n "${SUDO_USER:-}" ]]; then
        user_home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
        [[ -n "$user_home" ]] || die "cannot resolve home for SUDO_USER=$SUDO_USER"
    else
        user_home="$HOME"
    fi
    local mirror="${XDG_CACHE_HOME:-$user_home/.cache}/meshstor/torvalds-linux.git"
    [[ -d "$mirror" ]] \
        || die "upstream bare mirror missing: $mirror (run rebuild-main once to bootstrap)"
    _UPSTREAM_MASTER_SHA="$(git -C "$mirror" rev-parse master 2>/dev/null)" \
        || die "cannot read master from $mirror"

    _HARNESS_SHA="$(git ls-remote "$MESHSTOR_URL_FOR_REBUILD" refs/heads/meshstor-harness 2>/dev/null \
                      | awk 'NR==1{print $1}')"
    [[ -n "$_HARNESS_SHA" ]] \
        || die "git ls-remote $MESHSTOR_URL_FOR_REBUILD refs/heads/meshstor-harness failed"

    local label feature sha
    for label in "${SELECTED_VARIANTS[@]}"; do
        feature="${VARIANT_ARGS[$label]}"
        [[ -z "$feature" ]] && continue
        [[ -n "${_SHA_CACHE[$feature]:-}" ]] && continue
        sha="$(git ls-remote "$MESHSTOR_URL_FOR_REBUILD" "refs/heads/$feature" 2>/dev/null \
                  | awk 'NR==1{print $1}')"
        [[ -n "$sha" ]] \
            || die "git ls-remote $MESHSTOR_URL_FOR_REBUILD refs/heads/$feature failed"
        _SHA_CACHE[$feature]="$sha"
    done

    _CACHE_SHAS_RESOLVED=1
    log "cache: kernel=$(uname -r) upstream=${_UPSTREAM_MASTER_SHA:0:12} harness=${_HARNESS_SHA:0:12}"
    for label in "${SELECTED_VARIANTS[@]}"; do
        feature="${VARIANT_ARGS[$label]}"
        [[ -z "$feature" ]] && continue
        log "cache: $label feature=$feature sha=${_SHA_CACHE[$feature]:0:12}"
    done
}

# Compute the sha256 cache key for a variant label.
# Stdout: 64-hex-char sha256. Caller takes ${result:0:12} for the dir name.
cache_key_for() {
    local label="$1"
    resolve_shas
    local feature="${VARIANT_ARGS[$label]}"
    local feature_sha=""
    [[ -n "$feature" ]] && feature_sha="${_SHA_CACHE[$feature]:-}"
    local ver="${VARIANT_VER[$label]}"
    local bt_sh_sha rm_sha
    bt_sh_sha="$(sha256sum "$BUILD_TARBALL" | awk '{print $1}')"
    rm_sha="$(sha256sum "$REBUILD_MAIN"     | awk '{print $1}')"
    # Newline-joined; no trailing newline (printf, not echo). Field order
    # MUST match cache_write_key_txt for human/machine consistency.
    printf '%s' "kernel=$(uname -r)
upstream_sha=$_UPSTREAM_MASTER_SHA
harness_sha=$_HARNESS_SHA
feature=$feature
feature_sha=$feature_sha
ver=$ver
build_tarball_sh=$bt_sh_sha
rebuild_main=$rm_sha" | sha256sum | awk '{print $1}'
}

# Write a human-readable record of the inputs that produced the cache entry.
# Field set MUST match cache_key_for, plus a created= timestamp.
cache_write_key_txt() {
    local cache_dir="$1" label="$2" ver="$3"
    local feature="${VARIANT_ARGS[$label]}"
    local feature_sha=""
    [[ -n "$feature" ]] && feature_sha="${_SHA_CACHE[$feature]:-}"
    local bt_sh_sha rm_sha
    bt_sh_sha="$(sha256sum "$BUILD_TARBALL" | awk '{print $1}')"
    rm_sha="$(sha256sum "$REBUILD_MAIN"     | awk '{print $1}')"
    {
        echo "kernel=$(uname -r)"
        echo "upstream_sha=$_UPSTREAM_MASTER_SHA"
        echo "harness_sha=$_HARNESS_SHA"
        echo "feature=$feature"
        echo "feature_sha=$feature_sha"
        echo "ver=$ver"
        echo "build_tarball_sh=sha256:$bt_sh_sha"
        echo "rebuild_main=sha256:$rm_sha"
        echo "created=$(date -u +%FT%TZ)"
    } > "$cache_dir/key.txt"
}

# Atomically copy a freshly built tarball into the cache directory.
# Args: $1=cache_dir  $2=cache_tar (final path)  $3=fresh_tarball
#       $4=label  $5=ver  $6=key (full sha256)
# Returns non-zero on failure; caller should fall back to the fresh path.
cache_store() {
    local cache_dir="$1" cache_tar="$2" fresh_tarball="$3"
    local label="$4" ver="$5" key="$6"
    mkdir -p "$cache_dir" || return 1
    local tmp="$cache_dir/.tmp.$$.tar.gz"
    cp "$fresh_tarball" "$tmp" || { rm -f "$tmp"; return 1; }
    cache_write_key_txt "$cache_dir" "$label" "$ver" || true
    mv "$tmp" "$cache_tar" || { rm -f "$tmp"; return 1; }
    # cache_store is called from obtain_tarball (which is invoked via $(...)),
    # so log output must go to stderr to avoid polluting the captured stdout.
    log "cache: stored $cache_tar (key=${key:0:12})" >&2
    return 0
}

# Best-effort cleanup of partial cache writes orphaned by a killed prior run.
# Bounded: only removes .tmp.* files older than 1 day under build/cache/.
cache_sweep_tmp() {
    local root="$REPO_ROOT/build/cache"
    [[ -d "$root" ]] || return 0
    find "$root" -name '.tmp.*' -mtime +1 -delete 2>/dev/null || true
}

# Return (via stdout) an absolute tarball path ready for `dkms ldtarball`,
# either from cache (hit) or by running rebuild-main + build-tarball (miss).
# Args: $1=label  $2=out_dir  $3=rebuild_log path  $4=build_log path
# On internal build failure: writes "$out_dir/status" with the failure code
# (REBUILD_FAILED / BUILD_FAILED) and returns 1; caller should `return 0`.
#
# IMPORTANT: this function is called via $(...) by the caller, which captures
# stdout into a variable. Diagnostic log()/warn() output therefore MUST go to
# stderr — otherwise it would be embedded into the returned tarball path.
obtain_tarball() {
    local label="$1" out_dir="$2" rebuild_log="$3" build_log="$4"
    local args="${VARIANT_ARGS[$label]}"
    local ver="${VARIANT_VER[$label]}"
    local fresh_tarball="$REBUILT_TREE/build/meshstor-ms-$ver.dkms.tar.gz"

    local key="" key12="" cache_dir="" cache_tar=""
    if (( NO_CACHE == 0 )); then
        key="$(cache_key_for "$label")"
        # Defensive: command substitution swallows die() exits; verify the
        # function returned a well-formed sha256 hex.
        [[ ${#key} -eq 64 ]] \
            || die "cache: cache_key_for produced unexpected output for $label: '$key'"
        key12="${key:0:12}"
        cache_dir="$REPO_ROOT/build/cache/$key12"
        cache_tar="$cache_dir/meshstor-ms-$ver.dkms.tar.gz"
        if [[ -f "$cache_tar" ]]; then
            log "CACHE HIT: $cache_tar (key=$key12)" >&2
            echo "$cache_tar"
            return 0
        fi
        log "cache: miss for $label (key=$key12); rebuilding" >&2
    fi

    # Cache miss (or --no-cache): rebuild + build. Block matches the original
    # inline implementation verbatim so failure paths are byte-identical to
    # the pre-cache behavior.
    log "rebuild-main $args -> $REBUILT_TREE" >&2
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
            return 1
        fi
    else
        if ! env "${rebuild_env[@]}" "$REBUILD_MAIN" --no-fetch $args > "$rebuild_log" 2>&1; then
            warn "rebuild-main failed for $label (see $rebuild_log)"
            echo "REBUILD_FAILED" > "$out_dir/status"
            return 1
        fi
    fi

    log "build-tarball $ver" >&2
    if [[ -n "${SUDO_USER:-}" ]]; then
        if ! ( cd "$REBUILT_TREE" && sudo -u "$SUDO_USER" "$BUILD_TARBALL" "$ver" ) > "$build_log" 2>&1; then
            warn "build-tarball failed (see $build_log)"
            echo "BUILD_FAILED" > "$out_dir/status"
            return 1
        fi
    else
        if ! ( cd "$REBUILT_TREE" && "$BUILD_TARBALL" "$ver" ) > "$build_log" 2>&1; then
            warn "build-tarball failed (see $build_log)"
            echo "BUILD_FAILED" > "$out_dir/status"
            return 1
        fi
    fi
    if [[ ! -f "$fresh_tarball" ]]; then
        warn "tarball not found: $fresh_tarball"
        echo "BUILD_FAILED" > "$out_dir/status"
        return 1
    fi

    # Populate cache (best-effort). On store failure, fall back to fresh path.
    if (( NO_CACHE == 0 )); then
        if cache_store "$cache_dir" "$cache_tar" "$fresh_tarball" "$label" "$ver" "$key"; then
            echo "$cache_tar"
            return 0
        fi
        warn "cache: failed to store $cache_tar; falling back to fresh path"
    fi
    echo "$fresh_tarball"
    return 0
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
    # dkms status formats:
    #   installed:  meshstor-ms/0.1.0-baseline, 6.8.0-111-generic, x86_64: installed
    #   added only: meshstor-ms/0.1.0-baseline: added
    # Match either by accepting `,` or `:` after the pkg name.
    if dkms status | grep -qE "^$pkg[,:]"; then
        log "dkms remove $pkg"
        dkms remove "$pkg" --all >/dev/null 2>&1 || warn "dkms remove $pkg returned non-zero"
    fi
}

remove_existing_pkg() {
    # Split on /, , and : so the version parses cleanly from both `installed` (",")
    # and `added` (":") output forms.
    #
    # Don't use `exit` in awk: with `set -o pipefail`, awk closing stdin on
    # first match causes `dkms status` to die with SIGPIPE, the pipeline
    # returns 141, and `set -e` then aborts the whole script before
    # remove_existing_pkg even finishes. Consume all input and emit at END.
    SYSTEM_DKMS_VER="$(dkms status | awk -F'[/,:]' '/^meshstor-ms\// && !v{gsub(/ /,"",$2); v=$2} END{print v}')"
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
    # Clear any stale entry for this slot — a prior failed run may have left
    # the version in `added` state, which makes ldtarball below refuse.
    dkms_remove_safe "meshstor-ms/$ver"
    log "dkms ldtarball $tarball"
    # Explicitly propagate ldtarball failure: install_variant is invoked from
    # `if ! install_variant ...` (which suppresses set -e), and a corrupt
    # tarball would otherwise be masked by dkms install silently reusing a
    # stale /usr/src/<pkg>-<ver>/ tree from a prior run — defeating the
    # auto-heal path in run_variant.
    if ! dkms ldtarball "$tarball" >/dev/null; then
        return 1
    fi
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
#
# Some suites (e.g. ewma-asymmetric-read) append diagnostic text after the
# fio JSON object — passing the whole file to jq causes a parse error on
# the trailer and jq exits non-zero, so the values get lost. Strip the
# trailer before piping to jq.

run_log_json() {
    awk '/^==== per-rdev/{exit} {print}' "$1"
}

# Returns total IOPS (read+write — only one is non-zero per suite).
extract_iops_json() {
    run_log_json "$1" \
        | jq -r '[.jobs[0].read.iops, .jobs[0].write.iops] | add | floor' 2>/dev/null \
        || echo "-"
}

# Returns p99 clat in microseconds (read+write — only one is non-zero per suite).
extract_lat_p99_us_json() {
    local p99_ns
    p99_ns="$(run_log_json "$1" \
        | jq -r '[.jobs[0].read.clat_ns.percentile."99.000000" // 0,
                  .jobs[0].write.clat_ns.percentile."99.000000" // 0] | add' \
        2>/dev/null)" || { echo "-"; return; }
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

    # 1+2. Obtain tarball (cache hit OR rebuild-main + build-tarball).
    local tarball
    if ! tarball="$(obtain_tarball "$label" "$out_dir" "$rebuild_log" "$build_log")"; then
        return 0   # status was already written by obtain_tarball
    fi

    # 3. dkms install (with auto-heal on cache-sourced failure).
    if ! install_variant "$label" "$ver" "$tarball" >> "$build_log" 2>&1; then
        if [[ "$tarball" == "$REPO_ROOT/build/cache/"* ]]; then
            local cache_dir
            cache_dir="$(dirname "$tarball")"
            warn "CACHE CORRUPT: removing $cache_dir and rebuilding once"
            rm -rf "$cache_dir"
            dkms_remove_safe "meshstor-ms/$ver"
            if ! tarball="$(obtain_tarball "$label" "$out_dir" "$rebuild_log" "$build_log")"; then
                return 0
            fi
            if ! install_variant "$label" "$ver" "$tarball" >> "$build_log" 2>&1; then
                warn "dkms install failed after auto-heal (see $build_log)"
                dkms_remove_safe "meshstor-ms/$ver"
                echo "INSTALL_FAILED" > "$out_dir/status"
                return 0
            fi
        else
            warn "dkms install failed (see $build_log)"
            dkms_remove_safe "meshstor-ms/$ver"
            echo "INSTALL_FAILED" > "$out_dir/status"
            return 0
        fi
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
setup_nvmet

mkdir -p "$OUT_BASE"
cache_sweep_tmp
# Resolve cache-key inputs (network calls) up front so any failure aborts the
# script in the main shell. cache_key_for is later invoked via $(...) inside
# obtain_tarball, where set -e does not propagate die() out of the subshell.
(( NO_CACHE == 0 )) && resolve_shas
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

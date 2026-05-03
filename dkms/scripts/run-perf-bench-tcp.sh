#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# nvme-tcp loopback raid1 perf harness for meshstor-ms.
# Spec: docs/superpowers/specs/2026-05-04-perf-bench-tcp-loopback-design.md
#
# Builds an ms raid1 with one local NVMe partition leg and one nvme-tcp
# loopback leg (the second partition exported via nvmet-tcp on this host
# and re-imported), then runs one or more csi-perf-test-style suites
# against /dev/ms0. Idempotent trap-driven teardown.

set -euo pipefail

# ---- defaults ----
DEFAULT_BITMAP="lockless"
DEFAULT_PORT="4420"
DEFAULT_ADDR="127.0.0.1"

# ---- exit codes ----
EXIT_USAGE=2
EXIT_PREFLIGHT=3
EXIT_SETUP=4
EXIT_SUITE=5

# ---- globals populated by parse_args ----
PART_LOCAL=""
PART_REMOTE=""
SUITES=()
BITMAP="$DEFAULT_BITMAP"
PORT="$DEFAULT_PORT"
ADDR="$DEFAULT_ADDR"
MSADM=""
OUT_DIR=""
FAIL_FAST=0
KEEP=0

die() { echo "error: $*" >&2; exit "$EXIT_USAGE"; }

# ---- logging ----
LOG_FD=2  # stderr by default; main() may redirect later

log()  { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >&"$LOG_FD"; }
warn() { printf '[%s] WARN: %s\n' "$(date -u +%FT%TZ)" "$*" >&"$LOG_FD"; }

# run_log CMD ARGS...  — log the command, then run it; output goes
# wherever the caller already routed stdout/stderr. Returns command's
# exit code.
run_log() {
    log "+ $*"
    "$@"
}

# ---- preflight ----
REQUIRED_TOOLS=(mdadm nvme fio lsblk jq udevadm awk modprobe ss)
REQUIRED_MODULES=(nvmet nvmet-tcp nvme-tcp ms-mod)

die_pre() { echo "preflight: $*" >&2; exit "$EXIT_PREFLIGHT"; }

resolve_msadm() {
    if [[ -n "$MSADM" ]]; then
        [[ -x "$MSADM" ]] || return 1
        return 0
    fi
    if [[ -x /tmp/msadm ]]; then
        MSADM=/tmp/msadm
        return 0
    fi
    if command -v msadm >/dev/null 2>&1; then
        MSADM="$(command -v msadm)"
        return 0
    fi
    return 1
}

die_setup() { echo "setup: $*" >&2; exit "$EXIT_SETUP"; }

# ---- nvmet ----
NVMET_ROOT="${NVMET_ROOT:-/sys/kernel/config/nvmet}"
NQN=""
PORT_ID=""
NVMET_SETUP_DONE=0

generate_nqn() {
    local host
    host="$(hostname -s)"
    NQN="nqn.2026-05.local:msbench-${host}-$$-$RANDOM"
}

generate_port_id() {
    PORT_ID="$(printf '%s:%s' "$ADDR" "$PORT" | cksum | awk '{print $1 % 65535 + 1}')"
}

setup_nvmet() {
    [[ -d "$NVMET_ROOT" ]] || die_setup "configfs not mounted at $NVMET_ROOT"
    generate_nqn
    generate_port_id

    local sub="$NVMET_ROOT/subsystems/$NQN"
    local ns="$sub/namespaces/1"
    local port="$NVMET_ROOT/ports/$PORT_ID"

    log "nvmet: subsystem $NQN, port $PORT_ID -> $ADDR:$PORT"

    run_log mkdir -p "$sub"
    echo 1 > "$sub/attr_allow_any_host"
    run_log mkdir -p "$ns"
    echo "$PART_REMOTE" > "$ns/device_path"
    echo 1 > "$ns/enable"

    run_log mkdir -p "$port"
    echo "$ADDR"  > "$port/addr_traddr"
    echo "$PORT"  > "$port/addr_trsvcid"
    echo tcp      > "$port/addr_trtype"
    echo ipv4     > "$port/addr_adrfam"

    run_log ln -s "$sub" "$port/subsystems/$NQN"
    NVMET_SETUP_DONE=1
}

# ---- nvme client ----
IMPORTED=""
NVME_CONNECTED=0

connect_nvme_client() {
    log "nvme connect: $ADDR:$PORT $NQN"
    run_log udevadm settle
    run_log nvme connect -t tcp -a "$ADDR" -s "$PORT" -n "$NQN"
    NVME_CONNECTED=1
    run_log udevadm settle
}

resolve_imported() {
    local json
    json="$(nvme list -o json)" || die_setup "nvme list failed"
    local matches
    matches="$(printf '%s\n' "$json" | jq -r --arg nqn "$NQN" \
        '[.Devices[]? | select(.SubsystemNQN == $nqn) | .DevicePath] | .[]')"
    local count
    count="$(printf '%s\n' "$matches" | grep -c . || true)"
    if [[ "$count" -ne 1 ]]; then
        die_setup "expected 1 nvme device matching NQN $NQN; got $count"
    fi
    IMPORTED="$matches"
    log "imported device: $IMPORTED"
}

disconnect_nvme_client() {
    [[ "$NVME_CONNECTED" -eq 1 ]] || return 0
    nvme disconnect -n "$NQN" >/dev/null 2>&1 || true
    udevadm settle >/dev/null 2>&1 || true
}

# ---- ms raid1 ----
MS_DEV="${MS_DEV:-/dev/ms0}"
MSRAID_ASSEMBLED=0

msraid_assemble() {
    log "msraid: assemble $MS_DEV from $PART_LOCAL + $IMPORTED (bitmap=$BITMAP)"
    run_log "$MSADM" --create "$MS_DEV" \
        --level=raid1 --raid-devices=2 \
        --bitmap="$BITMAP" --metadata=1.2 \
        --run --assume-clean \
        "$PART_LOCAL" "$IMPORTED"
    MSRAID_ASSEMBLED=1
}

msraid_verify() {
    local detail state working failed
    detail="$("$MSADM" --detail "$MS_DEV")" || die_setup "msadm --detail failed"
    state="$(printf '%s\n'   "$detail" | awk -F': *' '/State *:/{print $2; exit}')"
    working="$(printf '%s\n' "$detail" | awk -F': *' '/Working Devices/{print $2; exit}')"
    failed="$(printf '%s\n'  "$detail" | awk -F': *' '/Failed Devices/{print $2; exit}')"
    if [[ "$state" != "active" ]] || [[ "$working" != "2" ]] || [[ "$failed" != "0" ]]; then
        die_setup "msraid not healthy: state=$state working=$working failed=$failed"
    fi
}

msraid_teardown() {
    [[ "$MSRAID_ASSEMBLED" -eq 1 ]] || return 0
    "$MSADM" --stop "$MS_DEV" >/dev/null 2>&1 || true
    "$MSADM" --zero-superblock "$PART_LOCAL" >/dev/null 2>&1 || true
    if [[ -n "$IMPORTED" ]]; then
        "$MSADM" --zero-superblock "$IMPORTED" >/dev/null 2>&1 || true
    fi
}

# ---- manifest ----
default_out_dir() {
    local stamp host kver
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    host="$(hostname -s)"
    kver="$(uname -r)"
    printf '%s' "./results/${stamp}-${host}-${kver}"
}

resolve_out_dir() {
    [[ -z "$OUT_DIR" ]] && OUT_DIR="$(default_out_dir)"
    mkdir -p "$OUT_DIR"
}

# Best-effort property fetcher; returns "" on any failure.
safe() { "$@" 2>/dev/null || true; }

write_manifest() {
    resolve_out_dir
    local f="$OUT_DIR/manifest.json"
    local started host kver
    started="$(date -u +%FT%TZ)"
    host="$(hostname -s)"
    kver="$(uname -r)"

    local ms_version ms_srcversion msadm_v nvme_v mdadm_v
    ms_version="$(   safe modinfo ms-mod | awk -F': *' '/^version:/    {print $2; exit}')"
    ms_srcversion="$(safe modinfo ms-mod | awk -F': *' '/^srcversion:/ {print $2; exit}')"
    msadm_v="$(      safe "$MSADM" --version | head -1)"
    nvme_v="$(       safe nvme --version    | head -1)"
    mdadm_v="$(      safe mdadm --version 2>&1 | head -1)"

    local pl_size pr_size pl_model pr_model pl_serial pr_serial
    pl_size="$(  safe blockdev --getsize64 "$PART_LOCAL")"
    pr_size="$(  safe blockdev --getsize64 "$PART_REMOTE")"
    pl_model="$( safe lsblk -ndo MODEL  "$PART_LOCAL"  | tr -d '\n' | xargs)"
    pr_model="$( safe lsblk -ndo MODEL  "$PART_REMOTE" | tr -d '\n' | xargs)"
    pl_serial="$(safe lsblk -ndo SERIAL "$PART_LOCAL"  | tr -d '\n' | xargs)"
    pr_serial="$(safe lsblk -ndo SERIAL "$PART_REMOTE" | tr -d '\n' | xargs)"

    local cmdline ms_params
    cmdline="$(safe cat /proc/cmdline | tr -d '\n')"
    ms_params="$(
        for p in /sys/module/ms_mod/parameters/*; do
            [ -e "$p" ] || continue
            printf '%s=%s\n' "$(basename "$p")" "$(safe cat "$p")"
        done 2>/dev/null
    )"

    jq -n \
        --arg started        "$started" \
        --arg host           "$host" \
        --arg kver           "$kver" \
        --arg ms_version     "$ms_version" \
        --arg ms_srcversion  "$ms_srcversion" \
        --arg msadm_v        "$msadm_v" \
        --arg nvme_v         "$nvme_v" \
        --arg mdadm_v        "$mdadm_v" \
        --arg part_local     "$PART_LOCAL" \
        --arg part_remote    "$PART_REMOTE" \
        --arg imported       "$IMPORTED" \
        --arg nqn            "$NQN" \
        --arg addr           "$ADDR" \
        --arg port           "$PORT" \
        --arg bitmap         "$BITMAP" \
        --arg ms_dev         "$MS_DEV" \
        --arg cmdline        "$cmdline" \
        --arg ms_params      "$ms_params" \
        --argjson pl_size    "${pl_size:-0}" \
        --argjson pr_size    "${pr_size:-0}" \
        --arg pl_model       "$pl_model" \
        --arg pr_model       "$pr_model" \
        --arg pl_serial      "$pl_serial" \
        --arg pr_serial      "$pr_serial" \
        --argjson suites     "$(printf '%s\n' "${SUITES[@]}" | jq -R . | jq -s .)" \
        '{
          schema: 1,
          started_utc: $started,
          host: $host,
          uname_r: $kver,
          ms_module: { version: $ms_version, srcversion: $ms_srcversion },
          msadm_version: $msadm_v,
          nvme_cli_version: $nvme_v,
          mdadm_version: $mdadm_v,
          part_local:  { path: $part_local,  size_bytes: $pl_size, model: $pl_model, serial: $pl_serial },
          part_remote: { path: $part_remote, size_bytes: $pr_size, model: $pr_model, serial: $pr_serial },
          imported_path: $imported,
          nvmet: { nqn: $nqn, addr: $addr, port: ($port|tonumber? // $port) },
          ms_array: { device: $ms_dev, bitmap: $bitmap, level: "raid1" },
          kernel_cmdline: $cmdline,
          ms_module_params: $ms_params,
          suites: $suites
        }' > "$f"

    {
        echo "started_utc: $started"
        echo "host:        $host"
        echo "kernel:      $kver"
        echo "ms-mod:      $ms_version ($ms_srcversion)"
        echo "msadm:       $msadm_v"
        echo "nvme:        $nvme_v"
        echo "mdadm:       $mdadm_v"
        echo "PART_LOCAL:  $PART_LOCAL"
        echo "PART_REMOTE: $PART_REMOTE  -> imported $IMPORTED"
        echo "nvmet:       $NQN @ $ADDR:$PORT"
        echo "ms array:    $MS_DEV bitmap=$BITMAP"
        echo
        echo "--- msadm --detail $MS_DEV ---"
        safe "$MSADM" --detail "$MS_DEV"
        echo
        echo "--- lsblk ---"
        safe lsblk
        echo
        echo "--- /proc/mdstat ---"
        safe cat /proc/mdstat
    } > "$OUT_DIR/start.txt"
}

# ---- suite runner ----
SUITE_FAILURES=0

drop_caches() {
    if [[ "${PBT_FAKE_DROP_CACHES:-0}" == "1" ]]; then
        return 0
    fi
    sync
    echo 3 > /proc/sys/vm/drop_caches
}

run_suite() {
    local suite="$1"
    local name dir started_epoch ended_epoch duration started_iso
    name="$(basename "$suite")"
    dir="$OUT_DIR/$name"
    mkdir -p "$dir"

    log "suite: $name (path=$suite)"
    drop_caches

    local prepare_rc=0 run_rc=0 cleanup_rc=0
    started_epoch="$(date -u +%s)"
    started_iso="$(date -u +%FT%TZ)"

    BLOCKDEV="$MS_DEV" VOLUME_MODE=block OUT_DIR="$OUT_DIR" \
        bash "$suite/prepare.sh" >"$dir/prepare.log" 2>&1 \
        || prepare_rc=$?

    if [[ "$prepare_rc" -eq 0 ]]; then
        BLOCKDEV="$MS_DEV" VOLUME_MODE=block OUT_DIR="$OUT_DIR" \
            bash "$suite/run.sh" >"$dir/run.log" 2>&1 \
            || run_rc=$?
    else
        run_rc=255
        echo "skipped: prepare failed (rc=$prepare_rc)" > "$dir/run.log"
    fi

    BLOCKDEV="$MS_DEV" VOLUME_MODE=block OUT_DIR="$OUT_DIR" \
        bash "$suite/cleanup.sh" >"$dir/cleanup.log" 2>&1 \
        || cleanup_rc=$?

    ended_epoch="$(date -u +%s)"
    duration=$((ended_epoch - started_epoch))

    jq -nc \
        --arg suite      "$name" \
        --arg path       "$suite" \
        --arg started    "$started_iso" \
        --argjson dur    "$duration" \
        --argjson p_rc   "$prepare_rc" \
        --argjson r_rc   "$run_rc" \
        --argjson c_rc   "$cleanup_rc" \
        '{
          suite: $suite,
          path: $path,
          started_utc: $started,
          duration_s: $dur,
          prepare_rc: $p_rc,
          run_rc:     $r_rc,
          cleanup_rc: $c_rc
        }' >> "$OUT_DIR/suite-results.jsonl"

    if [[ "$run_rc" -ne 0 ]]; then
        SUITE_FAILURES=$((SUITE_FAILURES + 1))
        log "suite $name: FAIL (run_rc=$run_rc)"
    else
        log "suite $name: ok"
    fi

    return "$run_rc"
}

# ---- cleanup + trap ----
SCRIPT_RC=0  # set by on_exit from $? before cleanup runs

cleanup() {
    local keep_active=0
    if [[ "$KEEP" -eq 1 ]] && [[ "$SCRIPT_RC" -eq 0 ]] && [[ "$SUITE_FAILURES" -eq 0 ]]; then
        keep_active=1
    fi

    if [[ "$keep_active" -eq 1 ]]; then
        log "cleanup: --keep set and run is clean; preserving topology"
        return 0
    fi

    log "cleanup: tearing down"
    msraid_teardown        || true
    disconnect_nvme_client || true
    teardown_nvmet         || true
}

on_exit() {
    SCRIPT_RC=$?
    cleanup >>"$OUT_DIR/cleanup.log" 2>&1 || true
    exit "$SCRIPT_RC"
}

teardown_nvmet() {
    [[ "$NVMET_SETUP_DONE" -eq 1 ]] || return 0
    local sub="$NVMET_ROOT/subsystems/$NQN"
    local ns="$sub/namespaces/1"
    local port="$NVMET_ROOT/ports/$PORT_ID"
    rm -f "$port/subsystems/$NQN" 2>/dev/null || true
    # On real configfs, ports/<id>/subsystems/ is auto-managed by the
    # kernel and disappears with rmdir of the port. Our tmpdir mock
    # leaves it around, so rm it explicitly.
    rmdir "$port/subsystems" 2>/dev/null || true
    rmdir "$port" 2>/dev/null || true
    if [[ -d "$ns" ]]; then
        # configfs creates `enable` when the namespace is created; in
        # the unit-test mock it doesn't exist, so guard the write.
        [[ -e "$ns/enable" ]] && { echo 0 > "$ns/enable" 2>/dev/null || true; }
        rmdir "$ns" 2>/dev/null || true
    fi
    rmdir "$sub/namespaces" 2>/dev/null || true
    rmdir "$sub" 2>/dev/null || true
}

preflight() {
    if [[ "${PBT_SKIP_ROOT_CHECK:-0}" != "1" ]] && [[ "$(id -u)" -ne 0 ]]; then
        die_pre "must run as root"
    fi

    local t
    for t in "${REQUIRED_TOOLS[@]}"; do
        command -v "$t" >/dev/null 2>&1 || die_pre "missing tool: $t"
    done

    if ! resolve_msadm; then
        die_pre "msadm not found (tried --msadm, /tmp/msadm, PATH)"
    fi

    local m
    for m in "${REQUIRED_MODULES[@]}"; do
        if ! modprobe -n "$m" >/dev/null 2>&1; then
            die_pre "kernel module not loadable: $m"
        fi
    done

    local p
    for p in "$PART_LOCAL" "$PART_REMOTE"; do
        if [[ "${PBT_PRESUME_BLOCK:-0}" != "1" ]] && [[ ! -b "$p" ]]; then
            die_pre "not a block device: $p"
        fi
        if grep -q "^$(basename "$p") " /proc/mdstat 2>/dev/null; then
            die_pre "partition is in /proc/mdstat: $p"
        fi
        if awk '{print $10}' /proc/self/mountinfo 2>/dev/null | grep -qx "$p"; then
            die_pre "partition is mounted: $p"
        fi
    done

    local s f
    for s in "${SUITES[@]}"; do
        [[ -d "$s" ]] || die_pre "suite is not a directory: $s"
        for f in prepare.sh run.sh cleanup.sh; do
            [[ -x "$s/$f" ]] || die_pre "suite missing executable $f: $s"
        done
    done

    if [[ "${PBT_SKIP_ROOT_CHECK:-0}" != "1" ]]; then
        if ss -lnt "sport = :$PORT" 2>/dev/null | tail -n +2 | grep -q .; then
            die_pre "port already bound: $ADDR:$PORT"
        fi
    fi
}

parse_args() {
    # Reset state so callers (and tests) can invoke parse_args repeatedly.
    PART_LOCAL=""
    PART_REMOTE=""
    SUITES=()
    BITMAP="$DEFAULT_BITMAP"
    PORT="$DEFAULT_PORT"
    ADDR="$DEFAULT_ADDR"
    MSADM=""
    OUT_DIR=""
    FAIL_FAST=0
    KEEP=0

    local pos=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --bitmap=*)   BITMAP="${1#--bitmap=}" ;;
            --port=*)     PORT="${1#--port=}" ;;
            --addr=*)     ADDR="${1#--addr=}" ;;
            --out-dir=*)  OUT_DIR="${1#--out-dir=}" ;;
            --msadm=*)    MSADM="${1#--msadm=}" ;;
            --fail-fast)  FAIL_FAST=1 ;;
            --keep)       KEEP=1 ;;
            -h|--help)    usage; exit 0 ;;
            --) shift; pos+=("$@"); break ;;
            -*) die "unknown flag: $1" ;;
            *)  pos+=("$1") ;;
        esac
        shift
    done

    if [[ ${#pos[@]} -lt 3 ]]; then
        die "need PART_LOCAL PART_REMOTE SUITE [SUITE...]; got ${#pos[@]} positional args"
    fi
    PART_LOCAL="${pos[0]}"
    PART_REMOTE="${pos[1]}"
    SUITES=("${pos[@]:2}")

    if [[ "$PART_LOCAL" == "$PART_REMOTE" ]]; then
        die "PART_LOCAL and PART_REMOTE must differ"
    fi

    # Mark not-yet-consumed globals as "used" so shellcheck SC2034
    # doesn't flag them while later commits add the actual consumers
    # (setup_nvmet, run_suite, cleanup, ...). The final commit will
    # remove this line once every global has a real reader.
    : "$FAIL_FAST $EXIT_SUITE"
}

usage() {
    cat <<'EOF'
Usage: run-perf-bench-tcp.sh [flags] PART_LOCAL PART_REMOTE SUITE [SUITE...]

Builds an ms raid1 with PART_LOCAL as leg 0 and PART_REMOTE (exported via
nvmet-tcp on this host and re-imported) as leg 1, then runs each SUITE
(prepare.sh, run.sh, cleanup.sh) against /dev/ms0 in block mode.

Flags:
  --bitmap=VAL        passed verbatim to msadm --bitmap (default: lockless)
  --out-dir=PATH      results root (default: ./results/<UTC>-<host>-<kver>)
  --port=N            nvmet tcp port (default: 4420)
  --addr=IP           nvmet tcp listen addr (default: 127.0.0.1)
  --msadm=PATH        msadm binary (default: /tmp/msadm if exists, else PATH)
  --fail-fast         stop after first failing suite (default: continue)
  --keep              skip teardown on success (debugging only)
  -h, --help          this message

Exit codes:
  0   all suites passed
  2   usage error
  3   preflight failure
  4   setup failure (nvmet/nvme/msadm)
  5   one or more suites failed
EOF
}

main() {
    if [[ $# -eq 0 ]] || [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
        usage
        exit 0
    fi
    parse_args "$@"
    echo "main: unimplemented (parse_args ok)" >&2
    exit 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

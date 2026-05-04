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

teardown_nvmet() {
    [[ "$NVMET_SETUP_DONE" -eq 1 ]] || return 0
    local sub="$NVMET_ROOT/subsystems/$NQN"
    local ns="$sub/namespaces/1"
    local port="$NVMET_ROOT/ports/$PORT_ID"
    rm -f "$port/subsystems/$NQN" 2>/dev/null || true
    rmdir "$port" 2>/dev/null || true
    if [[ -d "$ns" ]]; then
        echo 0 > "$ns/enable" 2>/dev/null || true
        rmdir "$ns" 2>/dev/null || true
    fi
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
    : "$BITMAP $OUT_DIR $FAIL_FAST $KEEP $EXIT_SUITE"
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

#!/usr/bin/env bash
# perf-compare-lib.sh — shared helpers for bin/perf-compare and
# bin/perf-bitmap-compare. Source-only (not directly executable).
#
# Spec: docs/superpowers/specs/2026-05-10-perf-bitmap-compare-design.md
#
# CONTRACT — caller must set these globals BEFORE sourcing or before
# calling functions that use them:
#
#   REPO_ROOT                  repo root absolute path
#   REBUILD_MAIN               path to bin/rebuild-main
#   BUILD_TARBALL              path to bin/build-tarball
#   REBUILT_TREE               path to build/linux-meshstor-rebuilt
#   MESHSTOR_URL_FOR_REBUILD   meshstor remote URL (HTTPS)
#   MDADM_BIN                  path to mdadm-fork binary (msadm wrapper)
#   COOL_THRESH_K              cooling threshold in Kelvin (0 = disabled)
#   LOCALS, REMOTES            arrays of leg partition paths
#   SELECTED_VARIANTS          array of variant labels to iterate
#   VARIANT_LABELS             array of ALL known labels (used by
#                              restore_system to clean leftover pkgs from
#                              prior runs that weren't in this --modes)
#   VARIANT_ARGS               assoc array: label -> rebuild-main args
#   VARIANT_VER                assoc array: label -> dkms version string
#   NO_CACHE                   0 or 1
#   MSADM_WRAPPER              path to msadm shell wrapper (used by
#                              unload_ms_modules to stop /dev/ms* arrays)
#
# Functions populate/read these caller-shared globals as side effects:
#   SYSTEM_DKMS_VER, _SHA_CACHE, _UPSTREAM_MASTER_SHA, _HARNESS_SHA,
#   _CACHE_SHAS_RESOLVED.
#
# Refusing to be executed directly catches typos like
# `bash perf-compare-lib.sh ...`:
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "perf-compare-lib.sh is sourced, not executed" >&2
    exit 2
fi

# ----- logging -----

log()  { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$(date -u +%FT%TZ)" "$*" >&2; exit 1; }

# ----- cooling -----

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

# Resolve a branch SHA the same way rebuild-main sources branches: a local
# head in this repo (even un-pushed) wins, else the meshstor remote. Keeping
# the two in lockstep is what makes the cache key honest — it must hash the
# SHA of whatever rebuild-main will actually build.
# Stdout: the SHA, or empty if the branch exists in neither place.
branch_sha() {
    local branch="$1" sha
    if sha="$(git -C "$REPO_ROOT" rev-parse --verify --quiet "refs/heads/$branch")"; then
        echo "$sha"
        return 0
    fi
    git ls-remote "$MESHSTOR_URL_FOR_REBUILD" "refs/heads/$branch" 2>/dev/null \
        | awk 'NR==1{print $1}'
}

# Resolve and memoize upstream master + meshstor branch SHAs needed for cache
# keys across all SELECTED_VARIANTS. Idempotent. Fails the run if any required
# branch cannot be resolved (rebuild-main would fail on the same lookup).
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
    local mirror="${MESHSTOR_UPSTREAM_MIRROR_DIR:-$REPO_ROOT/build}/torvalds-linux.git"
    [[ -d "$mirror" ]] \
        || die "upstream bare mirror missing: $mirror (run rebuild-main once to bootstrap)"
    _UPSTREAM_MASTER_SHA="$(git -C "$mirror" rev-parse master 2>/dev/null)" \
        || die "cannot read master from $mirror"

    _HARNESS_SHA="$(branch_sha meshstor-harness)"
    [[ -n "$_HARNESS_SHA" ]] \
        || die "branch meshstor-harness not found locally in $REPO_ROOT or on $MESHSTOR_URL_FOR_REBUILD"

    local label feature sha
    for label in "${SELECTED_VARIANTS[@]}"; do
        feature="${VARIANT_ARGS[$label]}"
        [[ -z "$feature" ]] && continue
        [[ -n "${_SHA_CACHE[$feature]:-}" ]] && continue
        sha="$(branch_sha "$feature")"
        [[ -n "$sha" ]] \
            || die "branch $feature not found locally in $REPO_ROOT or on $MESHSTOR_URL_FOR_REBUILD"
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
    # build-tarball writes its output to <its-REPO_ROOT>/build/. We invoke
    # it from $REPO_ROOT (this repo), so the tarball lands under our build/.
    local fresh_tarball="$REPO_ROOT/build/meshstor-ms-$ver.dkms.tar.gz"

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
    # build-tarball expects to run from this repo's REPO_ROOT (its own `git
    # rev-parse --show-toplevel` selects what becomes its REPO_ROOT — used
    # for dkms/ inputs and build outputs). REBUILT_TREE has its own .git
    # (rebuild-main does `git clone` into it), so we must NOT cd into it,
    # and must pass KERNEL_TREE explicitly so build-tarball reads kernel
    # sources from the rebuilt tree rather than its broken default.
    if [[ -n "${SUDO_USER:-}" ]]; then
        if ! ( cd "$REPO_ROOT" && sudo -u "$SUDO_USER" env KERNEL_TREE="$REBUILT_TREE" "$BUILD_TARBALL" "$ver" ) > "$build_log" 2>&1; then
            warn "build-tarball failed (see $build_log)"
            echo "BUILD_FAILED" > "$out_dir/status"
            return 1
        fi
    else
        if ! ( cd "$REPO_ROOT" && KERNEL_TREE="$REBUILT_TREE" "$BUILD_TARBALL" "$ver" ) > "$build_log" 2>&1; then
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

# ----- module + dkms lifecycle -----

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

# Remove any meshstor-ms .ko physically present in EVERY installed kernel's
# module tree, then refresh depmod. This is the cleanup `dkms remove` cannot do:
# dkms only deletes files it still tracks, so a .ko left by a prior install
# survives in two situations that both break the next run —
#   1. a higher-versioned ms_mod from an earlier deploy-branch: dkms install's
#      per-module "is it newer?" guard refuses to overwrite it while the
#      unversioned raid{1,10}_ms ARE overwritten, yielding a mismatched set
#      that fails to modprobe ("disagrees about version of symbol …");
#   2. a "Differences between built and installed modules" state where the
#      on-disk .ko no longer matches what dkms believes it installed.
# It must sweep ALL kernels, not just the running one: dkms install fans
# weak-updates/ symlinks into every ABI-compatible kernel, and a stale one left
# in a non-running kernel's modules.dep makes `dracut --regenerate-all` abort
# ("weak-updates/ms_mod.ko.xz: No such file … installkernel failed").
# Purging the ghost .ko guarantees the next `dkms install` lands a coherent
# module set. Idempotent.
purge_ms_kmods() {
    local kd kver rmd m f
    for kd in /lib/modules/*/; do
        kver="$(basename "$kd")"
        rmd=
        for m in ms_mod raid1_ms raid10_ms; do
            for f in "$kd"extra/"$m".ko* \
                     "$kd"updates/dkms/"$m".ko* \
                     "$kd"weak-updates/"$m".ko* \
                     "$kd"weak-updates/*/"$m".ko*; do
                # -L also matches a DANGLING symlink (a weak-updates link whose
                # extra/ target was already deleted); plain -e is false for those
                # and would leak them, stranding the modules.dep entry.
                [[ -e "$f" || -L "$f" ]] || continue
                rm -f "$f" && rmd=1
            done
        done
        # Regenerate depmod if we removed a .ko OR stale ms_* lines still linger
        # in modules.dep — a prior partial purge can strand entries with nothing
        # left to delete, and those break `dracut --regenerate-all`. Use depmod,
        # NOT `weak-modules --remove-modules` (it can hang indefinitely).
        if [[ -n "$rmd" ]] || grep -qsE 'ms_mod|raid1_ms|raid10_ms' "$kd"modules.dep; then
            [[ -n "$rmd" ]] && log "purged stale ms_* .ko from $kd"
            depmod "$kver" 2>/dev/null || true
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

# Is $1 one of the ephemeral perf-compare variant versions (0.1.0-baseline,
# 0.1.0-pba, …)? Lets us tell a real deployed system meshstor-ms (e.g. 0.1.0)
# apart from a variant package a prior aborted run left behind.
# VARIANT_LABELS/VARIANT_VER are defined by the calling tool (perf-compare /
# perf-bitmap-compare) and sourced into this shell; guard for the unset case.
is_variant_version() {
    local v="$1" label
    for label in "${VARIANT_LABELS[@]-}"; do
        [[ -n "$label" ]] || continue
        [[ "${VARIANT_VER[$label]-}" == "$v" ]] && return 0
    done
    return 1
}

# Fully purge an EPHEMERAL meshstor-ms variant version: `dkms remove` (best
# effort) then a force-clear of the registry dir. `dkms remove … --all` deletes
# the built .ko but leaves /var/lib/dkms/<m>/<v> in place (source link + build
# dir), and a lingering dir makes the next `dkms ldtarball` die with
#   Error! DKMS tree already contains: <m>/<v>
# (`ldtarball --force` does NOT bypass that check) — the failure that strands
# every repeat perf-compare run. Use ONLY for throwaway variant versions, never
# the saved system version: restore_system rebuilds that from its source.
purge_dkms_version() {
    local m="$1" v="$2"
    [[ -n "$m" && -n "$v" ]] || { warn "purge_dkms_version: empty module/version"; return 0; }
    dkms_remove_safe "$m/$v"
    if [[ -e "/var/lib/dkms/$m/$v" || -L "/var/lib/dkms/$m/$v" ]]; then
        warn "force-clearing leftover dkms registry dir /var/lib/dkms/$m/$v"
        rm -rf "/var/lib/dkms/${m:?}/${v:?}"
    fi
    # Drop any now-dangling kernel-<ver> originals symlink that pointed into the
    # version we just removed (dkms recreates the live one on the next install).
    [[ -d "/var/lib/dkms/$m" ]] && find "/var/lib/dkms/$m" -maxdepth 1 -xtype l -delete 2>/dev/null || true
}

remove_existing_pkg() {
    # Collect every installed/added meshstor-ms version. Split on /, , and : so
    # the version parses from both `installed` ("meshstor-ms/0.1.0, k, a: installed")
    # and `added` ("meshstor-ms/0.1.0: added") forms. awk consumes all input
    # (no early exit) so `set -o pipefail` can't trip on a SIGPIPE'd dkms status.
    local -a vers=()
    mapfile -t vers < <(dkms status | awk -F'[/,:]' '/^meshstor-ms\//{gsub(/ /,"",$2); print $2}' | sort -u)
    SYSTEM_DKMS_VER=""
    if (( ${#vers[@]} )); then
        unload_ms_modules
        local v
        for v in "${vers[@]}"; do
            [[ -n "$v" ]] || continue
            if is_variant_version "$v"; then
                # A perf variant version installed as the "system" package is the
                # leftover of a run that aborted before restore (or whose restore
                # reinstalled a variant). It is NOT a real deployment — saving it
                # would perpetuate it forever AND make this run's same-versioned
                # variant collide in the dkms tree. Purge it, don't restore it.
                warn "stale perf variant installed as system: meshstor-ms/$v — purging, not restoring"
                purge_dkms_version "meshstor-ms" "$v"
            elif [[ -z "$SYSTEM_DKMS_VER" ]]; then
                SYSTEM_DKMS_VER="$v"
                log "saving system meshstor-ms version: $v (will restore at end)"
                # Gentle remove only: the dkms source for $v is left intact so
                # restore_system can rebuild it from /usr/src at the end.
                dkms_remove_safe "meshstor-ms/$v"
            else
                warn "extra system meshstor-ms/$v present; removing (only $SYSTEM_DKMS_VER restored)"
                dkms_remove_safe "meshstor-ms/$v"
            fi
        done
    else
        log "no existing system meshstor-ms found"
    fi
    # Sweep ghost .ko unconditionally: a stale module set can be present even
    # when the dkms registry disagrees (registry on one version, on-disk ms_mod
    # a higher-versioned leftover) — the exact state that fails every variant
    # with LOAD_FAILED.
    purge_ms_kmods
}

install_variant() {
    local label="$1" ver="$2" tarball="$3"
    # Guarantee a clean dkms slot for $ver before ldtarball. A prior run (or the
    # saved system package sharing this version) leaves /var/lib/dkms/meshstor-ms/$ver
    # behind even after `dkms remove`, and `dkms ldtarball` then dies with
    # "DKMS tree already contains" — so force-clear it, don't just `dkms remove`.
    purge_dkms_version "meshstor-ms" "$ver"
    log "dkms ldtarball $tarball"
    # Explicitly propagate ldtarball failure: install_variant is invoked from
    # `if ! install_variant ...` (which suppresses set -e), and a corrupt
    # tarball would otherwise be masked by dkms install silently reusing a
    # stale /usr/src/<pkg>-<ver>/ tree from a prior run — defeating the
    # auto-heal path in run_variant.
    if ! dkms ldtarball "$tarball" --force >/dev/null; then
        return 1
    fi
    log "dkms install meshstor-ms/$ver"
    # --force: overwrite whatever .ko are already in the kernel tree regardless
    # of version. Without it, a higher-versioned leftover ms_mod is kept by
    # dkms's "is it newer?" guard while the unversioned raid{1,10}_ms get
    # overwritten — a mismatched set that fails to modprobe. remove_existing_pkg
    # already purges such ghosts up front; --force is the second line of defense.
    dkms install "meshstor-ms/$ver" --force >/dev/null
}

load_ms_modules() {
    log "modprobe ms_mod raid1_ms raid10_ms"
    modprobe ms_mod    || return 1
    modprobe raid1_ms  || return 1
    modprobe raid10_ms || return 1
}

restore_system() {
    log "restore: cleaning up per-variant pkgs and reinstalling system meshstor-ms"
    unload_ms_modules || true
    for label in "${VARIANT_LABELS[@]}"; do
        purge_dkms_version "meshstor-ms" "${VARIANT_VER[$label]}"
    done
    # Clear any ghost .ko the per-variant removals could not (foreign/mismatched
    # files dkms won't touch) so the system pkg reinstalls into a clean tree.
    purge_ms_kmods
    if [[ -n "${SYSTEM_DKMS_VER:-}" ]]; then
        # Always reinstall with --force: purge_ms_kmods just deleted the built
        # .ko, so even if the dkms registry still lists this version as
        # "installed" the kernel tree is now empty and needs a real rebuild.
        log "dkms install meshstor-ms/$SYSTEM_DKMS_VER"
        dkms install "meshstor-ms/$SYSTEM_DKMS_VER" --force >/dev/null 2>&1 \
            || warn "dkms install meshstor-ms/$SYSTEM_DKMS_VER failed; manual restore needed"
        load_ms_modules || warn "modprobe ms_mod failed; manual restore needed"
    fi
}

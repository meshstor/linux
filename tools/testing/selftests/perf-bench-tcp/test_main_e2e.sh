#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Mocked end-to-end: main() with all external tools stubbed and the
# nvmet ROOT pointed at a tmp dir. Verifies the full pipeline ordering
# and that suite-results.jsonl + manifest.json land in OUT_DIR.
set -e
# shellcheck source=tools/testing/selftests/perf-bench-tcp/lib.sh
. "$(dirname "$0")/lib.sh"
pbt_run_test "main-e2e"

# Stubs only for tools whose real invocation would fail or change state;
# leave coreutils + jq + lsblk + awk to the real binaries since the
# script uses them for parsing/formatting.
for t in mdadm fio modprobe ss; do
    pbt_stub "$t" 0 ""
done
pbt_stub udevadm 0 ""

export _NQN_CACHE="$PBT_TMPDIR/nqn.cache"

# nvme: respond to connect/list/disconnect/--version
cat > "$PBT_STUB_DIR/nvme" <<'EOF'
#!/usr/bin/env bash
echo "STUB nvme $*" >> "$PBT_STUB_LOG"
case "$1" in
    connect)
        nqn=""
        while [ $# -gt 0 ]; do
            if [ "$1" = "-n" ]; then nqn="$2"; break; fi
            shift
        done
        echo "$nqn" > "$_NQN_CACHE"
        ;;
    list-subsys)
        nqn="$(cat "$_NQN_CACHE" 2>/dev/null || true)"
        printf '[{"Subsystems":[{"NQN":"%s","Paths":[{"Name":"nvme9"}]}]}]\n' "$nqn"
        ;;
    --version)  echo "nvme version 2.4" ;;
    disconnect) ;;
esac
exit 0
EOF
chmod +x "$PBT_STUB_DIR/nvme"

# msadm: log calls; provide --detail and --version
cat > "$PBT_STUB_DIR/msadm" <<'EOF'
#!/usr/bin/env bash
echo "STUB msadm $*" >> "$PBT_STUB_LOG"
case "$1" in
    --detail)
        echo "State : active"
        echo "Working Devices : 2"
        echo "Failed Devices : 0"
        ;;
    --version)  echo "msadm v4.6-ms-fork" ;;
esac
exit 0
EOF
chmod +x "$PBT_STUB_DIR/msadm"

export PBT_SKIP_ROOT_CHECK=1
export PBT_PRESUME_BLOCK=1
export PBT_FAKE_DROP_CACHES=1
export PBT_SKIP_SUITE_LINK=1

# Use a tmp NVMET_ROOT
export NVMET_ROOT="$PBT_TMPDIR/configfs"
mkdir -p "$NVMET_ROOT"

# Suite that exits 0
SUITE="$PBT_TMPDIR/suiteX"; mkdir -p "$SUITE"
for f in prepare.sh run.sh cleanup.sh; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$SUITE/$f"
    chmod +x "$SUITE/$f"
done

OUT_DIR="$PBT_TMPDIR/results"
"$PBT_SCRIPT" --out-dir="$OUT_DIR" --msadm="$PBT_STUB_DIR/msadm" \
              /tmp/p0 /tmp/p1 "$SUITE"

[ -f "$OUT_DIR/manifest.json" ]        || { echo "FAIL: manifest.json"; exit 1; }
[ -f "$OUT_DIR/suite-results.jsonl" ]  || { echo "FAIL: jsonl";          exit 1; }
[ -f "$OUT_DIR/suiteX/run.log" ]       || { echo "FAIL: run.log";        exit 1; }

echo "ok"

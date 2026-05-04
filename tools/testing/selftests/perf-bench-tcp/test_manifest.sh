#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Unit: write_manifest emits valid JSON with required fields.
set -e
# shellcheck source=tools/testing/selftests/perf-bench-tcp/lib.sh
. "$(dirname "$0")/lib.sh"
pbt_run_test "manifest"

# shellcheck source=dkms/scripts/run-perf-bench-tcp.sh
. "$PBT_SCRIPT"

# Stubs for tools the manifest captures
pbt_stub modinfo 0 "version:        0.1.0
srcversion:     ABCDEF0123"
pbt_stub mdadm    0 "mdadm - v4.6 - 2026"
pbt_stub blockdev 0 ""
pbt_stub lsblk    0 ""

# nvme stub: respond to --version (and tolerate other calls)
cat > "$PBT_STUB_DIR/nvme" <<'EOF'
#!/usr/bin/env bash
echo "STUB nvme $*" >> "$PBT_STUB_LOG"
case "$1" in
    --version) echo "nvme version 2.4" ;;
esac
exit 0
EOF
chmod +x "$PBT_STUB_DIR/nvme"

# msadm stub: handle --version and --detail
cat > "$PBT_STUB_DIR/msadm" <<'EOF'
#!/usr/bin/env bash
echo "STUB msadm $*" >> "$PBT_STUB_LOG"
case "$1" in
    --version) echo "msadm - v4.6-ms-fork" ;;
    --detail)
        echo "State : active"
        echo "Working Devices : 2"
        echo "Failed Devices : 0"
        ;;
esac
exit 0
EOF
chmod +x "$PBT_STUB_DIR/msadm"

OUT_DIR="$PBT_TMPDIR/results"
mkdir -p "$OUT_DIR"
LOCALS=(/tmp/p0 /tmp/p1)
REMOTES=(/tmp/p2 /tmp/p3)
IMPORTEDS=(/tmp/p2-imp /tmp/p3-imp)
MSRAID_MEMBERS=(/tmp/p0 /tmp/p2-imp /tmp/p1 /tmp/p3-imp)
NQN=nqn.test:demo
ADDR=127.0.0.1
PORT=4420
BITMAP=lockless
LEVEL=raid10
RAID_DEVICES=4
MS_DEV=/dev/ms0
MSADM="$PBT_STUB_DIR/msadm"
SUITES=(/tmp/s1 /tmp/s2)

write_manifest

[ -f "$OUT_DIR/manifest.json" ] || { echo "FAIL: manifest.json missing"; exit 1; }
# Validate as JSON via python (always available in dev env); fall back to jq.
if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$OUT_DIR/manifest.json"
fi

pbt_assert_file_contains "$OUT_DIR/manifest.json" '"schema": 2'                "schema=2"
pbt_assert_file_contains "$OUT_DIR/manifest.json" '"bitmap": "lockless"'       "bitmap"
pbt_assert_file_contains "$OUT_DIR/manifest.json" '"level": "raid10"'          "level=raid10"
pbt_assert_file_contains "$OUT_DIR/manifest.json" '"raid_devices": 4'          "raid_devices=4"
pbt_assert_file_contains "$OUT_DIR/manifest.json" '"nqn": "nqn.test:demo"'     "nqn"
pbt_assert_file_contains "$OUT_DIR/manifest.json" '/tmp/p0'                    "LOCALS[0]"
pbt_assert_file_contains "$OUT_DIR/manifest.json" '/tmp/p1'                    "LOCALS[1]"
pbt_assert_file_contains "$OUT_DIR/manifest.json" '/tmp/p2'                    "REMOTES[0]"
pbt_assert_file_contains "$OUT_DIR/manifest.json" '/tmp/p2-imp'                "IMPORTEDS[0]"
pbt_assert_file_contains "$OUT_DIR/manifest.json" '/tmp/s1'                    "suite 1"
pbt_assert_file_contains "$OUT_DIR/manifest.json" '/tmp/s2'                    "suite 2"

[ -f "$OUT_DIR/start.txt" ] || { echo "FAIL: start.txt missing"; exit 1; }

echo "ok"

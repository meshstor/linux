#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Unit: run_suite tees logs, sets BLOCKDEV/VOLUME_MODE, captures rcs,
# appends one suite-results.jsonl line per suite.
set -e
# shellcheck source=tools/testing/selftests/perf-bench-tcp/lib.sh
. "$(dirname "$0")/lib.sh"
pbt_run_test "suite-runner"

# shellcheck source=dkms/scripts/run-perf-bench-tcp.sh
. "$PBT_SCRIPT"

OUT_DIR="$PBT_TMPDIR/results"; mkdir -p "$OUT_DIR"
MS_DEV=/dev/ms0
SUITE="$PBT_TMPDIR/mysuite"
mkdir -p "$SUITE"
export OUT_DIR_PROBE="$PBT_TMPDIR/probe.log"

cat > "$SUITE/prepare.sh" <<'EOF'
#!/usr/bin/env bash
echo "PREPARE blockdev=$BLOCKDEV mode=$VOLUME_MODE" >> "$OUT_DIR_PROBE"
exit 0
EOF
cat > "$SUITE/run.sh" <<'EOF'
#!/usr/bin/env bash
echo "RUN blockdev=$BLOCKDEV mode=$VOLUME_MODE" >> "$OUT_DIR_PROBE"
exit 0
EOF
cat > "$SUITE/cleanup.sh" <<'EOF'
#!/usr/bin/env bash
echo "CLEANUP" >> "$OUT_DIR_PROBE"
exit 0
EOF
chmod +x "$SUITE"/*.sh

# drop_caches needs root; the script honors PBT_FAKE_DROP_CACHES=1.
export PBT_FAKE_DROP_CACHES=1

run_suite "$SUITE"

# Per-suite dir + logs
name="$(basename "$SUITE")"
[ -f "$OUT_DIR/$name/prepare.log" ] || { echo "FAIL: prepare.log missing"; exit 1; }
[ -f "$OUT_DIR/$name/run.log"     ] || { echo "FAIL: run.log missing";     exit 1; }
[ -f "$OUT_DIR/$name/cleanup.log" ] || { echo "FAIL: cleanup.log missing"; exit 1; }

# Suite scripts saw the right env
pbt_assert_file_contains "$OUT_DIR_PROBE" "PREPARE blockdev=/dev/ms0 mode=block" "prepare env"
pbt_assert_file_contains "$OUT_DIR_PROBE" "RUN blockdev=/dev/ms0 mode=block"     "run env"
pbt_assert_file_contains "$OUT_DIR_PROBE" "CLEANUP"                              "cleanup ran"

# jsonl line
jsonl="$OUT_DIR/suite-results.jsonl"
[ -f "$jsonl" ] || { echo "FAIL: jsonl missing"; exit 1; }
lines="$(wc -l < "$jsonl")"
pbt_assert_eq "$lines" "1" "one jsonl line"
pbt_assert_file_contains "$jsonl" '"prepare_rc":0' "prepare_rc"
pbt_assert_file_contains "$jsonl" '"run_rc":0'    "run_rc"
pbt_assert_file_contains "$jsonl" '"cleanup_rc":0' "cleanup_rc"

# Failing run.sh
cat > "$SUITE/run.sh" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
chmod +x "$SUITE/run.sh"
rm -rf "${OUT_DIR:?}/$name"
run_suite "$SUITE" || true
pbt_assert_file_contains "$OUT_DIR/suite-results.jsonl" '"run_rc":7' "run_rc=7"

echo "ok"

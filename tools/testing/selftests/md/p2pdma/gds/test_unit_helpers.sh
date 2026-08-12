#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Rootless unit test for the GDS lib helpers (pure logic only — no arrays, no
# hardware). Also the syntax gate: every gds/bin file must pass bash -n.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
FAILED=0
fail() { echo "FAIL: $*" >&2; FAILED=1; }

# --- bash -n gate over everything this campaign ships -----------------------
REPO_ROOT="$(cd "$DIR/../../../../../.." && pwd)"
for f in "$DIR/lib.sh" "$DIR"/test_*.sh \
         "$REPO_ROOT/bin/gds-campaign" "$REPO_ROOT/bin/ms-queue-features" \
         "$REPO_ROOT/bin/gds-p2p-witness" "$REPO_ROOT/bin/gds-make-kit"; do
    [ -e "$f" ] || continue          # later-task files may not exist yet
    bash -n "$f" || fail "bash -n $f"
done

# --- source the lib with a stub MDADM ---------------------------------------
STUB="$(mktemp -d)"
trap 'rm -rf "$STUB"' EXIT
export MDADM="$STUB/mdadm"
cat > "$MDADM" <<'EOF'
#!/bin/bash
if [ "$1" = --examine ]; then
cat <<'EX'
/dev/fake:
          Magic : a92b4efc
        Version : 1.2
    Data Offset : 264192 sectors
   Super Offset : 8 sectors
EX
else
    echo "MDADM_ARGS: $*"
fi
EOF
chmod +x "$MDADM"
export GDS_RESULTS="$STUB/results"
. "$DIR/lib.sh"

# --- gds_verdict -------------------------------------------------------------
gds_verdict p2 headline PASS "it works"
grep -q $'p2\theadline\tPASS\tit works' "$GDS_RESULTS/verdict.tsv" \
    || fail "gds_verdict TSV line wrong: $(cat "$GDS_RESULTS/verdict.tsv")"

# --- gds_cufile_json ----------------------------------------------------------
CJ=$(gds_cufile_json strict "$STUB/cf1")
python3 -m json.tool "$CJ" >/dev/null || fail "strict cufile.json is not valid JSON"
grep -q '"allow_compat_mode": false' "$CJ" || fail "strict must set allow_compat_mode=false"
grep -q '"raid":   { "use_pci_p2pdma": true }' "$CJ" || fail "strict must set block.raid.use_pci_p2pdma"
CJ=$(gds_cufile_json lenient "$STUB/cf2")
grep -q '"allow_compat_mode": true' "$CJ" || fail "lenient must set allow_compat_mode=true"

# --- gds_csi_mdadm_create: exact CSI flag shape -------------------------------
out=$(gds_csi_mdadm_create /dev/ms9 1 /dev/a /dev/b)
exp="MDADM_ARGS: --create /dev/ms9 --level=1 --raid-devices=2 --metadata=1.2 --homehost=any --assume-clean --bitmap=internal --bitmap-chunk=128M --consistency-policy=bitmap --failfast --run /dev/a /dev/b"
[ "$out" = "$exp" ] || fail "raid1 create args:
  got: $out
  exp: $exp"
out=$(gds_csi_mdadm_create /dev/ms9 10 /dev/a /dev/b /dev/c /dev/d)
exp="MDADM_ARGS: --create /dev/ms9 --level=10 --raid-devices=4 --metadata=1.2 --homehost=any --assume-clean --bitmap=internal --bitmap-chunk=128M --consistency-policy=bitmap --failfast --chunk=64 --layout=n2 --run /dev/a /dev/b /dev/c /dev/d"
[ "$out" = "$exp" ] || fail "raid10 create args:
  got: $out
  exp: $exp"
out=$(gds_csi_mdadm_create /dev/ms9 1 /dev/a /dev/b -- --size=131072)
exp="MDADM_ARGS: --create /dev/ms9 --level=1 --raid-devices=2 --metadata=1.2 --homehost=any --assume-clean --bitmap=internal --bitmap-chunk=128M --consistency-policy=bitmap --failfast --size=131072 --run /dev/a /dev/b"
[ "$out" = "$exp" ] || fail "extra-args create args:
  got: $out
  exp: $exp"

# --- gds_data_offset_sectors ---------------------------------------------------
off=$(gds_data_offset_sectors /dev/fake)
[ "$off" = 264192 ] || fail "data offset parse: got '$off' want 264192"

# --- inval_inject: byte-lock the default matrix + refuse rule ----------------
INJ_SRC="$REPO_ROOT/dkms/inval-inject/inval_inject.c"
if [ -e "$INJ_SRC" ]; then
    grep -q 'static int p2p_only = -1;' "$INJ_SRC" \
        || fail "inval_inject: p2p_only must default to -1 (auto matrix)"
    grep -q 'p2p_only = strcmp(match, "ioerr") == 0 ? 0 : 1;' "$INJ_SRC" \
        || fail "inval_inject: default matrix must be 0 for match=ioerr, 1 otherwise"
    grep -q "strchr(symbol, ':')" "$INJ_SRC" \
        || fail "inval_inject: module-qualified refuse rule (strchr colon) missing"
    grep -q 'static char to_status_str\[16\] = "";' "$INJ_SRC" \
        || fail "inval_inject: to_status must default EMPTY (so 'set' is detectable)"
    grep -q 'is_pci_p2pdma_page(bio->bi_io_vec->bv_page)' "$INJ_SRC" \
        || fail "inval_inject: p2p filter must test bi_io_vec->bv_page directly (not bio_has_data)"
fi

# --- gds-p2p-witness arg validation (rootless: parsing precedes root check) --
WIT="$REPO_ROOT/bin/gds-p2p-witness"
if [ -e "$WIT" ]; then
    out=$("$WIT" --expect-rc bogus -- true 2>&1); rc=$?
    [ "$rc" = 2 ] || fail "witness --expect-rc bogus: want rc=2, got $rc"
    echo "$out" | grep -q -- '--expect-rc needs zero|nonzero|any' \
        || fail "witness --expect-rc bogus: wrong message: $out"
    out=$("$WIT" --expect-rc 2>&1); rc=$?     # missing value
    [ "$rc" = 2 ] || fail "witness --expect-rc (missing value): want rc=2, got $rc"
    if [ "$(id -u)" != 0 ]; then
        "$WIT" --expect-rc nonzero -- true >/dev/null 2>&1; rc=$?
        [ "$rc" = 4 ] || fail "witness valid --expect-rc as non-root: want rc=4 (root skip), got $rc"
    fi
fi

# --- Task-3 helpers: rootless coverage ---------------------------------------
# gds_assert_no_badblocks against a fake sysfs tree
mkdir -p "$STUB/sysblock/ms7/ms/rd0" "$STUB/sysblock/ms7/ms/rd1"
: > "$STUB/sysblock/ms7/ms/rd0/bad_blocks"
: > "$STUB/sysblock/ms7/ms/rd1/bad_blocks"
GDS_SYS_BLOCK="$STUB/sysblock" gds_assert_no_badblocks /dev/ms7 \
    || fail "gds_assert_no_badblocks: empty files must pass"
echo "16 8" > "$STUB/sysblock/ms7/ms/rd1/bad_blocks"
GDS_SYS_BLOCK="$STUB/sysblock" gds_assert_no_badblocks /dev/ms7 2>/dev/null \
    && fail "gds_assert_no_badblocks: non-empty content must fail"
# Absent path (no ms/rd*/bad_blocks at all) must FAIL, not read as a pass: a
# missing sysfs file means the array isn't running, not that it is clean.
GDS_SYS_BLOCK="$STUB/sysblock" gds_assert_no_badblocks /dev/ms_absent 2>/dev/null \
    && fail "gds_assert_no_badblocks: absent bad_blocks path must fail (missing != clean)"

# breadcrumb helpers against a stub dmesg
cat > "$STUB/dmesg1" <<'EOF'
line one
line two
EOF
cat > "$STUB/fake-dmesg" <<EOF
#!/bin/bash
cat "$STUB/dmesg1"
EOF
chmod +x "$STUB/fake-dmesg"
export GDS_DMESG_CMD="$STUB/fake-dmesg"
gds_dmesg_mark
cat >> "$STUB/dmesg1" <<'EOF'
ms/raid1:ms0: nvme0n1p5: no P2P path for peer pages (status=-22), failing write; if legs diverged run: echo repair > sync_action
EOF
gds_assert_breadcrumb || fail "gds_assert_breadcrumb: must see the breadcrumb in the delta"
gds_assert_no_breadcrumb 2>/dev/null && fail "gds_assert_no_breadcrumb: must fail when breadcrumb present"
gds_dmesg_mark   # re-mark past the breadcrumb
gds_assert_no_breadcrumb || fail "gds_assert_no_breadcrumb: clean delta must pass"
gds_assert_breadcrumb 2>/dev/null && fail "gds_assert_breadcrumb: must fail on clean delta"
unset GDS_DMESG_CMD

# gds_kallsyms_check against a fixture. raid_end_bio_io appears TWICE inside the
# same [raid10_ms] bracket -- the helper counts on ($3==sym && $NF==[mod]), so
# that is one target with n=2, exercising the n>1 "not uniquely resolvable"
# branch (a real static shared via raid1-10_ms.c could surface this way).
cat > "$STUB/kallsyms" <<'EOF'
ffffffffc0100000 t raid1_end_write_request	[raid1]
ffffffffc0200000 t raid1_end_write_request	[raid1_ms]
ffffffffc0200100 t raid10_end_write_request	[raid10_ms]
ffffffffc0200200 t raid_end_bio_io	[raid10_ms]
ffffffffc0200300 t raid_end_bio_io	[raid10_ms]
EOF
GDS_KALLSYMS="$STUB/kallsyms" gds_kallsyms_check raid1_end_write_request raid1_ms \
    || fail "gds_kallsyms_check: exactly-one-in-module must pass"
GDS_KALLSYMS="$STUB/kallsyms" gds_kallsyms_check raid1_end_write_request raid5_ms 2>/dev/null \
    && fail "gds_kallsyms_check: zero-in-module must fail"
GDS_KALLSYMS="$STUB/kallsyms" gds_kallsyms_check raid_end_bio_io raid10_ms 2>/dev/null \
    && fail "gds_kallsyms_check: two-in-same-module (ambiguous) must fail"

[ "$FAILED" = 0 ] && echo "PASS: unit helpers" && exit 0
exit 1

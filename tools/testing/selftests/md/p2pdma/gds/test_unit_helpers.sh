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

[ "$FAILED" = 0 ] && echo "PASS: unit helpers" && exit 0
exit 1

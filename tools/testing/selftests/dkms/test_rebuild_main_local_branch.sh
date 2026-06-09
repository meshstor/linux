#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# rebuild-main must source branches local-first so un-pushed work builds:
#   - a branch that exists only as a local head in the repo it runs from
#     is applied as-is (this is what lets deploy-branch/build-* work on a
#     branch that was never pushed);
#   - a branch absent locally falls back to the meshstor remote;
#   - a branch present in BOTH places resolves to the LOCAL one;
#   - a branch present in NEITHER fails with a "not found locally" error.
#
# Exercised end-to-end (filter-repo -> fetch -> format-patch -> git am)
# against miniature fixture repos: a fake upstream mirror, a fake local
# repo holding a copy of bin/rebuild-main, and a fake bare "meshstor
# remote". No network is touched.

set -u
# shellcheck source=tools/testing/selftests/dkms/lib.sh
. "$(dirname "$0")/lib.sh"

command -v git >/dev/null 2>&1 || dkms_skip "git not installed"
git filter-repo --version >/dev/null 2>&1 \
	|| dkms_skip "git-filter-repo not installed (rebuild-main requires it)"

work="$(dkms_mktemp_dir)"

# Fixture commits must not depend on the runner's git identity or signing
# config; rebuild-main itself gets signing disabled via GIT_CONFIG_* env,
# exactly the way perf-compare-lib.sh invokes it.
G=(git -c user.name=selftest -c user.email=selftest@example.invalid
   -c commit.gpgsign=false -c tag.gpgsign=false)
REBUILD_ENV=(MESHSTOR_UPSTREAM_MIRROR_DIR="$work/mirror"
             GIT_CONFIG_COUNT=2
             GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false
             GIT_CONFIG_KEY_1=tag.gpgsign    GIT_CONFIG_VALUE_1=false)

# --- fixture: fake torvalds upstream (only the filtered paths) ------------
up="$work/upstream"
"${G[@]}" init -q -b master "$up"
mkdir -p "$up/drivers/md" "$up/tools/testing/selftests/md"
echo "base md source" > "$up/drivers/md/md.c"
echo "base selftest" > "$up/tools/testing/selftests/md/base.sh"
"${G[@]}" -C "$up" add -A
"${G[@]}" -C "$up" commit -qm "fake upstream base"

# --- fixture: upstream mirror where rebuild-main expects its cache --------
mkdir -p "$work/mirror"
"${G[@]}" clone -q --bare "$up" "$work/mirror/torvalds-linux.git"

# --- fixture: the meshstor fork lineage ------------------------------------
# Same tree CONTENT as upstream but an independently created history
# (different root hash) — like the real github.com/meshstor/linux, whose
# history shares no commit hashes with torvalds/linux. This forces
# rebuild-main to anchor each branch's merge-base in the branch's own
# lineage; anchoring on the torvalds mirror has no common ancestor and
# would format-patch the whole history from the root.
msbase="$work/meshstor-base"
"${G[@]}" init -q -b master "$msbase"
cp -r "$up/drivers" "$up/tools" "$msbase/"
"${G[@]}" -C "$msbase" add -A
"${G[@]}" -C "$msbase" commit -qm "meshstor import of fake upstream base"
[ "$("${G[@]}" -C "$msbase" rev-list --max-parents=0 HEAD)" \
  != "$("${G[@]}" -C "$up" rev-list --max-parents=0 HEAD)" ] \
	|| dkms_fail "fixture lineages must not share history"

# --- fixture: local repo = what rebuild-main treats as REPO_ROOT ----------
# A copy of the real bin/rebuild-main runs from here, so its
# `git rev-parse --show-toplevel` resolves to this fixture repo. Cloned
# from the meshstor lineage, NOT the fake torvalds one.
lrepo="$work/localrepo"
"${G[@]}" clone -q "$msbase" "$lrepo"
mkdir -p "$lrepo/bin"
cp "$REPO_ROOT/bin/rebuild-main" "$lrepo/bin/rebuild-main"
chmod +x "$lrepo/bin/rebuild-main"

"${G[@]}" -C "$lrepo" checkout -qb local-feature
echo "local-only change" >> "$lrepo/drivers/md/md.c"
"${G[@]}" -C "$lrepo" commit -qam "md: local-only feature (never pushed)"

"${G[@]}" -C "$lrepo" checkout -q master
"${G[@]}" -C "$lrepo" checkout -qb shared-feature
echo "shared: local version" > "$lrepo/drivers/md/shared.c"
"${G[@]}" -C "$lrepo" add drivers/md/shared.c
"${G[@]}" -C "$lrepo" commit -qm "md: shared feature, LOCAL flavour"
"${G[@]}" -C "$lrepo" checkout -q master

# --- fixture: fake meshstor remote ----------------------------------------
# Carries remote-feature (absent locally) and a DIVERGENT shared-feature,
# so the test can prove which side local-first picked.
remote="$work/meshstor-remote.git"
"${G[@]}" clone -q --bare "$msbase" "$remote"
scratch="$work/scratch"
"${G[@]}" clone -q "$remote" "$scratch"
"${G[@]}" -C "$scratch" checkout -qb remote-feature
echo "remote-only change" > "$scratch/drivers/md/remote.c"
"${G[@]}" -C "$scratch" add drivers/md/remote.c
"${G[@]}" -C "$scratch" commit -qm "md: remote-only feature"
"${G[@]}" -C "$scratch" push -q origin remote-feature
"${G[@]}" -C "$scratch" checkout -q master
"${G[@]}" -C "$scratch" checkout -qb shared-feature
echo "shared: remote version" > "$scratch/drivers/md/shared.c"
"${G[@]}" -C "$scratch" add drivers/md/shared.c
"${G[@]}" -C "$scratch" commit -qm "md: shared feature, REMOTE flavour"
"${G[@]}" -C "$scratch" push -q origin shared-feature

# --- run: one branch from each source, plus the local-vs-remote tiebreak ---
out="$work/out"
if ! env "${REBUILD_ENV[@]}" MESHSTOR_URL="$remote" \
	"$lrepo/bin/rebuild-main" --no-fetch -o "$out" \
	local-feature remote-feature shared-feature \
	> "$work/rebuild.log" 2>&1; then
	echo "FAIL: rebuild-main failed; log follows" >&2
	cat "$work/rebuild.log" >&2
	exit 1
fi
log="$(cat "$work/rebuild.log")"

[ -f "$out/.meshstor-rebuilt" ] || dkms_fail "output sentinel .meshstor-rebuilt missing"

assert_contains "$log" "sourcing local-feature from local repo" \
	"un-pushed local branch must be sourced from the local repo"
assert_contains "$log" "sourcing remote-feature from $remote" \
	"branch absent locally must fall back to the meshstor remote"
assert_contains "$log" "sourcing shared-feature from local repo" \
	"branch present in both places must resolve local-first"

assert_file_matches "$out/drivers/md/md.c" "local-only change" \
	"local-only branch content must reach the rebuilt tree"
assert_file_matches "$out/drivers/md/remote.c" "remote-only change" \
	"remote-only branch content must reach the rebuilt tree"
assert_file_matches "$out/drivers/md/shared.c" "shared: local version" \
	"shared branch must carry the LOCAL flavour"
assert_file_not_matches "$out/drivers/md/shared.c" "shared: remote version" \
	"shared branch must not carry the REMOTE flavour"

# --- run: a branch that exists nowhere must fail informatively -------------
if env "${REBUILD_ENV[@]}" MESHSTOR_URL="$remote" \
	"$lrepo/bin/rebuild-main" --no-fetch -o "$work/out2" no-such-branch \
	> "$work/fail.log" 2>&1; then
	dkms_fail "rebuild-main unexpectedly succeeded for a nonexistent branch"
fi
assert_file_matches "$work/fail.log" "not found locally" \
	"missing-branch error must mention the local lookup"

dkms_pass "rebuild-main sources branches local-first with remote fallback"

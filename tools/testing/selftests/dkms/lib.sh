# SPDX-License-Identifier: GPL-2.0
# shellcheck shell=bash
# Shared helpers for meshstor-ms DKMS *tooling* selftests.
#
# These tests exercise the DKMS build tooling — the compat patches in
# dkms/patches/, the feature-flag detection in dkms/Makefile.in, and the
# bin/build-tarball assembly pipeline. Unlike the runtime md selftests under
# tools/testing/selftests/md/llbitmap/, they need NO root, NO loaded module,
# and NO special hardware: they operate purely on repo files plus fixture
# kernel header trees.
#
# Sourced by each test_*.sh in this directory; never run directly.

set -u

DKMS_TEST_TMPDIRS=()

DKMS_SELFTEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DKMS_SELFTEST_DIR/../../../.." && pwd)"

dkms_pass() { echo "PASS: $1"; exit 0; }
dkms_fail() { echo "FAIL: $1" >&2; exit 1; }
dkms_skip() { echo "SKIP: $1" >&2; exit 4; }

# dkms_mktemp_dir -> echoes a fresh temp dir, tracked for cleanup on EXIT.
dkms_mktemp_dir() {
	local d
	d="$(mktemp -d "${TMPDIR:-/tmp}/dkms-selftest.XXXXXX")"
	DKMS_TEST_TMPDIRS+=("$d")
	echo "$d"
}

dkms_cleanup() {
	set +e
	local d
	for d in "${DKMS_TEST_TMPDIRS[@]:-}"; do
		[ -n "$d" ] && rm -rf "$d"
	done
	set -e
}
trap dkms_cleanup EXIT

# --- assertions: each prints FAIL and exits 1 on mismatch ----------------

assert_eq() {
	# assert_eq EXPECTED ACTUAL MESSAGE
	if [ "$1" != "$2" ]; then
		echo "FAIL: $3" >&2
		echo "  expected: $1" >&2
		echo "  actual:   $2" >&2
		exit 1
	fi
}

assert_contains() {
	# assert_contains HAYSTACK NEEDLE MESSAGE
	case "$1" in
		*"$2"*) : ;;
		*) echo "FAIL: $3" >&2; echo "  string does not contain: $2" >&2; exit 1 ;;
	esac
}

assert_not_contains() {
	# assert_not_contains HAYSTACK NEEDLE MESSAGE
	case "$1" in
		*"$2"*) echo "FAIL: $3" >&2; echo "  string unexpectedly contains: $2" >&2; exit 1 ;;
		*) : ;;
	esac
}

assert_file_matches() {
	# assert_file_matches FILE EXTENDED_REGEX MESSAGE
	if ! grep -qE "$2" "$1"; then
		echo "FAIL: $3" >&2
		echo "  file $1 does not match: $2" >&2
		exit 1
	fi
}

assert_file_not_matches() {
	# assert_file_not_matches FILE EXTENDED_REGEX MESSAGE
	if grep -qE "$2" "$1"; then
		echo "FAIL: $3" >&2
		echo "  file $1 unexpectedly matches: $2" >&2
		exit 1
	fi
}

# --- fixture kernel header trees -----------------------------------------

# dkms_make_kdir -> echoes a fresh fake KDIR with the include/ skeleton.
# Callers drop fixture headers into $kdir/include/... afterwards.
dkms_make_kdir() {
	local kdir
	kdir="$(dkms_mktemp_dir)"
	mkdir -p "$kdir/include/linux" \
	         "$kdir/include/uapi/linux/raid"
	echo "$kdir"
}

# --- running the Makefile.in feature_flags target ------------------------

# dkms_run_feature_flags KDIR -> echoes the path to the feature_flags.h
# produced by dkms/Makefile.in's feature_flags target run against KDIR.
# Renders Makefile.in exactly the way bin/build-tarball does.
# Returns non-zero (with a stderr diagnostic) if the target fails; callers
# invoked in $(...) should guard with `|| dkms_fail ...`.
dkms_run_feature_flags() {
	local kdir="$1"
	local work
	work="$(dkms_mktemp_dir)"
	mkdir -p "$work/compat"
	sed 's/@VERSION@/selftest/g' "$REPO_ROOT/dkms/Makefile.in" > "$work/Makefile"
	if ! ( cd "$work" && make --silent feature_flags KDIR="$kdir" >/dev/null 2>&1 ); then
		echo "dkms_run_feature_flags: 'make feature_flags' failed for KDIR=$kdir" >&2
		return 1
	fi
	if [ ! -f "$work/compat/feature_flags.h" ]; then
		echo "dkms_run_feature_flags: feature_flags.h not produced for KDIR=$kdir" >&2
		return 1
	fi
	echo "$work/compat/feature_flags.h"
}

# --- patch application ---------------------------------------------------

# dkms_resolve_kernel_tree -> echoes the path to a tree that contains
# drivers/md/ (the manifest sources the patches and build pipeline apply to).
# Resolution order:
#   1. $KERNEL_TREE        (explicit override, as bin/build-tarball uses)
#   2. $REPO_ROOT          (a feature-composed checkout that carries drivers/md)
#   3. build tooling outputs that carry a composed drivers/md:
#        $REPO_ROOT/build/linux-meshstor-rebuilt     (bin/rebuild-main)
#        $REPO_ROOT/.worktrees/meshstor-main-rebuild (bin/rebuild-meshstor-main)
# Echoes the tree root and returns 0 on success; returns 1 (no output) when no
# drivers/md is found. The meshstor-harness branch deliberately carries no
# drivers/md, so callers must `dkms_skip` on a non-zero return — matching the
# documented "SKIP cleanly without a kernel build tree" contract.
dkms_resolve_kernel_tree() {
	local cand
	for cand in \
		"${KERNEL_TREE:-}" \
		"$REPO_ROOT" \
		"$REPO_ROOT/build/linux-meshstor-rebuilt" \
		"$REPO_ROOT/.worktrees/meshstor-main-rebuild"; do
		[ -n "$cand" ] || continue
		[ -d "$cand/drivers/md" ] || continue
		echo "$cand"
		return 0
	done
	return 1
}

# dkms_flat_manifest_tree [SRC_TREE] -> echoes a temp dir holding the manifest
# sources copied FLAT from SRC_TREE/drivers/md (mirrors bin/build-tarball step 1).
# SRC_TREE defaults to dkms_resolve_kernel_tree. Callers that want SKIP-on-absent
# behaviour should resolve + dkms_skip THEMSELVES before calling (dkms_skip from
# within this $(...)-captured function would only exit the subshell).
dkms_flat_manifest_tree() {
	local src="${1:-}" tree entry
	if [ -z "$src" ]; then
		src="$(dkms_resolve_kernel_tree)" \
			|| dkms_fail "no drivers/md tree found (set KERNEL_TREE=)"
	fi
	tree="$(dkms_mktemp_dir)"
	while IFS= read -r entry; do
		[ -z "$entry" ] && continue
		case "$entry" in \#*) continue ;; esac
		# shellcheck disable=SC2086
		cp "$src"/drivers/md/$entry "$tree/"
	done < "$REPO_ROOT/dkms/manifest.txt"
	echo "$tree"
}

# dkms_patch_guard_skips PATCH TREE -> returns 0 (skip this patch) when PATCH
# carries a `<name>.patch.when` sidecar guard that is NOT satisfied against TREE,
# else 1 (apply). Each guard line is `[!]<relpath>:<grep -E regex>` evaluated
# against TREE (a leading `!` requires the pattern to be ABSENT); the patch
# applies only when every predicate holds. Mirrors bin/build-tarball's loop so
# the production pipeline and the selftests select the same patch subset.
dkms_patch_guard_skips() {
	local p="$1" tree="$2" when="$1.when" cond neg file rx
	[ -f "$when" ] || return 1
	while IFS= read -r cond; do
		cond="${cond%%$'\r'}"
		[ -z "$cond" ] && continue
		case "$cond" in \#*) continue ;; esac
		neg=
		case "$cond" in !*) neg=1; cond="${cond#!}" ;; esac
		file="${cond%%:*}"
		rx="${cond#*:}"
		if grep -Eq -- "$rx" "$tree/$file" 2>/dev/null; then
			[ -n "$neg" ] && return 0
		else
			[ -z "$neg" ] && return 0
		fi
	done < "$when"
	return 1
}

# dkms_apply_all_patches TREE -> applies every dkms/patches/*.patch in glob
# order into TREE with `patch -p1 --fuzz=0`, honoring `.patch.when` guards so
# composition-dependent variants self-select (e.g. the raid queue-limits gating
# 0009 vs 0010). Prints the combined patch(1) output (each hunk prefixed with
# its patch filename). Returns the exit status of the first failing patch, or 0
# if all applied cleanly.
dkms_apply_all_patches() {
	local tree="$1" p out rc=0
	for p in "$REPO_ROOT"/dkms/patches/*.patch; do
		if dkms_patch_guard_skips "$p" "$tree"; then
			printf '### %s (skipped: guard not satisfied)\n' "$(basename "$p")"
			continue
		fi
		if out="$(patch -p1 --fuzz=0 --no-backup-if-mismatch -d "$tree" < "$p" 2>&1)"; then
			printf '### %s\n%s\n' "$(basename "$p")" "$out"
		else
			rc=$?
			printf '### %s\n%s\n' "$(basename "$p")" "$out"
			return "$rc"
		fi
	done
	return 0
}

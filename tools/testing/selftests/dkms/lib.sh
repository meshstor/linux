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

# dkms_flat_manifest_tree -> echoes a temp dir holding the manifest sources
# copied FLAT from drivers/md/ (mirrors bin/build-tarball step 1).
dkms_flat_manifest_tree() {
	local tree entry
	tree="$(dkms_mktemp_dir)"
	while IFS= read -r entry; do
		[ -z "$entry" ] && continue
		case "$entry" in \#*) continue ;; esac
		# shellcheck disable=SC2086
		cp "$REPO_ROOT"/drivers/md/$entry "$tree/"
	done < "$REPO_ROOT/dkms/manifest.txt"
	echo "$tree"
}

# dkms_apply_all_patches TREE -> applies every dkms/patches/*.patch in glob
# order into TREE with `patch -p1 --fuzz=0`. Prints the combined patch(1)
# output (each hunk prefixed with its patch filename). Returns the exit
# status of the first failing patch, or 0 if all applied cleanly.
dkms_apply_all_patches() {
	local tree="$1" p out rc=0
	for p in "$REPO_ROOT"/dkms/patches/*.patch; do
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

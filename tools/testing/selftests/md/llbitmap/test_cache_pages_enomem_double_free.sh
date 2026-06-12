#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Regression test for a double-free (CWE-415) on the llbitmap_cache_pages()
# allocation-failure path, exposed by the FIRST_USE-persist commit
#   "md/llbitmap: persist BITMAP_FIRST_USE clear during init with fail-detect"
# (which rerouted llbitmap_create()'s error path through llbitmap_destroy()).
#
# Root cause:
#   llbitmap_cache_pages() does two allocations:
#       llbitmap->pctl       = kmalloc_array(nr_pages, sizeof(void *), ...);  (A)
#       pctl (the contiguous = kmalloc_array(nr_pages, size, ...);            (B)
#        pctl-block)
#   On (B) failure the code historically did:
#       kfree(llbitmap->pctl);   /* frees A ... */
#       return -ENOMEM;          /* ... but leaves llbitmap->pctl DANGLING */
#   i.e. it freed the pointer array but did NOT NULL llbitmap->pctl (unlike
#   the sibling pctl_blocks-failure path, which does set ->pctl = NULL).
#   llbitmap->nr_pages is still 0 at this point.
#
#   On master this was harmless: llbitmap_create()'s error path was a plain
#   kfree(llbitmap) -- the dangling pointer lived inside the freed struct and
#   was never touched again.  The FIRST_USE-persist commit changed that error
#   path to call llbitmap_destroy() -> llbitmap_free_pages(), whose guard is
#       if (!llbitmap->pctl) return;
#   The dangling (non-NULL) pointer slips past the guard; nr_pages==0 makes the
#   loops no-ops; and the function ends with
#       kfree(llbitmap->pctl);     <-- SECOND free of A == double-free.
#
# Fix: NULL llbitmap->pctl after the kfree in the (B)-failure path, mirroring
#   the pctl_blocks path.  Then the free_pages guard fires and there is no
#   double-free.
#
# Mechanism (fault injection):
#   The (B) failure is an ENOMEM path, so we drive it with the slab fault
#   injector (CONFIG_FAILSLAB).  We scope failures to the mdadm process via
#   the task filter (/proc/self/make-it-fail), so the rest of the system is
#   unaffected, and -- when possible -- we narrow eligibility to the kmalloc
#   buckets the pctl-block (B) lands in via the cache filter, so allocation (A)
#   (8 bytes/elem -> a small bucket) keeps succeeding while (B) can fail.
#   A create is then attempted many times; on a buggy kernel one of the
#   iterations fails allocation (B) after (A) succeeded and triggers the
#   double-free, which KASAN (or SLUB_DEBUG) reports.
#
# Requirements (else SKIP):
#   - CONFIG_FAILSLAB + CONFIG_FAULT_INJECTION_DEBUG_FS, debugfs mounted.
#   - CONFIG_KASAN (preferred) or CONFIG_SLUB_DEBUG, so the double-free is
#     actually diagnosed rather than silently corrupting the heap.
#
# Verdict:
#   PASS  no double-free / KASAN / invalid-free / slab-corruption splat across
#         all create attempts (the ->pctl = NULL fix is present).
#   FAIL  a double-free / invalid-free / KASAN / slab-corruption splat appeared
#         (the bug is present).
#   SKIP  fault injection or a memory debugger is unavailable, an injector
#         knob did not take, no create attempt could be issued, or the
#         injector never fired (a clean run without injections proves
#         nothing and must not be reported as PASS).
#
# NOTE: this is a probabilistic reproducer (standard for slab fault injection).
#   Injector engagement is enforced, not assumed: every knob write is read
#   back, and the run must log at least one "FAULT_INJECTION: forcing a
#   failure." line (verbose=1) or the verdict is SKIP.  The iteration count
#   and probability are tunables (LLBITMAP_FI_ITERS, LLBITMAP_FI_PROB).
#   A FAIL is always conclusive: the bug is present.

set -u

DIR="$(dirname "$0")"
. "$DIR/lib.sh"

llbitmap_require_root
llbitmap_require_modules
llbitmap_require_tools

ITERS="${LLBITMAP_FI_ITERS:-400}"
PROB="${LLBITMAP_FI_PROB:-30}"
LOOP_SIZE_MB=64

DEBUGFS=/sys/kernel/debug
FI=$DEBUGFS/failslab

# --- requirement checks ------------------------------------------------------
kconf() {
	(zcat /proc/config.gz 2>/dev/null || cat "/boot/config-$(uname -r)" 2>/dev/null) \
		| grep -q "^$1=y"
}

[ -d "$FI" ] || {
	mount | grep -q "$DEBUGFS" || sudo mount -t debugfs none "$DEBUGFS" 2>/dev/null || true
}
[ -d "$FI" ] || llbitmap_skip \
	"failslab unavailable ($FI; need CONFIG_FAILSLAB + CONFIG_FAULT_INJECTION_DEBUG_FS)"

if ! kconf CONFIG_KASAN && ! kconf CONFIG_SLUB_DEBUG; then
	# SLUB_DEBUG may still be runtime-disabled, but without either we cannot
	# reliably diagnose a double-free.
	llbitmap_skip "no CONFIG_KASAN and no CONFIG_SLUB_DEBUG -- double-free would not be diagnosed"
fi

# --- save & restore failslab state -------------------------------------------
FI_KEYS="probability interval times space verbose task-filter ignore-gfp-wait cache-filter"
declare -A FI_SAVED
SLAB_FAILSLAB_SET=()

fi_get() { cat "$FI/$1" 2>/dev/null; }

# A knob that silently fails to take leaves the injector disabled and the
# whole run would PASS having tested nothing.  Write strictly and read the
# value back; an unconfigurable injector is an unfit environment (SKIP),
# never a pass.
fi_set() {
	echo "$2" | sudo tee "$FI/$1" >/dev/null 2>&1 ||
		llbitmap_skip "cannot write failslab knob $1=$2"
	[ "$(fi_get "$1")" = "$2" ] ||
		llbitmap_skip "failslab knob $1: wrote '$2', reads back '$(fi_get "$1")'"
}

restore_fi() {
	set +e
	for k in $FI_KEYS; do
		[ -n "${FI_SAVED[$k]:-}" ] && echo "${FI_SAVED[$k]}" | sudo tee "$FI/$k" >/dev/null 2>&1
	done
	for s in "${SLAB_FAILSLAB_SET[@]:-}"; do
		echo 0 | sudo tee "/sys/kernel/slab/$s/failslab" >/dev/null 2>&1
	done
	set -e
}

fi_cleanup() {
	set +e
	# Make sure no stray make-it-fail task or injector config survives.
	restore_fi
	rm -f "$WRAP" 2>/dev/null
	llbitmap_cleanup
	set -e
}
trap fi_cleanup EXIT

for k in $FI_KEYS; do
	FI_SAVED[$k]="$(fi_get "$k")"
done

# --- configure the injector: task-scoped, GFP_KERNEL-eligible ----------------
fi_set probability "$PROB"
fi_set interval 1
fi_set times -1
fi_set space 0
# verbose>=1 makes each injected failure log a (rate-limited)
# "FAULT_INJECTION: forcing a failure." line; the engagement check after
# the create loop keys off it.
fi_set verbose 1
fi_set task-filter Y		# only fail tasks flagged make-it-fail (safe for the host)
fi_set ignore-gfp-wait N		# allow failing GFP_KERNEL (cache_pages uses GFP_KERNEL)

# Narrow to the kmalloc buckets the pctl-block (B) is likely to use, so the
# pointer array (A) (a tiny bucket) keeps succeeding.  If we can mark any of
# these caches, enable the cache filter; otherwise fall back to broad fuzzing.
CACHE_NARROWED=0
for c in kmalloc-96 kmalloc-128 kmalloc-192 kmalloc-256 kmalloc-512; do
	f="/sys/kernel/slab/$c/failslab"
	if [ -w "$f" ] && echo 1 | sudo tee "$f" >/dev/null 2>&1; then
		SLAB_FAILSLAB_SET+=("$c")
		CACHE_NARROWED=1
	fi
done
if [ "$CACHE_NARROWED" -eq 1 ]; then
	fi_set cache-filter Y
	echo "  fault scope: cache-filter on ${SLAB_FAILSLAB_SET[*]}, task-filtered, prob=$PROB%"
else
	fi_set cache-filter N
	echo "  fault scope: all kmalloc caches, task-filtered, prob=$PROB% (broad fuzz)"
fi

# --- mdadm wrapper that flags itself make-it-fail before exec -----------------
WRAP="$(mktemp /tmp/llbitmap-fi-mdadm.XXXXXX.sh)"
cat > "$WRAP" <<EOF
#!/bin/bash
echo 1 > /proc/self/make-it-fail 2>/dev/null
exec "$MDADM" "\$@"
EOF
chmod +x "$WRAP"

# --- devices -----------------------------------------------------------------
LA=$(llbitmap_make_loop $LOOP_SIZE_MB)
LB=$(llbitmap_make_loop $LOOP_SIZE_MB)
llbitmap_alloc_ms_dev >/dev/null
MS_DEV="$LLBITMAP_TEST_MS_DEV"

echo "=== llbitmap cache_pages ENOMEM double-free reproducer ==="
echo "  members: $LA $LB  ms: $MS_DEV  iters: $ITERS"

splat_seen() {
	llbitmap_dmesg_contains 'KASAN: double-free' ||
	llbitmap_dmesg_contains 'KASAN: invalid-free' ||
	llbitmap_dmesg_contains 'double-free or invalid-free' ||
	llbitmap_dmesg_contains 'Object already free' ||
	llbitmap_dmesg_contains 'double free' ||
	llbitmap_dmesg_contains 'kernel BUG at mm/slub' ||
	llbitmap_dmesg_contains 'general protection fault' ||
	llbitmap_dmesg_contains 'BUG: KASAN'
}

llbitmap_dmesg_clear

attempts=0
for i in $(seq 1 "$ITERS"); do
	# Create under fault injection. mdadm RUN_ARRAY -> md_run ->
	# md_bitmap_create -> llbitmap_create -> read_sb -> llbitmap_init ->
	# llbitmap_cache_pages, where allocation (B) may fail.
	sudo "$WRAP" --create "$MS_DEV" \
		--level=1 --metadata=1.2 --raid-devices=2 --homehost=any \
		--bitmap=lockless --assume-clean "$LA" "$LB" --run --force \
		>/dev/null 2>&1
	attempts=$((attempts + 1))

	# Tear down whatever (if anything) came up -- NOT via the wrapper, so
	# cleanup allocations are not fault-injected.
	sudo "$MDADM" --stop "$MS_DEV" >/dev/null 2>&1 || true

	if splat_seen; then
		restore_fi
		echo "  --- offending dmesg ---"
		sudo dmesg | tail -40 | grep -iE 'kasan|double|free|slub|llbitmap|BUG|fault' | head -20
		echo "  (bug present; need ->pctl = NULL in cache_pages (B)-failure path)"
		llbitmap_fail "double-free/corruption splat after $i fault-injected creates"
	fi
done

restore_fi

[ "$attempts" -gt 0 ] || llbitmap_skip "no create attempt issued"

# Prove the injector actually engaged: count the (rate-limited)
# "FAULT_INJECTION: forcing a failure." lines logged since our dmesg clear.
# Zero injections means zero coverage -- SKIP, never PASS.
injected=$(sudo dmesg 2>/dev/null | grep -c 'FAULT_INJECTION: forcing a failure')
[ "$injected" -gt 0 ] || llbitmap_skip \
	"fault injector never fired across $attempts creates (0 FAULT_INJECTION log lines) -- nothing tested"

echo "  completed $attempts create attempts, $injected logged injections, no splat"
llbitmap_pass "no double-free/corruption across $attempts creates with $injected fault injections"

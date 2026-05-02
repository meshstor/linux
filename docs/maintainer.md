# Maintainer guide

Internal reference for maintainers of meshstor-ms. Covers branch model,
upstream-rebase workflow, compat-shim authoring, the
feature-flag-detection design, and the two non-obvious gotchas
(KBUILD_EXTMOD, sysctl-sentinel) that have already cost engineering time.

For end-user docs see [install.md](install.md), [admin.md](admin.md).
For release engineering see [build.md](build.md). For the static
distro/kernel matrix see [compat.md](compat.md).

## Branch model

The repo is a Linux kernel fork with two long-lived branches:

```
upstream/master ── master ──┐
                             ├── meshstor-main (our integration work)
```

- **`master`** tracks `upstream/master` 1:1, verbatim. Every commit on
  `master` exists upstream. Never modified locally.
- **`meshstor-main`** carries our integration commits on top of `master`.
  Cherry-picked feature commits (per-bucket-arrays, latency-EWMA,
  raid1↔raid10 takeover, llbitmap), DKMS packaging metadata, compat
  shims, this documentation set.

Upstream rebase keeps `master` in sync with `upstream/master`, then
rebases `meshstor-main` onto the new `master`. Conflicts surface in
the cherry-picked feature commits or in the pre-rename patches; the
rest is side-by-side files that don't collide.

The original branching decision is in
[`docs/superpowers/specs/2026-05-01-meshstor-md-dkms-design.md`](superpowers/specs/2026-05-01-meshstor-md-dkms-design.md).

## Upstream rebase workflow

### Routine cadence

Rebase whenever upstream lands changes that affect `drivers/md/` or
when a new RHEL/Ubuntu kernel ships that we want to support. A
typical cycle is once per upstream `-rcN` cycle (~weekly during merge
window, monthly during stabilization).

### Step-by-step

```bash
# 1. Fetch upstream changes.
git fetch upstream master
```

```bash
# 2. Fast-forward master.
git checkout master
git merge --ff-only upstream/master
```

If `--ff-only` fails, `master` has diverged from upstream — investigate
before continuing. We never carry local commits on `master`.

```bash
# 3. Rebase meshstor-main onto the new master.
git checkout meshstor-main
git rebase master
```

Resolve conflicts as they appear. The patterns below cover ~90% of
real-world cases.

### Conflict resolution patterns

**Pattern A: upstream renamed a function our integration commits use.**

Symptom: rebase stops in a feature commit (e.g., the latency-EWMA
commit) with a conflict like:

```
<<<<<<< HEAD
        old_function_name(arg);
=======
        ewma_aware_function(arg);
>>>>>>> latency-ewma feature commit
```

Fix: keep our side's logic but use the new name. If the rename is
mechanical (`s/old_function_name/new_name/g`), do that across the
conflicting hunks. Then `git add` + `git rebase --continue`.

**Pattern B: upstream added a parameter to a function we wrap in `compat/compat.h`.**

Symptom: rebase succeeds but a later build fails with "too few
arguments to function". Our wrapper in `compat.h` is now wrong for
the new upstream signature.

Fix: update the wrapper. The relevant code is in
[`dkms/compat/compat.h`](../dkms/compat/compat.h). Add the new
parameter to the inline/macro and propagate sensible defaults if
older kernels don't support it. Re-add the corresponding `HAVE_*`
detection in [`dkms/Makefile.in`](../dkms/Makefile.in)'s
`feature_flags` recipe if the new signature differs detectably.

**Pattern C: upstream changed context lines around a pre-rename patch.**

Symptom: `dkms/scripts/build-tarball.sh` fails at step 4 (apply
patches) with `patch: **** malformed patch at line N` or `Hunk #1
FAILED`.

Fix: regenerate the patch.

```bash
# Regenerate from a fresh tarball-staging tree.
dkms/scripts/build-tarball.sh 0.1.0  # Will fail at the patch step;
# the partial tree is left under build/meshstor-ms-0.1.0/

# Apply the patch manually with --merge (gets you to a usable state):
patch -p1 -d build/meshstor-ms-0.1.0/ --merge \
    < dkms/patches/000N-foo.patch
# Edit conflict markers in the affected files.

# Generate a new patch from the fixed tree.
cd build/meshstor-ms-0.1.0
diff -u --recursive ../meshstor-ms-0.1.0-original/ . \
    > ../../dkms/patches/000N-foo.patch.new
mv ../../dkms/patches/000N-foo.patch.new ../../dkms/patches/000N-foo.patch
```

Verify the new patch applies cleanly by re-running `build-tarball.sh`.

### Verification before merging the rebase

Build against all four target kernels:

```bash
for K in /tmp/kdevs/r10/usr/src/kernels/6.12.0-* \
         /tmp/kdevs/r9/usr/src/kernels/5.14.0-* \
         /tmp/kdevs/u24/usr/src/linux-headers-6.14.0-* \
         /tmp/kdevs/u26/usr/src/linux-headers-6.17.0-*; do
    echo "=== $K ==="
    env -u KDIR KDIR=$K dkms/scripts/build-tarball.sh 0.1.0 \
        2>&1 | tail -2
done
```

All four must report `Built: build/meshstor-ms-0.1.0.dkms.tar.gz`.

Then run smoke tests on the two baremetal hosts (see [§ cross-distro
test workflow](#cross-distro-test-workflow) below).

If everything passes:

```bash
git push --force-with-lease origin meshstor-main
```

Force-push is acceptable on `meshstor-main` because we are the only
consumer (no downstream consumers depend on its commit history).

## Compat shim authoring

When a kernel API change breaks our build, you have two options:
header shim or source-level patch. The decision tree:

```
Is the change…
├── …a missing symbol or new helper function?
│       → Header shim in dkms/compat/compat.h
│
├── …a function-signature drift (same name, different args/types)?
│       → Header shim (wrapper macro/inline) in compat/compat.h
│
├── …a struct field added or removed?
│       → Patch in dkms/patches/  (can't add fields to kernel-owned structs)
│
├── …a callback signature change in a struct table?
│       → Patch (the table assignment must be conditionally rewritten)
│
└── …source-level syntax that differs across versions?
        → Patch
```

Heuristic: if the change requires editing more than 3 callsites or
modifying a struct definition or a `.foo = bar`-style table, it's a
patch. Otherwise it's a header shim.

### Adding a header shim

1. Add the symbol to the feature-flag detection list in
   [`dkms/Makefile.in`](../dkms/Makefile.in)'s `feature_flags` recipe.
   For a simple-name detection, append a line to the
   `for sym_hdr in \` block:

   ```makefile
   for sym_hdr in \
       bio_submit_split_bioset:linux/bio.h \
       ... \
       new_symbol_name:linux/new_header.h ; do
   ```

   For a signature-drift detection (where the symbol exists on every
   supported kernel but its arguments differ), add a custom `grep` or
   `awk` block after the loop, modeled on the existing
   `HAVE_BADBLOCKS_CHECK_SECTOR_T_OUTPUTS` detection. See lines around
   `dkms/Makefile.in:80-90`.

2. Add the shim to [`dkms/compat/compat.h`](../dkms/compat/compat.h),
   gated on `#ifndef HAVE_<NAME>` (or
   `#if !defined(HAVE_<NAME>) && !defined(<symbol>)` if the symbol
   might be a macro). Follow the existing patterns:

   ```c
   #ifndef HAVE_NEW_SYMBOL_NAME
   static inline int new_symbol_name(args) {
       /* fallback implementation for older kernels */
   }
   #endif
   ```

3. Build against the four target kernels to verify both branches
   compile.

### Adding a patch

1. Apply the conceptual change to a copy of the upstream source as
   you'd want it to look in the post-build tarball — but using the
   pre-rename names (`md_*`, not `ms_*`), since patches apply before
   the rename pass.

2. Generate a unified diff:

   ```bash
   diff -u --recursive original/ modified/ > dkms/patches/000N-description.patch
   ```

   The patch must use `-p1` paths (i.e., `a/raid1.c`, `b/raid1.c`)
   matching the tarball-flat layout that `build-tarball.sh` works in.

3. Bracket version-conditional changes in `#if LINUX_VERSION_CODE`
   blocks, using `KERNEL_VERSION(MAJOR, MINOR, PATCH)`, so the same
   patch produces correct behavior across our supported range.

4. Update [`dkms/patches/README.md`](../dkms/patches/README.md) with
   a new row in the "Listing" table.

5. Verify all four target kernels build clean.

## Feature-flag detection (vs `LINUX_VERSION_CODE`)

We do **not** use `LINUX_VERSION_CODE` to gate compat shims. Reason:
RHEL backports.

Red Hat backports features into RHEL 9's "5.14" kernel from upstream
versions as recent as 6.10+. So the kernel that reports itself as
`5.14.0-611.49.1.el9_7` actually has `bdev_file_open_by_dev`,
`queue_limits_start_update`, `BLK_FEAT_ATOMIC_WRITES`, etc., that
vanilla 5.14 does not. A `#if LINUX_VERSION_CODE >= KERNEL_VERSION(6,9,0)`
gate would silently disable those features on RHEL 9, breaking the
build.

Solution: scan the target kernel's actual headers at module-build
time and emit `#define HAVE_<NAME>` for each present symbol/signature.

The detection logic lives in [`dkms/Makefile.in`](../dkms/Makefile.in),
in the `feature_flags` recipe (within the `ifeq ($(KBUILD_EXTMOD),)`
block — see [the KBUILD_EXTMOD gotcha](#the-kbuild_extmod-gotcha) below
for why it's gated this way). The recipe:

1. Iterates over a list of `symbol:header` pairs.
2. For each, greps the target kernel's `$(KDIR)/include/<header>` for
   the symbol; if found, emits `#define HAVE_<UPPER_SYMBOL> 1`.
3. Adds custom signature-drift detections (e.g.,
   `HAVE_BADBLOCKS_CHECK_SECTOR_T_OUTPUTS` greps the function
   signature, not just the name).
4. Writes the result to `compat/feature_flags.h`, which `compat.h`
   includes.

Output: every `compat.h` shim is gated on `HAVE_<NAME>` — present on
the target kernel = shim compiled out, absent = shim active.

To add a new detection, see [§ adding a header shim](#adding-a-header-shim).

## The KBUILD_EXTMOD gotcha

Symptom: DKMS install fails with this in `make.log`:

```
make: *** No targets.  Stop.
```

The wrapper Makefile defines `all:`, but make sees no targets. This
cost ~30 minutes of debugging during initial DKMS bring-up.

### Root cause

DKMS invokes the wrapper with:

```bash
make -j20 KERNELRELEASE=<kver> KDIR=/lib/modules/<kver>/build
```

Note: `KERNELRELEASE=` is set **on the command line**, not just as an
inherited env var.

The conventional out-of-tree-module Makefile guard is:

```makefile
ifeq ($(KERNELRELEASE),)
    # …user-side targets: all, clean, modules_install…
else
    # …kbuild-side: obj-m := …
endif
```

Under DKMS, the outer invocation already has `KERNELRELEASE` set, so
`ifeq ($(KERNELRELEASE),)` evaluates to **false** and the user-side
targets disappear. Make sees nothing it knows how to build.

### Fix

Use `KBUILD_EXTMOD` instead of `KERNELRELEASE` for the guard.
`KBUILD_EXTMOD` is set only by kbuild itself during the
`make -C $KDIR M=$M` recursion — i.e., when kbuild has reached back
into our Makefile to extract `obj-m`. It's NOT set by DKMS in the
outer invocation.

The fix is in [`dkms/Makefile.in:36`](../dkms/Makefile.in):

```makefile
ifeq ($(KBUILD_EXTMOD),)
    # …user-side targets: all, feature_flags, clean, modules_install…
endif
```

The full guard block runs from line 36 to line 114.

### How to remember this

Every time you write a wrapper Makefile that DKMS will invoke, use
`KBUILD_EXTMOD`. Saved as a feedback memory at
`/home/mykola/.claude/projects/-home-mykola-sync-linux-meshstor/memory/feedback_dkms_makefile_guard.md`
so future-Claude doesn't re-discover this.

## The sysctl-sentinel patch case study

Symptom: kernel panic on first `modprobe ms_mod` on RHEL 9 (5.14
kernel). vng VM hangs entirely; in baremetal, the host crashes and
kdump captures a panic in `sysctl_check_table`.

### Root cause

Linux 6.4 introduced `register_sysctl_sz()` and removed the
sentinel-row requirement from sysctl tables. Pre-6.4 kernels (RHEL
9.x is 5.14) require the trailing `{}` sentinel entry that says
"end of table"; without it, `sysctl_check_table` walks past the
table end and dereferences garbage.

Upstream md uses `register_sysctl()` (no sentinel) on post-6.4. Our
build picked up the no-sentinel form and shipped it everywhere,
causing the panic on RHEL 9.

### Fix

[`dkms/patches/0004-sysctl-table-sentinel-pre-6.4-compat.patch`](../dkms/patches/0004-sysctl-table-sentinel-pre-6.4-compat.patch)
conditionally adds the sentinel back. The patch is gated on
`#ifndef HAVE_SYSCTL_REGISTER_TABLE_NO_SENTINEL`, which the feature-flag
detection sets when the target kernel exports `register_sysctl_sz` (added
upstream in 6.4).

The detection is in `dkms/Makefile.in`'s `feature_flags` recipe. See
the `register_sysctl_sz:linux/sysctl.h` line in the `for sym_hdr` block.

### Diagnostic flow that found this

The chain that led here:

1. `modprobe ms_mod` hung on RHEL 9 (5.14). VM lockup, no log output.
2. Configured kdump on the RHEL 9 baremetal host, retried, captured a
   panic trace in `/var/crash/`.
3. Trace pointed at `sysctl_check_table+0x...`.
4. Diff with upstream md core showed the sysctl registration changed
   from `register_sysctl_table` (with sentinel) to `register_sysctl`
   (without) at upstream commit ~6.4.
5. Wrote the conditional patch + the detection flag.

When debugging a similar symptom in the future: configure kdump
first, then reproduce on baremetal, then read the trace.

## Cross-distro test workflow

Minimum-pass criteria for accepting a rebase or compat-shim change.
Run in this order:

```bash
# 1. Tarball builds clean against all four target kernel header trees.
for K in /tmp/kdevs/r10/usr/src/kernels/6.12.0-* \
         /tmp/kdevs/r9/usr/src/kernels/5.14.0-* \
         /tmp/kdevs/u24/usr/src/linux-headers-6.14.0-* \
         /tmp/kdevs/u26/usr/src/linux-headers-6.17.0-*; do
    echo "=== $K ==="
    env -u KDIR KDIR=$K dkms/scripts/build-tarball.sh 0.1.0 \
        2>&1 | tail -2
done
```

Each line must end with `Built: …`.

```bash
# 2. Build the rpm, install on RHEL 10 baremetal, verify modprobe.
dkms/scripts/build-rpm.sh 0.1.0 /tmp/test-release
scp /tmp/test-release/RPMS/noarch/meshstor-ms-dkms-0.1.0-*.rpm \
    mykola@192.168.200.32:/tmp/ms.rpm
ssh mykola@192.168.200.32 'sudo rpm -e meshstor-ms-dkms 2>/dev/null
    sudo rpm -i /tmp/ms.rpm
    sudo modprobe ms_mod raid1_ms raid10_ms
    cat /proc/msstat'
```

Expected: `Personalities : [raid1] [raid10]` followed by `unused devices: <none>`.

```bash
# 3. Same on RHEL 9 baremetal.
scp /tmp/test-release/RPMS/noarch/meshstor-ms-dkms-0.1.0-*.rpm \
    mykola@192.168.200.35:/tmp/ms.rpm
ssh mykola@192.168.200.35 'sudo rpm -e meshstor-ms-dkms 2>/dev/null
    sudo rpm -i /tmp/ms.rpm
    sudo modprobe ms_mod raid1_ms raid10_ms
    cat /proc/msstat'
```

Same expected output.

```bash
# 4. raid1 + raid10 array assemble on the RHEL 10 host.
ssh mykola@192.168.200.32 'sudo truncate -s 256M /tmp/d{0,1,2,3}.img
    for i in 0 1 2 3; do sudo losetup /dev/loop$i /tmp/d$i.img; done
    sudo /tmp/msadm --create /dev/ms0 --level=raid1 --raid-devices=2 \
        --metadata=1.2 --bitmap=internal --run /dev/loop0 /dev/loop1
    sudo dd if=/dev/urandom of=/dev/ms0 bs=1M count=64 oflag=direct 2>&1 | tail -1
    sudo /tmp/msadm --stop /dev/ms0
    sudo /tmp/msadm --zero-superblock /dev/loop0 /dev/loop1
    sudo /tmp/msadm --create /dev/ms0 --level=raid10 --raid-devices=4 \
        --metadata=1.2 --bitmap=internal --run \
        /dev/loop0 /dev/loop1 /dev/loop2 /dev/loop3
    sudo dd if=/dev/urandom of=/dev/ms0 bs=1M count=64 oflag=direct 2>&1 | tail -1
    sudo /tmp/msadm --stop /dev/ms0
    sudo losetup -D
    sudo rm -f /tmp/d*.img'
```

Both `dd` lines should report ~64 MB written.

```bash
# 5. Optional: full perf rerun (~6 minutes per host).
#    Only required if the rebase touched md core or bitmap code.
ssh mykola@192.168.200.32 'bash /tmp/ms-perf.sh' > /tmp/perf-r10.log
ssh mykola@192.168.200.35 'bash /tmp/ms-perf.sh' > /tmp/perf-r9.log
```

Compare to the prior baseline in
[`notes/perf-baremetal-r10-2026-05-02.log`](../notes/perf-baremetal-r10-2026-05-02.log)
and [`notes/perf-baremetal-r9-2026-05-02.log`](../notes/perf-baremetal-r9-2026-05-02.log).
Look for >5% regressions on any line; investigate before merging.

If criteria 1–4 pass, the change is safe to merge into `meshstor-main`.

## See also

- [architecture.md](architecture.md) — vocabulary, rename pass mechanics
- [build.md](build.md) — what the release pipeline does after this guide's work
- [compat.md](compat.md) — current shim inventory
- [`dkms/patches/README.md`](../dkms/patches/README.md) — patch series conventions

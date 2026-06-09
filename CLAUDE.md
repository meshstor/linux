# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A Linux-kernel fork that ships `meshstor-ms` — a **parallel `ms_*` MD/RAID
subsystem** delivered as a DKMS package. It does not replace the kernel's
built-in `md_mod` (which is `CONFIG_MD=y` / linked into `vmlinux` on every
supported distro); it coexists with it. Modules, symbols, `/dev` nodes, sysfs
paths, and the `/proc` file all use distinct `ms`/`ms_*` names, while the
**on-disk superblock format stays bit-for-bit identical** to kernel md so disks
can move between the two by re-attaching.

The package backports selected upstream md performance work onto kernels that
don't have it yet: lockless bitmap (llbitmap), per-rdev latency-EWMA read
balancing, per-bucket barrier arrays for raid10, and zero-copy raid1→raid10
takeover.

`docs/` is the authoritative, detailed reference (`docs/architecture.md`,
`build.md`, `maintainer.md`, `compat.md`, `performance.md`,
`perftest-playbook.md`). Read it for anything below in depth. `docs/superpowers/`
is a **gitignored, local-only** design archive — committed docs no longer link
into it, and only specs from `2026-05-10` onward survive on disk. When in doubt,
trust the actual files in `bin/`, `dkms/`, and `tools/` over prose.

## The single most important mental model: the rename pass

**You edit upstream-named files (`md.c`, `raid1.c`, `mddev`, `MD_*`). The
`ms_*` product is generated — never edit `ms.c` directly; it does not exist in
the source tree.**

- `drivers/md/` holds kernel sources at their **canonical upstream paths and
  names**, kept rebaseable. Our feature commits modify these in place exactly
  where upstream would.
- At **tarball-assembly time** (once per build, not per module-build),
  `bin/build-tarball` runs `sed -f dkms/rename.sed` over every `.c`/`.h`,
  translating `md_* → ms_*`, `mddev → mssev`, `MD_* → MS_*`, plus string
  literals (`"mdstat"→"msstat"`, log prefixes, `/dev` name templates), then
  renames files (`md.c→ms.c`, `raid1.c→raid1_ms.c`, …).
- A **keep-list** protects identifiers that must stay identical to upstream:
  UAPI header paths (`<linux/raid/md_p.h>`), and all `MD_SB_*`, `MD_FEATURE_*`,
  `MD_DISK_*`, `MD_RECOVERY_*`, `MD_BITMAP_*` on-disk-format constants. The
  keep-list is **auto-generated per build** by grepping the running kernel's
  UAPI headers, so it self-updates as upstream adds constants. Renaming any of
  these would break the kernel-header include path or the on-disk-format
  compatibility guarantee.

Module set produced: `ms_mod.ko` (= `ms.o + ms-bitmap.o + ms-llbitmap.o`; like
upstream, llbitmap is *inside* the core module, not a separate `.ko`),
`raid1_ms.ko`, `raid10_ms.ko`. `raid1-10_ms.c` is `#include`d source shared by
the two personalities. RAID0/5/6 and md-cluster are intentionally out of scope
(absent from `dkms/manifest.txt`).

## Directory split (keep it intact)

- **`drivers/md/` is upstream-canonical.** Never add meshstor-only files or
  compat shims here — that would dirty the rebase surface.
- **`dkms/` is ours alone.** Upstream never touches it. The rename rules
  (`rename.sed`), compat shims (`compat/compat.h`), structural patches
  (`patches/`), packaging templates (`dkms.conf.in`, `Makefile.in`, `debian/`,
  `rpm/`), and the manifest (`manifest.txt`) all live here.
- `bin/` = build / perf / deploy helpers. `tools/testing/selftests/` = tests.
- `build/`, `results/`, `.worktrees/`, `docs/superpowers/` are **gitignored**.

## Branch model

- **`master`** tracks `upstream/master` verbatim — never carry local commits.
- **`meshstor-harness`** (the usual working branch) carries packaging, `bin/`
  tooling, docs, and selftests — everything that is *not* a kernel md feature.
- **Feature branches** carry one md feature each, rebased on a torvalds master
  snapshot: `md-latency-ewma`, `per-bucket-arrays`, `takeover`,
  `llbitmap-fixes`, etc.
- `bin/rebuild-main` **composes** these into a working tree; it is the bridge
  between the branch model and the build pipeline.

## Build pipeline (three stages)

```
bin/rebuild-main [feature ...]   →  build/linux-meshstor-rebuilt/   (composed kernel tree)
bin/build-tarball <version>      →  build/meshstor-ms-<ver>.dkms.tar.gz
bin/build-rpm | build-deb[-direct] <version>  →  installable package
```

### 1. `bin/rebuild-main` — reconstruct a buildable tree from upstream + branches

Clones torvalds/linux, slims it with `git filter-repo` to `drivers/md` +
`tools/testing/selftests/md`, then applies branches as patch series
(`git format-patch` + `git am`) in the order given.

```bash
bin/rebuild-main                                   # filtered upstream only
bin/rebuild-main md-latency-ewma                   # + one feature
bin/rebuild-main per-bucket-arrays md-latency-ewma
bin/rebuild-main --with-harness md-latency-ewma    # also bake in meshstor-harness (selftests/dkms/docs)
bin/rebuild-main --no-fetch ...                    # skip refreshing the cached mirror
```

Output goes to `build/linux-meshstor-rebuilt/` (branch `meshstor-main-rebuilt`,
sentinel `.meshstor-rebuilt`). It will only wipe a dir bearing that sentinel.
Requires `git >= 2.30` and `git-filter-repo`. Reads branches from
`git@github.com:meshstor/linux` (override `MESHSTOR_URL=` to HTTPS when no SSH
agent, e.g. under `sudo`/CI).

### 2. `bin/build-tarball <version>` — assemble the DKMS source tarball

Reads `drivers/md/` from `KERNEL_TREE` (**default `build/linux-meshstor-rebuilt`**,
so run `rebuild-main` first; or `KERNEL_TREE=$(git rev-parse --show-toplevel)`
to package straight from this repo). Nine steps, **order matters**:

1. Copy files listed in `dkms/manifest.txt` from `KERNEL_TREE/drivers/md/`.
2. Copy `dkms/compat/`.
3. Drop a **stub** `feature_flags.h` (the real one is generated at
   module-build time — see DKMS below).
4. Apply `dkms/patches/*.patch` (glob-sorted) — **before** the rename, so
   patches use upstream `md_*` names.
5. Run the rename pass (`rename.sed` + auto-generated keep-list).
6. Rename source filenames.
7. Inject `extern int ms_major;` into `ms.h` and `MODULE_VERSION(MS_VERSION)`
   into `ms.c` (bridges the rename produces but upstream doesn't have).
8. Render `dkms.conf.in` / `Makefile.in` (`@VERSION@` substitution).
9. `tar czf build/meshstor-ms-<ver>.dkms.tar.gz`.

`KDIR=` (default `/lib/modules/$(uname -r)/build`) is the header tree scanned
for the rename keep-list.

### 3. Packaging

```bash
bin/build-rpm <ver> <outdir>          # noarch DKMS source rpm via rpmbuild -bb
bin/build-deb <ver> [outdir]          # native Debian/Ubuntu (dpkg-buildpackage)
bin/build-deb-direct <ver> [outdir]   # cross-build a .deb from RHEL (dpkg-deb, no debhelper)
```

Both consume the same tarball. The rpm `dist` tag (`.el10`) is cosmetic; a
noarch DKMS package is portable across distros.

## Compat strategy (this is non-obvious — read before touching it)

**Gate on detected capabilities (`HAVE_*`), never on `LINUX_VERSION_CODE`.**
RHEL backports recent features into its "5.14" kernel, and Ubuntu HWE backports
into older releases, so a version check both misses backported capabilities and
mis-detects them.

Detection runs at **module-build time** in `dkms/Makefile.in`'s `feature_flags`
recipe: it greps the *target* kernel's headers for each `symbol:header` pair
(and a few signature-shape `awk`/`grep` probes) and emits `#define HAVE_<NAME> 1`
into `compat/feature_flags.h`, which `compat.h` includes.

Decision tree for a new break:

- Missing symbol / new helper / signature drift (same name, different args)
  → **header shim** in `dkms/compat/compat.h`, gated `#ifndef HAVE_<NAME>`.
  Add the detection to `dkms/Makefile.in` (`sym_hdr` loop, or a custom probe
  for signature drift).
- Struct field added/removed, callback-table signature change, or
  version-conditional source syntax → **patch** in `dkms/patches/`. Patches are
  `NNNN-description.patch`, `-p1` paths (`a/raid1.c`), use **pre-rename `md_*`
  names**, and prefer `#ifdef HAVE_FOO` over `#if LINUX_VERSION_CODE`. Document
  each in `dkms/patches/README.md`.

Two gotchas already paid for in engineering time (full write-ups in
`docs/maintainer.md`):

- **`KBUILD_EXTMOD`, not `KERNELRELEASE`, guards the wrapper Makefile.** DKMS
  sets `KERNELRELEASE=` on the *outer* command line, so the conventional
  `ifeq ($(KERNELRELEASE),)` guard drops all user-side targets → `make: ***
  No targets. Stop.` `KBUILD_EXTMOD` is set only by kbuild's `M=` recursion
  (`dkms/Makefile.in:36`).
- **sysctl sentinel** — pre-6.4 kernels (RHEL 9) need the trailing `{}` table
  sentinel; its absence panics on first `modprobe`. Handled by
  `0004-sysctl-table-sentinel-pre-6.4-compat.patch`, gated on
  `HAVE_SYSCTL_REGISTER_TABLE_NO_SENTINEL`.

## Caching

- **Upstream mirror.** `rebuild-main` keeps a full bare clone of torvalds/linux
  at `build/torvalds-linux.git` (~5GB, one-time; partial clones break
  `filter-repo`). It's refreshed each run unless `--no-fetch`. Override location
  with `MESHSTOR_UPSTREAM_MIRROR_DIR=`.
- **Per-variant DKMS tarball cache.** `perf-compare` / `perf-bitmap-compare`
  cache built tarballs at `build/cache/<sha256-key>/`, keyed by
  (upstream-master SHA, harness SHA, feature SHA, version string). A hit skips
  `rebuild-main` + `build-tarball` entirely. Bypass with `--no-cache`;
  `rm -rf build/cache` to reset. A corrupt cache entry that fails `dkms install`
  is auto-purged and rebuilt once.

## Perf tooling (`bin/perf-*`)

All run as root, build their own variants via `rebuild-main` + `build-tarball`,
and write to `results/`. External deps: a meshstor-patched mdadm at
`/home/$USER/mdadm/mdadm` (system mdadm rejects `/dev/msN`; a `build/msadm`
wrapper is used when present) and csi-perf-test suites under
`/home/$USER/csi-perf-test/suites` (override with `MDADM_BIN=`, `SUITES_BASE=`).

- `perf-bench-tcp PART_LOCAL PART_REMOTE SUITE...` — core harness. Builds a
  raid1 with one local NVMe leg and one **nvme-tcp loopback** leg, runs
  csi-perf-style fio suites against `/dev/ms0`, trap-driven teardown. `ENGINE`
  switches `ms` vs `md`.
- `perf-compare PART_LOCAL PART_REMOTE [VARIANT...]` — baseline vs single-feature
  variants (`per-bucket-arrays`/`takeover`/`latency-ewma`);
  each `kp-*` suite targets one branch's headline claim.
- `perf-bitmap-compare PART_LOCAL PART_REMOTE [SUITE...]` — 4-way matrix:
  `{md,ms} × {internal,lockless}` bitmap on one codebase. `md-lockless` uses the
  kernel's own llbitmap (auto-skipped if the running kernel lacks it).
- `perf-extract-table [--dot] [--baseline DIR] <results-dir>` — render a
  unicode comparison table (baseline absolute, others % delta).
- `perf-make-test-partitions /dev/nvmeXnY [--remove]` — idempotent setup of two
  25 GiB GPT test partitions in trailing free space (4K-block NVMe only).
- `perf-compare-lib.sh` — shared helpers (logging, NVMe cooling, cache, dkms
  lifecycle); sourced, not executed.

## DKMS specifics

- `dkms.conf` builds three modules (`ms_mod`, `raid1_ms`, `raid10_ms`) into
  `/extra`, `AUTOINSTALL="yes"`, `MAKE` passes `KDIR=…/build`.
- `feature_flags.h` exists **twice**: a no-op stub baked into the tarball, and
  the real one regenerated by `Makefile.in` against the *customer's running
  kernel* at every DKMS (re)build — so one architecture-independent source
  tarball serves every kernel version on the fleet.
- `version.h` (supplies `MS_VERSION`) is regenerated from `dkms.conf`'s
  `PACKAGE_VERSION`.
- `bin/deploy-branch <branch> <host>...` builds once locally then DKMS-installs
  + `modprobe`s across a heterogeneous fleet (detects dnf vs apt per host; skips
  Secure-Boot-on hosts — run `bin/mok-enroll` there first). `--cleanup` reverses it.

## Tests

```bash
bash tools/testing/selftests/dkms/run_all.sh   # tooling tests; exit-4 == SKIP, tolerated
bash tools/testing/selftests/dkms/test_build_smoke.sh   # one test directly
```

- `selftests/dkms/` exercises the **real** assembly pipeline (patch apply →
  rename → render → compile) and compat-flag gating — no array needed; SKIPs
  cleanly without a kernel build tree.
- `selftests/md/llbitmap/` are runtime tests; they require **root**, loaded
  `ms_mod`+`raid1_ms`, and the patched mdadm. `/dev/msN` uses a dynamic major
  (252 observed). Source `lib.sh`; never run a `test_*.sh` directly without it.

## Verification before merging a rebase or compat change

The tree must build clean against **all four target kernels** before merge:

| Distro | Kernel |
|---|---|
| RHEL 9.x / Rocky 9 | 5.14 |
| RHEL 10.x / Rocky 10 | 6.12 |
| Ubuntu 24.04 LTS HWE | 6.14 |
| Ubuntu 26.04 LTS | 6.17 |

```bash
for K in <r10 6.12> <r9 5.14> <u24 6.14> <u26 6.17>; do
    env -u KDIR KDIR="$K" bin/build-tarball 0.1.0 2>&1 | tail -2   # each must print "Built: …"
done
```

Then smoke-test on baremetal: install the rpm, `modprobe ms_mod raid1_ms
raid10_ms`, confirm `/proc/msstat` shows `Personalities : [raid1] [raid10]`.
Full procedure in `docs/maintainer.md` (§ cross-distro test workflow).

## Conventions

- **Commit identity for this repo: `Mykola <mykola@meshstor.io>` only**, for
  both Author and `Signed-off-by`. Never use the session/user email.
- Feature work goes on its own branch rebased on a torvalds master snapshot;
  tooling/packaging/docs go on `meshstor-harness`; `master` stays verbatim
  upstream.
- Force-push to `meshstor-main`/`meshstor-harness` is acceptable (we are the
  only consumer), but never rewrite `master`.

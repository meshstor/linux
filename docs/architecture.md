# Architecture

`meshstor-ms` is a parallel `ms_*` MD subsystem shipped as a DKMS package. It
coexists with the kernel's built-in `md_mod` rather than replacing it: our
modules, symbols, devices, and sysfs paths all use distinct names. Customers
run kernel-md and meshstor-ms arrays on the same host concurrently without
collision.

This page establishes the vocabulary that the rest of the doc set uses. It
does not cover installation (see [install.md](install.md)), operation
(see [admin.md](admin.md)), or release engineering (see [build.md](build.md)).

## Why a parallel subsystem

Every supported distro builds the kernel with `CONFIG_MD=y` — md core is
permanently linked into `vmlinux`. Empirically verified on each target:

| Distro / kernel | `CONFIG_MD` |
|---|---|
| RHEL 9.7 / Rocky 9 (5.14) | `=y` |
| RHEL 10.1 / Rocky 10 (6.12) | `=y` |
| Ubuntu 24.04 LTS HWE (6.14) | `=y` |
| Ubuntu 26.04 LTS (6.17) | `=y` |

The original design assumed we could ship a replacement `md_mod.ko` that
displaces the kernel's built-in version via `/extra/` precedence. That
assumption is invalid on every supported target: the in-kernel `md_mod`
cannot be unloaded or shadowed because it is built into the monolithic
kernel image, not provided as a separate module.

Renaming our entire stack to `ms_*` sidesteps the symbol collision. We do
not try to displace anything; we coexist. This unlocks the full feature set
the project needs to ship — including llbitmap and the bitmap_ops framework,
which are core-side changes that a personality-only DKMS could not deliver.

## The rename pass

The rename pass is the structural mechanism that keeps our subsystem isolated
from the kernel's. It runs at tarball-assembly time (i.e., once per release),
not at module-build time, so the customer sees only post-rename source files.

`bin/build-tarball:60-89` runs `sed` against every `.c` and `.h`
file in the assembled tarball, applying rules from `dkms/rename.sed`. The
script auto-generates a keep-list (lines 67-79) by scanning the running
kernel's UAPI headers (`<linux/raid/md_p.h>`, `<linux/raid/md_u.h>`,
`<linux/major.h>`) for `MD_*` and `md_*` identifiers; those become
`__KEEP_<name>` placeholders that subsequent rename rules pass through
untouched.

### Concrete examples

| Before (upstream md) | After (our ms) | Rule |
|---|---|---|
| `register_md_personality` | `register_ms_personality` | `s/\bmd_/ms_/g` |
| `struct mddev` | `struct mssev` | `s/\bmddev/mssev/g` |
| `MD_RECOVERY_RUNNING` | `MS_RECOVERY_RUNNING` | `s/\bMD_/MS_/g` |
| `md_mod_init` | `ms_mod_init` | `s/\bmd_/ms_/g` |
| `"mdstat"` | `"msstat"` | string-literal rule |
| `pr_warn("md: ...")` | `pr_warn("ms: ...")` | log-line prefix rule |

### The keep-list (what is NOT renamed)

The keep-list protects identifiers whose value or path must remain
identical to upstream's. Renaming any of these would either break the
build (kernel header path no longer found) or break on-disk format
compatibility (compiled superblock-magic/feature-flag value diverges
from what kernel md writes).

Static keep entries from [`dkms/rename.sed`](../dkms/rename.sed):

- `<linux/raid/md_p.h>` and `<linux/raid/md_u.h>` — kernel UAPI header
  paths; we still consume the same on-disk format definitions the kernel
  uses.
- `MD_MAJOR` — value `9`, the kernel-md block-device major. Used in
  `MODULE_ALIAS_BLOCKDEV_MAJOR`. (Note: our runtime allocates a different
  major dynamically — see [coexistence model](#coexistence-model) below.)

Auto-extracted keep entries (regenerated per build from kernel headers):

- `MD_SB_*` — superblock format magic values (e.g., `MD_SB_BITMAP_PRESENT`).
- `MD_FEATURE_*` — superblock feature-flag bits.
- `MD_DISK_*` — per-rdev role/state codes.
- `MD_RESYNC_*`, `MD_RECOVERY_*` — recovery state codes (kept on the
  on-disk side; the lowercase `md_recovery_*` *function* names get renamed).
- `MD_BITMAP_BIT_*`, `MD_DEFAULT_BITMAP_*` — on-disk bitmap layout.
- All lowercase `md_*` identifiers from `md_p.h` / `md_u.h` — typically
  struct field names like `md_magic`, `md_minor`.

The auto-extraction (`bin/build-tarball:67-79`) means the
keep-list updates itself when upstream adds new on-disk format constants;
we don't need to manually track them.

## What is renamed and what is not

The full rename map, layer by layer:

| Layer | Kernel `md` | Our `ms` | Mechanism |
|---|---|---|---|
| Module names | `md_mod` (built-in), `raid1.ko`, `raid10.ko` | `ms_mod.ko`, `raid1_ms.ko`, `raid10_ms.ko`, `ms-llbitmap` (in `ms_mod`) | Different module names |
| Exported symbols | `md_*`, `register_md_personality`, … | `ms_*`, `register_ms_personality`, … | Symbol-prefix rename at tarball-assembly time |
| Core types | `struct mddev`, `struct md_rdev`, `struct md_personality` | `struct mssev`, `struct ms_rdev`, `struct ms_personality` | Type-prefix rename |
| Block-device major | `MD_MAJOR=9` | dynamic via `register_blkdev(0, "ms")` | Different major; no conflict |
| Block-device name | `/dev/md0`, `/dev/md1`, … | `/dev/ms0`, `/dev/ms1`, … | Different device-name prefix |
| sysfs path | `/sys/block/md0/md/...` | `/sys/block/ms0/ms/...` | Different kobject names |
| /proc file | `/proc/mdstat` | `/proc/msstat` | Different proc filename |
| Personality `level` | `level = 1, 10, ...` registered via `register_md_personality` | `level = 1, 10, ...` registered via `register_ms_personality` | Different registration tables; same level numbers permitted |
| **On-disk superblock format** | `md` v1.x format | **Same format — bit-for-bit identical** | Customer-driven; userspace tooling writes the same magic. Lets customers freely convert between subsystems by re-attaching the disks under the alternate driver. |

The on-disk-format compatibility is intentional. It means a customer can
take disks from a kernel-md array, stop the array, and reassemble them
under meshstor-ms, or vice versa. The userspace tool that creates ms-bound
arrays must write the same superblock format the kernel md uses; that
tooling is the customer's responsibility (out of scope per the project's
non-goals).

## Coexistence model

Both subsystems are loaded by default on every supported distro:

- **Kernel `md_mod`** — built into `vmlinux`, always live.
- **Our `ms_mod.ko`** — DKMS-installed, loaded on first `modprobe ms_mod`
  (or autoloaded by udev/dracut on boot if a partition with our magic is
  present).

Their disjoint identity at every layer means they cannot collide:

- **Major numbers.** Kernel md owns major 9 (`MD_MAJOR`). Our `ms_mod`
  calls `register_blkdev(0, "ms")` at init, taking whatever dynamic major
  the kernel assigns. The two majors are different by construction.
- **Block-device names.** Kernel md creates `/dev/md0`, `/dev/md1`, ….
  Our `ms_mod` creates `/dev/ms0`, `/dev/ms1`, … via the auto-generated
  keep-list rule that protects the device-name prefix and a string-literal
  rule that switches the disk-name template.
- **sysfs.** Kernel md exposes `/sys/block/md0/md/...`. Our `ms_mod`
  exposes `/sys/block/ms0/ms/...`. Different kobject names because the
  rename touched the sysfs registration call sites.
- **/proc.** Kernel md owns `/proc/mdstat`. Our `ms_mod` owns
  `/proc/msstat`. Different `proc_create` names.
- **Personality registration.** Each subsystem has its own personality
  table. Both register a level=1 personality and a level=10 personality;
  there is no shared registry, so the level numbers do not collide.

The two subsystems do not share any in-memory state or any sysctl. They
are independent kernel subsystems that happen to operate on the same
on-disk format.

For the operator-side runbook on how to actually run `/dev/md0` and
`/dev/ms0` arrays concurrently — and how to migrate an array between the
two by re-attaching disks — see [`admin.md`](admin.md#coexistence-with-kernel-md-operator-side).

## Module set

Three `.ko` files ship in the package:

| Module | Composition | Role |
|---|---|---|
| `ms_mod.ko` | `ms.o + ms-bitmap.o + ms-llbitmap.o` (composite per `dkms/Makefile.in:14`) | MD core: rdev management, bitmap_ops framework, internal bitmap, lockless bitmap (llbitmap) |
| `raid1_ms.ko` | `raid1_ms.o` (which `#includes` `raid1-10_ms.c`) | RAID1 personality, with latency-EWMA read balancing and raid1→raid10 takeover |
| `raid10_ms.ko` | `raid10_ms.o` (which `#includes` `raid1-10_ms.c`) | RAID10 personality, with per-bucket-arrays, latency-EWMA, takeover |

### Why no separate `ms-llbitmap.ko`

Upstream ships llbitmap inside `md_mod`, not as a separate module. We
preserve the in-tree pattern: `ms-llbitmap.o` is compiled into the
`ms_mod` composite. This keeps the registration plumbing (the
`bitmap_ops` framework registering both `internal` and `lockless` types)
inside one module's init flow, avoiding cross-module symbol exports.

### Why no `raid0_ms` / `raid456_ms`

Out of scope per the project spec. Customers wanting RAID0/RAID5/RAID6
use the kernel's built-in `md` (which they already have on every
supported distro). meshstor-ms targets the workloads that benefit from
the optimizations we ported — primarily mirror-based redundancy with
high write rate or read-asymmetric latency.

The relevant source files (`raid0.h`, `raid5.*`, `md-cluster.c`) are
intentionally absent from [`dkms/manifest.txt`](../dkms/manifest.txt).

## Repository layout

The repository keeps kernel sources at their canonical upstream paths
under `drivers/md/`. DKMS packaging lives in a separate top-level
`dkms/` directory that never collides with upstream-owned paths. This
two-directory split is what makes ongoing upstream rebase practical
(see [maintainer.md](maintainer.md#upstream-rebase-workflow) for the
rebase procedure).

```
linux-meshstor/                     # kernel-fork repo
├── drivers/md/                     # canonical upstream paths
│   ├── md.c, md.h                  # md core (gets renamed to ms.* in tarball)
│   ├── md-bitmap.c, md-bitmap.h    # internal bitmap
│   ├── md-llbitmap.c               # lockless bitmap
│   ├── md-cluster.h                # included for upstream completeness
│   ├── raid1.c, raid1.h            # raid1 personality
│   ├── raid10.c, raid10.h          # raid10 personality
│   ├── raid1-10.c                  # source-only #include shared between raid1 + raid10
│   ├── Makefile, Kconfig           # upstream's in-tree build files (verbatim)
│   └── (raid0.c, raid5.*, md-cluster.c — present for upstream rebase
│        completeness, but NOT shipped via dkms/manifest.txt)
├── bin/                            # invokable helpers (build / perf / deploy / MOK)
│   ├── rebuild-main                # compose upstream + feature branches → build/linux-meshstor-rebuilt
│   ├── build-tarball               # assembles meshstor-ms-X.Y.Z.dkms.tar.gz (runs the rename pass)
│   ├── build-rpm, build-deb, build-deb-direct   # package the tarball
│   ├── deploy-branch               # build + DKMS-install + modprobe across a host fleet
│   ├── mok-enroll                  # Secure Boot MOK key generation + enrollment
│   ├── perf-bench-tcp              # nvme-tcp loopback raid1 perf harness
│   ├── perf-compare, perf-bitmap-compare        # feature / bitmap-mode comparisons
│   └── perf-extract-table, perf-make-test-partitions, perf-compare-lib.sh
├── dkms/                           # DKMS packaging — ours alone
│   ├── dkms.conf.in                # template, version-substituted
│   ├── Makefile.in                 # out-of-tree wrapper template
│   ├── manifest.txt                # which drivers/md/ files ship
│   ├── rename.sed                  # md_* → ms_* substitution rules
│   ├── compat/
│   │   ├── compat.h                # kernel-API compat shims
│   │   └── feature_flags.h         # auto-generated at module-build time
│   ├── patches/
│   │   ├── 0001-*.patch            # pre-rename source-level patches
│   │   └── README.md
│   ├── debian/                     # .deb packaging
│   └── rpm/                        # .rpm spec
├── docs/                           # this documentation set
│   ├── index.md, install.md, admin.md, architecture.md (this file),
│   ├── build.md, maintainer.md, compat.md, performance.md,
│   ├── perftest-playbook.md        # copy-paste perf-run recipe
│   └── superpowers/                # specs and plans (gitignored — local dev archive)
└── results/                        # gitignored — perf/test run outputs
```

The two source-tree directories serve disjoint roles:

- **`drivers/md/` is upstream-canonical.** Every file here uses the
  same path, name, and (modulo our integrated feature commits) content
  as upstream Linux. Our integration commits modify these files in
  place, exactly where upstream would. When we rebase, our changes
  apply against the new upstream lines.
- **`dkms/` is ours alone.** Upstream never adds anything here. Compat
  shims live here (not under `drivers/md/compat/`) precisely so the
  kernel-source directory stays upstream-pristine. The rename pass and
  compat-shim infrastructure exist entirely outside `drivers/md/`.

## See also

- [install.md](install.md) — how to install the package
- [admin.md](admin.md) — operator runbook
- [build.md](build.md) — release engineering
- [maintainer.md](maintainer.md) — rebase workflow + compat-shim authoring
- [compat.md](compat.md) — distro × kernel matrix
- [performance.md](performance.md) — measured perf characteristics

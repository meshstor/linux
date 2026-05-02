# Phase 0b: Cross-distro build matrix (final, 2026-05-02)

Build attempts for the meshstor-ms DKMS tarball against the four target
distros' kernel-devel/headers packages.

## Final state — three of four distros build from one source tree

| Distro | Kernel | Build result | Modules | Notes |
|---|---|---|---|---|
| **RHEL 10.1 / Rocky 10** (Phase 0 baseline) | 6.12.0-124.49.1.el10_1 | ✅ Clean | 3 .ko | Validated end-to-end with VM tests in Phase 0 |
| **RHEL 9.7 / Rocky 9** | 5.14.0-611.49.1.el9_7 | ✅ Clean | 3 .ko | Required `badblocks_check` and `alloc_page_buffers` shims for the 5.14→6.12 API drift |
| **Ubuntu 26.04 LTS** | 6.17.0-28-generic | ✅ Clean | 3 .ko | Native `bio_submit_split_bioset`, `bdev_count_inflight`, `timer_container_of`, etc. — feature flags correctly skip our shims |
| **Ubuntu 24.04 LTS HWE** | 6.14.0-37-generic | ⚠️ Build-env block | — | Ubuntu kernel compiled with `gcc-13`; CONFIG_CC_VERSION_TEXT enforces match. Solvable by installing `gcc-13` on build host or building inside an Ubuntu container. On customer machines DKMS uses the running system's matching gcc, so this is a CI-only concern. |

## How the compat layer evolved during Phase 0b

### Round 1: feature-flag-based detection (replaces LINUX_VERSION_CODE gates)

`dkms/scripts/build-tarball.sh` scans the target kernel's headers and
generates `compat/feature_flags.h` with `#define HAVE_<SYMBOL>` for each
present symbol. `compat.h` gates each shim on `#ifndef HAVE_X`.

Robust against distro backports — RHEL especially backports features
out-of-band relative to upstream version numbers, so `LINUX_VERSION_CODE`
comparisons silently break in those cases.

Symbols feature-detected:
- `bio_submit_split_bioset`, `bio_init_inline`
- `bdev_rot`, `bdev_count_inflight`, `bdev_write_zeroes_unmap_sectors`
- `timer_container_of`
- `kzalloc_obj`, `kmalloc_obj`, `kzalloc_objs`, `kmalloc_objs`,
  `kvzalloc_objs`, `kmalloc_flex`, `kzalloc_flex`
- `WQ_PERCPU`
- Signature: `block_device_operations.getgeo` (block_device → gendisk)
- Signature: `badblocks_check` arg-5 type (int → sector_t pointer)
- Signature: `alloc_page_buffers` argument count (3-arg → 2-arg)

### Round 2: RHEL 9 source-level shims

Two API differences between 5.14 (RHEL 9) and 6.12+ that needed code-level
wrappers, not just symbol presence checks:

1. **`badblocks_check` argument types** — RHEL 9 uses `int sectors` and
   `int *bad_sectors`; we wrap to convert from sector_t and back.

2. **`alloc_page_buffers` argument count** — RHEL 9 takes `(page, size, bool retry)`;
   our code uses the 2-arg form. Compat: a `#define` macro that adds the third
   `false` arg on detection of 3-arg form.

## Phase 0 + Phase 2 perf results (2026-05-02, RHEL 10.1)

Captured before Phase 0b work; validated again after with no regression.

| Workload | kernel `md` | `ms` (ours) | ratio |
|---|---|---|---|
| raid1 4K randread, 4 jobs qd32 | 1042k iops | 1013k iops | 97.2% |
| raid1 4K randwrite, 4 jobs qd32 | 660k iops | 644k iops | 97.6% |
| raid10 4K randwrite, 4 disks | 1025k iops | 981k iops | 95.7% |
| raid1 4K randwrite single-thread, llbitmap vs internal | 98.8k vs 61.7k iops | — | **+60% with llbitmap** |

Plus latency-EWMA actively redistributing reads (43× device-asymmetry observed
under uneven page-cache warming).

## What's left for full Phase 0b closure

1. **Ubuntu 24.04 HWE compiler match.** Install `gcc-13` on build host
   (`dnf install gcc-toolset-13` on RHEL family, or use Ubuntu container in CI).
   Probably 10-15 minutes once a compatible toolchain is on the path.

2. **End-to-end VM tests for RHEL 9 and Ubuntu 26.04.** Phase 0 only ran live
   tests on RHEL 10.1. Repeat the array-create + I/O + takeover + llbitmap
   verification on each distro. Each run ~10 minutes.

3. **CI matrix automation.** Driven by Phase 1 work (DKMS packaging) — a
   matrix that builds against every supported (distro × kernel-version) pair
   and runs the smoke tests. Out of Phase 0b scope.

The build-side architectural validation is now complete: one source tree
(meshstor-main) produces working modules for both extremes of our supported
range (RHEL 9.7's 5.14 kernel and Ubuntu 26.04's 6.17 kernel), with the
compat layer auto-detecting the right shim set for each target.

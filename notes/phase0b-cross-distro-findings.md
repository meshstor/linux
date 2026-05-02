# Phase 0b: Cross-distro build matrix (final, 2026-05-02)

Build attempts for the meshstor-ms DKMS tarball against the four target
distros' kernel-devel/headers packages.

## Final state — five kernel images tested

| Distro / kernel | Kernel | Build | Modules | Notes |
|---|---|---|---|---|
| **RHEL 10.1 / Rocky 10** (Phase 0 baseline) | 6.12.0-124.49.1.el10_1 | ✅ Clean | 3 .ko | Validated end-to-end with VM tests in Phase 0 |
| **RHEL 9.7 / Rocky 9** | 5.14.0-611.49.1.el9_7 | ✅ Clean | 3 .ko | `badblocks_check`, `alloc_page_buffers` shims for 5.14→6.12 API drift |
| **Ubuntu 24.04 LTS HWE** | 6.14.0-37-generic | ✅ Clean | 3 .ko | Same shims as RHEL 10. Ubuntu's kernel hardcodes `CC=gcc-13`; customer's Ubuntu 24.04 has gcc-13 by default, so DKMS works. Cross-build from RHEL needs `make CC=gcc HOSTCC=gcc`. |
| **Ubuntu 26.04 LTS** | 6.17.0-28-generic | ✅ Clean | 3 .ko | 6 shims compiled out — kernel has them natively |
| **Ubuntu 24.04 LTS GA** | 6.8.0-116-generic | ⚠️ Out of scope | — | See "GA 6.8 architectural gap" below |

## Ubuntu 24.04 LTS GA (kernel 6.8) — architectural gap

Tested 2026-05-02. Initial build attempt: 33 errors. After adding trivial defines
(`LEVEL_LINEAR`, `REQ_ATOMIC`): 25 errors. The remaining 25 split into structural
API gaps that require code-level patches, not header shims:

| Issue | API window | What's needed |
|---|---|---|
| `bdev_file_open_by_dev`, `file_bdev` | Added ~6.9 | Wrapper: replace `bdev_open_by_dev` callers' return-handling |
| `queue_limits_start_update`, `_commit_update`, `_cancel_update`, `_set`, `_stack_bdev`, `_stack_integrity_bdev` | Added ~6.10 (transactional queue_limits API) | Stubs that translate to direct `blk_queue_*()` calls — but lossy because the new API is transactional and pre-6.10 had no equivalent atomicity |
| `struct queue_limits.features` + `BLK_FEAT_*` flags | Added ~6.10 | Cannot add a struct field via shim. Patches needed at every callsite that sets `lim.features = ...` to use pre-6.10 separate-field access |
| `blk_alloc_disk` argument count change | Changed ~6.10 | Wrapper macro |
| `BLK_FEAT_ATOMIC_WRITES`, `REQ_ATOMIC` | Atomic-writes infra ~6.11 | Define-as-zero stubs (atomic-write paths become no-ops on 6.8) |
| `kstrtoint` arg-3 type drift | Minor, ~6.10 | Cast wrapper |

The 6.8 kernel pre-dates the bulk of upstream's queue_limits redesign (April 2024
release vs queue_limits transactional API landing in 6.10, August 2024).

**Recommendation: declare Ubuntu 24.04 GA 6.8 out of scope**, with HWE 6.14 as the
supported path for Ubuntu 24.04 LTS customers. Rationale:

1. **Cost**: estimated 3–5 focused engineering days to write the queue_limits
   compat layer plus 5+ source-level patches at call sites, plus regression-testing
   that the lossy queue_limits stubs don't break correctness.

2. **Customer base**: Ubuntu 24.04 LTS users with newer hardware typically install
   the HWE meta-package (`linux-image-generic-hwe-24.04`), which currently points
   at 6.14. Sticking on GA 6.8 long-term is unusual.

3. **Maintenance treadmill**: 6.8 will fall further behind upstream md as we
   rebase. Each rebase pulls in code that uses newer kernel APIs, requiring
   yet more compat work just for 6.8.

If 6.8 support becomes a hard customer requirement, plan a dedicated Phase 0c
sprint. The feature-flag detection infrastructure already in place will handle
the easy cases; the queue_limits transactional API needs a real source-level
patch series.

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

# Phase 0b: Cross-distro build matrix findings (2026-05-02)

Build attempts for the meshstor-ms DKMS tarball against the four target
distros' kernel-devel/headers packages. RHEL 10.1 already validated end-to-end
in Phase 0; this round is "does the same source compile against each kernel."

| Distro | Kernel | Build result | Required compat work |
|---|---|---|---|
| RHEL 10.1 (Rocky 10.1 proxy) | 6.12.0-124.49.1.el10_1 | **Clean — 3 .ko produced** | None (this is the validated baseline) |
| Ubuntu 24.04 LTS HWE | 6.14.0-37-generic | Compiler-environment failure | Build host needs `gcc-13` (Ubuntu kernel built with it; CONFIG_CC_VERSION_TEXT enforces match). Compat-wise expected to match 6.12 closely — will reassess once compiler matches. |
| Ubuntu 26.04 LTS | 6.17.0-28-generic | 8 errors | (1) `bio_submit_split_bioset` exists in 6.17's `<linux/blkdev.h>` — our compat shim's `LINUX_VERSION_CODE < KERNEL_VERSION(6, 18, 0)` gate over-includes (collides). Lower threshold to `< 6.17`. (2) `bdev_rot` missing — gate already `< 6.14` so misses 6.17; needs feature-test or wider gate. (3) `md_getgeo` callback signature — needs verification of when block_device→gendisk landed in upstream. |
| RHEL 9.7 (Rocky 9.7 proxy) | 5.14.0-611.49.1.el9_7 | 6 errors | (1) `badblocks_check` argument-5 type changed between 5.14 and 6.12; needs compat wrapper. (2) `alloc_page_buffers` argument-count changed; needs compat wrapper. RHEL 9.x is the largest kernel-API gap; expect 5–10 more shims surfacing as we iterate. |

## Implications for the compat layer

The dynamic UAPI keep-list in `dkms/rename.sed` worked: it auto-protected
`MD_FEATURE_RAID0_LAYOUT` and other UAPI constants on every distro without
manual intervention. The rename pass itself is not the bottleneck.

The bottleneck is **kernel-internal API drift**:

- **5.14 → 6.12** (RHEL 9 → RHEL 10): largest gap. Expect each shim cycle to surface 5–10 new symbols.
- **6.12 → 6.14**: small gap. Mostly compiler-environment differences (gcc-13 vs gcc).
- **6.14 → 6.17**: medium gap. New helpers landed (`bio_submit_split_bioset` in 6.17, etc.); our shim gates need refinement.
- **6.17 → upstream HEAD (~7.1)**: small (we already integrate from this base).

## Recommended next steps (Phase 0b proper)

1. **Refine LINUX_VERSION_CODE gates** in `dkms/compat/compat.h`:
   - `bio_submit_split_bioset`: `< 6.17` (not `< 6.18`)
   - `bdev_rot`, `bdev_count_inflight`: re-verify exact-version boundary for each
   - `bdev_write_zeroes_unmap_sectors`: similar audit

2. **Add RHEL 9 (5.14) shims**:
   - `badblocks_check` argument-5 wrapper (likely: 5.14 takes `int *first_bad`, 6.12 takes `sector_t *first_bad`)
   - `alloc_page_buffers` argument-count wrapper (5.14 had a `bool retry` arg that was removed)

3. **Build host environment**:
   - For Ubuntu builds, install `gcc-13` on the build host or run build inside an Ubuntu container/chroot. Standard DKMS deployment puts the build on the target machine where the matching compiler is already present, so this is only a CI-pipeline concern.

4. **Feature-test boundaries** instead of version-only gates:
   - For symbols where the introduction-version differs between vanilla upstream and distro backports (RHEL is notorious for backporting), use `kbuild`'s `CONFIG_*` checks or `Module.symvers` greps in `dkms/scripts/build-tarball.sh` to set `-DHAVE_*` defines that compat.h consumes. This is more robust than hardcoded version comparisons.

## Phase 2 perf results (already captured 2026-05-02)

| Workload | kernel `md` | `ms` (ours) | ratio |
|---|---|---|---|
| raid1 4K randread, 4 jobs qd32 | 1042k iops | 1013k iops | 97.2% |
| raid1 4K randwrite, 4 jobs qd32 | 660k iops | 644k iops | 97.6% |
| raid10 4K randwrite, 4 disks | 1025k iops | 981k iops | 95.7% |
| raid1 4K randwrite single-thread, llbitmap vs internal | 98.8k vs 61.7k iops | — | **+60% with llbitmap** |

Plus latency-EWMA actively redistributing reads (43× device-asymmetry observed).

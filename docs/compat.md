# Compatibility matrix

Static reference for which distros and kernels meshstor-ms supports, what
compat shims exist, and which features are out of scope. For the rationale
behind each shim and the rebase workflow that maintains them, see
[maintainer.md](maintainer.md). For measured perf characteristics across
this matrix, see [performance.md](performance.md).

## Supported distros

| Distro / kernel | Kernel | Build | Modules load | Live test | Notes |
|---|---|---|---|---|---|
| RHEL 10.1 / Rocky 10 | 6.12.0-124.x.el10 | ✅ | ✅ baremetal | ✅ raid1, raid10, takeover, llbitmap | Reference platform; perf baseline |
| RHEL 9.7 / Rocky 9 | 5.14.0-611.x.el9 | ✅ | ✅ baremetal | ✅ raid1, raid10 | `--bitmap=internal` only — see below |
| Ubuntu 24.04 LTS HWE | 6.14.0-37-generic | ✅ | ✅ via vng | ✅ raid1, EWMA tracking | Cross-build from RHEL needs `make CC=gcc HOSTCC=gcc` |
| Ubuntu 26.04 LTS | 6.17.0-28-generic | ✅ | ✅ via vng | ✅ raid1, EWMA tracking | 6 shims compiled out — kernel has them natively |
| Ubuntu 24.04 LTS GA | 6.8.0-116-generic | ⚠️ | — | — | Out of scope — see below |

## Per-shim API drift

The compat layer in [`dkms/compat/compat.h`](../dkms/compat/compat.h)
gates each shim on a `HAVE_*` macro that is generated at module-build time
by [`dkms/Makefile.in`](../dkms/Makefile.in)'s `feature_flags` recipe. The
recipe scans the target kernel's headers for the symbol or signature; if
found, the `HAVE_*` flag is defined and the corresponding shim is
compiled out. See [`maintainer.md`](maintainer.md#feature-flag-detection-vs-linux_version_code)
for the rationale.

### Header shims (in `compat/compat.h`)

| Symbol / feature | First upstream version | Why we shim it | Detection flag | compat.h line |
|---|---|---|---|---|
| `kzalloc_obj`, `kmalloc_obj` | ~6.10 | Convenience allocators for typed objects; we use them in raid1/raid10 | `HAVE_KZALLOC_OBJ`, `HAVE_KMALLOC_OBJ` | 72-86 |
| `kzalloc_objs`, `kmalloc_objs`, `kvzalloc_objs` | ~6.11 | Plural variants for arrays of objects | `HAVE_*OBJS` | 87-110 |
| `kmalloc_flex`, `kzalloc_flex` | ~6.11 | Flex-array struct allocators | `HAVE_*_FLEX` | 126-145 |
| `bdev_rot()` | ~6.11 | Replacement for the old `BLK_QUEUE_NONROT` flag query | `HAVE_BDEV_ROT` | 148-165 |
| `bdev_count_inflight()` | ~6.11 | Inflight I/O counter | `HAVE_BDEV_COUNT_INFLIGHT` | 167-179 |
| `WQ_PERCPU` | ~6.10 | Workqueue flag for per-CPU pinning | `HAVE_WQ_PERCPU` | 181-192 |
| `bdev_write_zeroes_unmap_sectors()` | ~6.11 | Discard-with-zero query | `HAVE_BDEV_WRITE_ZEROES_UNMAP_SECTORS` | 195-207 |
| `timer_container_of()` | ~6.10 | Timer→container helper (replaces `from_timer`) | `HAVE_TIMER_CONTAINER_OF` | 209-218 |
| `bio_init_inline()` | ~6.11 | Inline bio init helper | `HAVE_BIO_INIT_INLINE` | 220-237 |
| `bio_submit_split_bioset()` | ~6.11 | Submit-split helper for stacked bio split | `HAVE_BIO_SUBMIT_SPLIT_BIOSET` | 239-260 |
| `badblocks_check()` argument types | ~6.11 (sector_t outputs) | Pre-6.11 used `int *bad_sectors`; we wrap to `sector_t *` | `HAVE_BADBLOCKS_CHECK_SECTOR_T_OUTPUTS` | 262-284 |
| `alloc_page_buffers()` argument count | ~6.11 (2-arg) | Pre-6.11 took `(page, size, retry)`; wrap to add the third arg | `HAVE_ALLOC_PAGE_BUFFERS_2ARG` | 286-302 |
| `bh_submit()`, `bio_endio_bh()` | ~7.2 | buffer_head bio submit/complete helpers md-bitmap.c uses; ports them for pre-7.2 kernels (`guard_bio_eod` dropped — not module-exported) | `HAVE_BH_SUBMIT` | 537-605 |

### Source-level patches (in `dkms/patches/`)

When a header shim won't suffice — typically because a kernel-owned struct
gained a field, or a callback signature changed in a way `#define` can't
paper over — the change ships as a patch applied at tarball-assembly time.

| Patch | What it handles | First upstream version | Detection flag |
|---|---|---|---|
| `0001-md-getgeo-feature-gated.patch` | `block_device_operations.getgeo` callback signature: pre-6.18 took `struct block_device *`, post-6.18 takes `struct gendisk *`. Patch installs a wrapper for old kernels. | 6.18 | `HAVE_GETGEO_GENDISK` |
| `0002-pre-6.18-no-wzeroes-unmap-field.patch` | `struct queue_limits.max_hw_wzeroes_unmap_sectors` field added in 6.18. Patch `#ifdef`s the assignment so older kernels skip it. | 6.18 | (LINUX_VERSION_CODE) |
| `0003-pre-6.18-no-mdp-superblock-1-logical-block-size.patch` | `mdp_superblock_1` gained a logical_block_size field in 6.18 used by llbitmap. Patch makes the read/write conditional. | 6.18 | (LINUX_VERSION_CODE) |
| `0004-sysctl-table-sentinel-pre-6.4-compat.patch` | Pre-6.4 `register_sysctl_table` requires a sentinel entry; 6.4 introduced `register_sysctl_sz` that doesn't. Patch restores the trailing `{}` for old kernels. Without this, `modprobe ms_mod` panics on RHEL 9. | 6.4 | `HAVE_SYSCTL_REGISTER_TABLE_NO_SENTINEL` |

The patch series is documented in
[`dkms/patches/README.md`](../dkms/patches/README.md), including the
decision boundary for "header shim vs patch".

## llbitmap on RHEL 9 — empirical limitation

llbitmap creates and assembles successfully on RHEL 9 (5.14), but write
throughput collapses by 9–42× compared to the internal bitmap on the same
kernel. Use `--bitmap=internal` on RHEL 9.

Measured on baremetal 2026-05-02 (full numbers in
[`performance.md`](performance.md)):

| Workload | RHEL 9 ms internal | RHEL 9 ms llbitmap | Ratio |
|---|---|---|---|
| raid1 single-thread randwrite (qd=1) | 61.1k iops | 6.5k iops | **9× slower** |
| raid1 multi-thread randwrite (qd=32, 4 jobs) | 188k iops | 10.1k iops | **18× slower** |
| raid10 multi-thread randwrite (4 disks, qd=32, 4 jobs) | 188k iops | 4.5k iops | **42× slower** |

The kernel logs the underlying reason on every `--bitmap=lockless` array
assembly:

```
ms0: array will not be assembled in old kernels that lack configurable LBS support (<= 6.18)
```

llbitmap depends on the configurable-logical-block-size kernel feature
that landed upstream in 6.18. On kernels lacking it, llbitmap falls back
to a synchronous slow path. The fallback is functional (data is written
correctly) but unsuitable for any workload that cares about throughput.

Recommended bitmap selection by kernel:

| Kernel | Recommended bitmap |
|---|---|
| RHEL 9.x (5.14) | `--bitmap=internal` |
| RHEL 10.x (6.12) | `--bitmap=lockless` (or `auto`) |
| Ubuntu 24.04 HWE (6.14+) | `--bitmap=lockless` (or `auto`) |
| Ubuntu 26.04 (6.17+) | `--bitmap=lockless` (or `auto`) |

`--bitmap=auto` (the default in our mdadm fork) makes the right choice
based on kernel-side LBS support detection, so users following the
default get the right behavior on every platform.

## Out of scope

| Item | Disposition | Reason |
|---|---|---|
| Ubuntu 24.04 LTS GA (kernel 6.8) | Declined | Pre-dates upstream's 6.10 transactional `queue_limits` redesign and 6.10 `bdev_file_open_by_dev`. Estimated 3–5 engineer-days to write the missing shims. Customer base on 24.04 GA is small; HWE 6.14+ is the supported path. |
| RAID0 personality | Use kernel md | Out of project scope; meshstor-ms targets mirror-based redundancy. |
| RAID4/5/6 (raid456) | Use kernel md | Same as RAID0. raid5.* sources kept in `drivers/md/` for upstream-rebase completeness but not shipped via [`dkms/manifest.txt`](../dkms/manifest.txt). |
| Cluster MD (`md-cluster`) | Out of scope | Niche use case, large surface area, requires DLM/corosync userspace. |
| Multipath, faulty, linear personalities | Use kernel md | Deprecated upstream; not target use cases. |
| Bootloader / root-on-ms paths | Out of scope | Initramfs surgery, systemd-fsck-root ordering, recovery-mode failure modes — all skipped. Customer can run ms arrays for data volumes; root volume stays on kernel md or non-RAID. |
| `msadm` userspace tool | Customer responsibility | The user maintains an `ms`-aware mdadm fork or wrapper. Documented as a hard prerequisite. |
| Cross-subsystem auto-migration | Out of scope | Same on-disk format means a customer can manually re-attach disks under either subsystem; we don't ship automation for that. |

## See also

- [maintainer.md](maintainer.md) — how the compat layer is maintained, how to add new shims
- [architecture.md](architecture.md) — why the parallel-subsystem design forced the rename pass
- [performance.md](performance.md) — perf measurements on the supported matrix

/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * meshstor-md compatibility shims for kernels older than upstream HEAD.
 *
 * Each shim is gated on LINUX_VERSION_CODE (with optional RHEL_RELEASE_CODE
 * for RHEL backports that can't be expressed by version alone).
 *
 * Add a new shim by:
 *   1. Identifying the symbol or macro the build wants but the kernel lacks.
 *   2. Locating the upstream commit that introduced it.
 *   3. Adding the shim with KERNEL_VERSION(X,Y,Z) == upstream commit's release.
 *   4. Documenting in the comment block above the shim.
 */
#ifndef MESHSTOR_MD_COMPAT_H
#define MESHSTOR_MD_COMPAT_H

/*
 * All kernel headers needed by any shim below are pulled in here at the top.
 * compat.h is force-included via the Makefile's -include flag, so it is the
 * first thing every translation unit sees. Shims that use kernel types
 * (struct block_device, struct bio, etc.) need the relevant headers
 * already in scope when the static inline is parsed; otherwise gcc emits
 * "struct foo declared inside parameter list" warnings and the type ends up
 * incompatible with the kernel's definition seen later.
 */
#include <linux/version.h>
#include <linux/types.h>
#include <linux/slab.h>
#include <linux/bio.h>
#include <linux/blkdev.h>
#include <linux/blk_types.h>
#include <linux/workqueue.h>

/* RHEL release detection */
#ifndef RHEL_RELEASE_CODE
#define RHEL_RELEASE_CODE 0
#endif
#ifndef RHEL_RELEASE_VERSION
#define RHEL_RELEASE_VERSION(a,b) 0
#endif

/* Shims go here, sorted by introduction-version of the upstream symbol. */

/*
 * kzalloc_obj / kzalloc_objs / kmalloc_obj / kmalloc_objs
 *
 * Upstream introduces these as part of the treewide commit 7ea7c43e
 * "treewide: Replace kmalloc with kmalloc_obj for non-scalar types".
 * Each name has a 1-arg form (uses default GFP_KERNEL) and a 2-arg form
 * with explicit GFP. Same for *_objs (3-arg form takes type, count, gfp).
 *
 * Backport via existing kzalloc/kmalloc/kcalloc primitives. sizeof(x)
 * accepts both a dereferenced pointer (e.g. kzalloc_obj(*ptr)) and a
 * type name (e.g. kzalloc_obj(struct foo)).
 *
 * Variadic macro overload-by-arg-count technique is the standard way
 * to provide multiple arities for the same name in C99+.
 */

#define _MD_COMPAT_GET_3RD(_1, _2, _3, NAME, ...) NAME
#define _MD_COMPAT_GET_2ND(_1, _2, NAME, ...) NAME

/* kzalloc_obj(x) -> GFP_KERNEL ; kzalloc_obj(x, gfp) -> explicit */
#ifndef kzalloc_obj
#define _kzalloc_obj_1(x)      kzalloc(sizeof(x), GFP_KERNEL)
#define _kzalloc_obj_2(x, gfp) kzalloc(sizeof(x), (gfp))
#define kzalloc_obj(...) \
    _MD_COMPAT_GET_2ND(__VA_ARGS__, _kzalloc_obj_2, _kzalloc_obj_1)(__VA_ARGS__)
#endif

#ifndef kmalloc_obj
#define _kmalloc_obj_1(x)      kmalloc(sizeof(x), GFP_KERNEL)
#define _kmalloc_obj_2(x, gfp) kmalloc(sizeof(x), (gfp))
#define kmalloc_obj(...) \
    _MD_COMPAT_GET_2ND(__VA_ARGS__, _kmalloc_obj_2, _kmalloc_obj_1)(__VA_ARGS__)
#endif

/* kzalloc_objs(type, n) / kzalloc_objs(type, n, gfp) */
#ifndef kzalloc_objs
#define _kzalloc_objs_2(type, n)      kcalloc((n), sizeof(type), GFP_KERNEL)
#define _kzalloc_objs_3(type, n, gfp) kcalloc((n), sizeof(type), (gfp))
#define kzalloc_objs(...) \
    _MD_COMPAT_GET_3RD(__VA_ARGS__, _kzalloc_objs_3, _kzalloc_objs_2)(__VA_ARGS__)
#endif

#ifndef kmalloc_objs
#define _kmalloc_objs_2(type, n)      kmalloc_array((n), sizeof(type), GFP_KERNEL)
#define _kmalloc_objs_3(type, n, gfp) kmalloc_array((n), sizeof(type), (gfp))
#define kmalloc_objs(...) \
    _MD_COMPAT_GET_3RD(__VA_ARGS__, _kmalloc_objs_3, _kmalloc_objs_2)(__VA_ARGS__)
#endif

/*
 * bdev_rot()
 *
 * Upstream renames/adds bdev_rot(b) as the positive form of "is rotational".
 * 6.12 has the negative bdev_nonrot(b). Trivial inverse.
 */
#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 14, 0)
static inline bool bdev_rot(struct block_device *bdev)
{
    return !bdev_nonrot(bdev);
}
#endif

/*
 * bdev_count_inflight()
 *
 * Upstream adds this helper to count inflight bios on a block_device.
 * 6.12 lacks it. The single user (md.c::is_mddev_idle) compares against
 * the previous count to decide if the device is "idle." Returning 0 makes
 * the device always report idle, which biases the heuristic toward "yes"
 * but is not a correctness issue — sync_speed display may be slightly off.
 *
 * TODO: revisit with a real backport via part_stat_read once we identify
 * the exact field semantics.
 */
#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 14, 0)
static inline unsigned int bdev_count_inflight(struct block_device *bdev)
{
    (void)bdev;
    return 0;
}
#endif

/*
 * WQ_PERCPU
 *
 * New workqueue flag in upstream. On older kernels, defining it as 0 is
 * a safe no-op — alloc_workqueue ignores unknown bits in the flags arg.
 */
#ifndef WQ_PERCPU
#define WQ_PERCPU 0
#endif

/*
 * bdev_write_zeroes_unmap_sectors
 *
 * Upstream adds this distinct API to query write-zeroes-with-unmap
 * sector limit, separate from plain bdev_write_zeroes_sectors. Older
 * kernels don't have the distinction.
 *
 * Safe fallback: return 0, which causes md-llbitmap to skip the
 * write-zeroes-unmap optimization and fall back to the standard sync path.
 */
#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 14, 0)
static inline unsigned int bdev_write_zeroes_unmap_sectors(struct block_device *bdev)
{
    (void)bdev;
    return 0;
}
#endif

/*
 * bio_submit_split_bioset()
 *
 * Upstream introduces this helper around v6.18. Semantics: split off
 * `sectors` from the front of `bio` using bioset `bs`, chain remainder,
 * submit the split via submit_bio_noacct, and return the original bio
 * (now representing the remainder) so the caller can continue.
 *
 * Backport via existing bio_split + bio_chain + submit_bio_noacct,
 * all of which exist in 6.12.
 */
#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 18, 0)
static inline struct bio *bio_submit_split_bioset(struct bio *bio,
                                                   unsigned int sectors,
                                                   struct bio_set *bs)
{
    struct bio *split;

    split = bio_split(bio, sectors, GFP_NOIO, bs);
    if (IS_ERR(split))
        return NULL;
    bio_chain(split, bio);
    submit_bio_noacct(split);
    return bio;
}
#endif

#endif /* MESHSTOR_MD_COMPAT_H */

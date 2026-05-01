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

#include <linux/version.h>

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
 * They wrap kzalloc/kmalloc/kcalloc with the GFP_KERNEL default and a
 * type-or-deref-style size argument.
 *
 * Backport via existing kzalloc/kmalloc/kcalloc primitives, which exist
 * in every kernel we target. sizeof(x) accepts both a dereferenced
 * pointer (kzalloc_obj(*ptr)) and a type name (kzalloc_obj(struct foo)).
 */
#include <linux/slab.h>
#ifndef kzalloc_obj
#define kzalloc_obj(x)        kzalloc(sizeof(x), GFP_KERNEL)
#endif
#ifndef kmalloc_obj
#define kmalloc_obj(x)        kmalloc(sizeof(x), GFP_KERNEL)
#endif
#ifndef kzalloc_objs
#define kzalloc_objs(type, n) kcalloc((n), sizeof(type), GFP_KERNEL)
#endif
#ifndef kmalloc_objs
#define kmalloc_objs(type, n) kmalloc_array((n), sizeof(type), GFP_KERNEL)
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
#include <linux/blkdev.h>
#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 14, 0)
static inline unsigned int bdev_write_zeroes_unmap_sectors(struct block_device *bdev)
{
    (void)bdev;
    return 0;
}
#endif

#endif /* MESHSTOR_MD_COMPAT_H */

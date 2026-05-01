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

#endif /* MESHSTOR_MD_COMPAT_H */

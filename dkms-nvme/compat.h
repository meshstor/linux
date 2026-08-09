/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * meshstor-nvme-rdma compat.
 *
 * This package has no feature_flags probe infrastructure -- variant selection
 * is version-keyed by design (see README.md) -- so the guard tests the macro
 * itself rather than a HAVE_* flag. Upstream v6 patch 1 defines
 * BLK_STS_P2PDMA as a #define, so #ifndef is a valid detector, and rdma.c
 * includes <linux/blk-mq.h> (which pulls blk_types.h) before this header.
 *
 * Value 18 matches upstream and is unused on every supported target, so md --
 * which carries the same definition via dkms/compat/compat.h -- reads the
 * status we emit correctly.
 */
#ifndef MESHSTOR_NVME_COMPAT_H
#define MESHSTOR_NVME_COMPAT_H

#include <linux/blk_types.h>

#ifndef BLK_STS_P2PDMA
#define BLK_STS_P2PDMA ((__force blk_status_t)18)
#endif

#endif /* MESHSTOR_NVME_COMPAT_H */

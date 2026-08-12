// SPDX-License-Identifier: GPL-2.0
/*
 * inval-inject -- TEST-ONLY fault injector for the p2pdma campaign.
 *
 * A kprobe on raid1_end_write_request (raid1_ms) or raid10_end_write_request
 * (raid10_ms) rewrites a member data-write completion's blk_status before the
 * personality processes it.  Modes:
 *
 *   match=ioerr   (default) rewrite completions that FAILED with
 *                 BLK_STS_IOERR -- the historical P6 rig shape (dm-flakey
 *                 error_writes under one leg + rewrite to INVAL emulates the
 *                 P2PDMA partial-reachability completion).
 *   match=success rewrite completions that SUCCEEDED (BLK_STS_OK) -- the P7
 *                 rig shape: data reaches media, then the status is rewritten,
 *                 exercising the stage-1 completion arm without dm-flakey.
 *   match=any     rewrite regardless of prior status.
 *
 *   to_status=inval|target|<numeric>  what to rewrite TO (default inval).
 *
 *   p2p_only=1    rewrite only completions whose bio carries PCI P2PDMA
 *                 (GPU BAR) pages.  Default matrix: 0 when match=ioerr
 *                 (P6-compatible), 1 otherwise.  MANDATORY for any arming
 *                 while a filesystem is mounted on the array: cuFile
 *                 registers files on mounted XFS, so journal/metadata writes
 *                 traverse the probed function; a plain (non-P2P) write
 *                 rewritten to TARGET takes the real-error path and faults a
 *                 FailFast leg via md_error(), and a plain INVAL is silently
 *                 swallowed (stale leg).  The P2P page test reads the leg
 *                 clone's bi_io_vec directly: at completion bi_iter.bi_size
 *                 is 0 (so bio_has_data() would be false), but the clone's
 *                 bi_io_vec still points at the master bio's live bvecs (the
 *                 master strictly outlives leg completions in the raid1/
 *                 raid10 write paths), so is_pci_p2pdma_page() on the first
 *                 bvec page is valid here.  Do NOT replace with
 *                 md_bio_is_p2pdma()/bio_has_data().
 *
 * symbol= must be MODULE-QUALIFIED (mod:name, e.g.
 * raid1_ms:raid1_end_write_request) whenever match!=ioerr, to_status= is
 * set, or p2p_only=1: the bare name is ambiguous whenever the in-tree raid1
 * module is co-loaded (mis-bind observed live), and in-kernel multiplicity
 * detection is not implementable (the enumeration helpers are unexported),
 * so init refuses un-qualified arming in the modes that could rewrite live
 * traffic.  kallsyms resolves the mod:name form within the named module.
 *
 * Interception scope: only the personality's per-leg DATA write completions
 * pass through the probed functions.  Superblock and bitmap writes go via
 * md_write_metadata() with their own rdev end_io and never reach here, so
 * match=success cannot poison CSI-shape bitmap/SB traffic.  Never ship or
 * load in production.
 *
 * insmod inval_inject.ko symbol=raid1_ms:raid1_end_write_request \
 *        disk=nvme0n1 partno=5 match=success to_status=inval p2p_only=1
 * echo 1 > /sys/module/inval_inject/parameters/remaining    # arm
 * cat /sys/module/inval_inject/parameters/injected          # evidence
 */
#include <linux/module.h>
#include <linux/kprobes.h>
#include <linux/ptrace.h>
#include <asm/ptrace.h>
#include <linux/bio.h>
#include <linux/blkdev.h>
#include <linux/memremap.h>

static char symbol[64] = "raid1_end_write_request";
module_param_string(symbol, symbol, sizeof(symbol), 0444);
MODULE_PARM_DESC(symbol, "completion function to intercept (module-qualified mod:name form)");

static char disk[DISK_NAME_LEN] = "";
module_param_string(disk, disk, sizeof(disk), 0644);
MODULE_PARM_DESC(disk, "gendisk name of the target member (e.g. dm-0, nvme0n1)");

static int partno = -1;
module_param(partno, int, 0644);
MODULE_PARM_DESC(partno, "partition number to match (-1 = any, 0 = whole disk)");

static char to_status_str[16] = "";
module_param_string(to_status, to_status_str, sizeof(to_status_str), 0444);
MODULE_PARM_DESC(to_status, "status to rewrite to: inval (default) | target | numeric blk_status");

static char match[8] = "ioerr";
module_param_string(match, match, sizeof(match), 0444);
MODULE_PARM_DESC(match, "which completions to rewrite: ioerr (default) | success | any");

static int p2p_only = -1;
module_param(p2p_only, int, 0444);
MODULE_PARM_DESC(p2p_only, "rewrite only P2PDMA-page bios (default: 0 for match=ioerr, 1 otherwise)");

static int remaining;
module_param(remaining, int, 0644);
MODULE_PARM_DESC(remaining, "matching write completions left to rewrite (0 = disarmed)");

static unsigned long injected;
module_param(injected, ulong, 0444);
MODULE_PARM_DESC(injected, "completions rewritten so far");

enum { MATCH_IOERR, MATCH_SUCCESS, MATCH_ANY };
static int match_mode;
static blk_status_t to_status;

static int inval_pre(struct kprobe *kp, struct pt_regs *regs)
{
	struct bio *bio = (struct bio *)regs_get_kernel_argument(regs, 0);

	if (!bio || !bio->bi_bdev || READ_ONCE(remaining) <= 0)
		return 0;
	if (bio_data_dir(bio) != WRITE)
		return 0;
	switch (match_mode) {
	case MATCH_IOERR:
		if (bio->bi_status != BLK_STS_IOERR)
			return 0;
		break;
	case MATCH_SUCCESS:
		if (bio->bi_status != BLK_STS_OK)
			return 0;
		break;
	case MATCH_ANY:
		break;
	}
	if (strcmp(bio->bi_bdev->bd_disk->disk_name, disk) != 0)
		return 0;
	if (partno >= 0 && bdev_partno(bio->bi_bdev) != partno)
		return 0;
	if (p2p_only) {
		/* see header comment: completion-time bvec access is valid on
		 * the leg clone; bio_has_data() is NOT (bi_iter.bi_size == 0). */
		if (!bio->bi_io_vec ||
		    !is_pci_p2pdma_page(bio->bi_io_vec->bv_page))
			return 0;
	}

	bio->bi_status = to_status;
	injected++;		/* racy under concurrency; fine for a test rig */
	remaining--;
	return 0;
}

static struct kprobe kp = { .pre_handler = inval_pre };

static int __init inval_init(void)
{
	unsigned int v;

	if (strcmp(match, "ioerr") == 0)
		match_mode = MATCH_IOERR;
	else if (strcmp(match, "success") == 0)
		match_mode = MATCH_SUCCESS;
	else if (strcmp(match, "any") == 0)
		match_mode = MATCH_ANY;
	else {
		pr_err("inval_inject: match= must be ioerr|success|any\n");
		return -EINVAL;
	}

	if (!to_status_str[0] || strcmp(to_status_str, "inval") == 0)
		to_status = BLK_STS_INVAL;
	else if (strcmp(to_status_str, "target") == 0)
		to_status = BLK_STS_TARGET;
	else if (kstrtouint(to_status_str, 0, &v) == 0)
		to_status = (__force blk_status_t)v;
	else {
		pr_err("inval_inject: to_status= must be inval|target|numeric\n");
		return -EINVAL;
	}

	/* default matrix: 0 when match=ioerr (P6-compatible), 1 otherwise */
	if (p2p_only < 0)
		p2p_only = strcmp(match, "ioerr") == 0 ? 0 : 1;

	/* refuse-rule: module_param cannot distinguish an explicit p2p_only=0
	 * from its default, so the rule is worded on the resolved/explicit
	 * values: any mode that can rewrite live traffic needs mod:name. */
	if ((match_mode != MATCH_IOERR || to_status_str[0] || p2p_only == 1) &&
	    !strchr(symbol, ':')) {
		pr_err("inval_inject: symbol= must be module-qualified (mod:name) when match!=ioerr, to_status= is set, or p2p_only=1\n");
		return -EINVAL;
	}

	kp.symbol_name = symbol;
	return register_kprobe(&kp);
}

static void __exit inval_exit(void)
{
	unregister_kprobe(&kp);
}

module_init(inval_init);
module_exit(inval_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("blk_status completion injector (p2pdma campaign test rig)");

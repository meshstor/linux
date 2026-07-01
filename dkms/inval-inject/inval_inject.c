// SPDX-License-Identifier: GPL-2.0
/*
 * inval-inject -- TEST-ONLY fault injector for the p2pdma divergence repro.
 *
 * A kprobe on raid1_end_write_request (raid1_ms) rewrites a member write
 * completion from BLK_STS_IOERR to BLK_STS_INVAL before raid1 processes it.
 * Combined with dm-flakey (error_writes) under one leg this emulates exactly
 * the P2PDMA partial-reachability failure: the write never reaches media AND
 * completes BLK_STS_INVAL -- which the current base swallows (silent mirror
 * divergence, follow-up spec S2/Finding L).  Never ship or load in production.
 *
 * insmod inval_inject.ko disk=dm-0 partno=-1
 * echo 1000000 > /sys/module/inval_inject/parameters/remaining   # arm
 * cat /sys/module/inval_inject/parameters/injected               # evidence
 */
#include <linux/module.h>
#include <linux/kprobes.h>
#include <linux/ptrace.h>
#include <asm/ptrace.h>
#include <linux/bio.h>
#include <linux/blkdev.h>

static char symbol[64] = "raid1_end_write_request";
module_param_string(symbol, symbol, sizeof(symbol), 0444);
MODULE_PARM_DESC(symbol, "completion function to intercept");

static char disk[DISK_NAME_LEN] = "";
module_param_string(disk, disk, sizeof(disk), 0644);
MODULE_PARM_DESC(disk, "gendisk name of the target member (e.g. dm-0, loop3)");

static int partno = -1;
module_param(partno, int, 0644);
MODULE_PARM_DESC(partno, "partition number to match (-1 = any, 0 = whole disk)");

static int remaining;
module_param(remaining, int, 0644);
MODULE_PARM_DESC(remaining, "IOERR write completions left to rewrite to INVAL (0 = disarmed)");

static unsigned long injected;
module_param(injected, ulong, 0444);
MODULE_PARM_DESC(injected, "completions rewritten so far");

static int inval_pre(struct kprobe *kp, struct pt_regs *regs)
{
	struct bio *bio = (struct bio *)regs_get_kernel_argument(regs, 0);

	if (!bio || !bio->bi_bdev || READ_ONCE(remaining) <= 0)
		return 0;
	if (bio->bi_status != BLK_STS_IOERR || bio_data_dir(bio) != WRITE)
		return 0;
	if (strcmp(bio->bi_bdev->bd_disk->disk_name, disk) != 0)
		return 0;
	if (partno >= 0 && bdev_partno(bio->bi_bdev) != partno)
		return 0;

	bio->bi_status = BLK_STS_INVAL;
	injected++;		/* racy under concurrency; fine for a test rig */
	remaining--;
	return 0;
}

static struct kprobe kp = { .pre_handler = inval_pre };

static int __init inval_init(void)
{
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
MODULE_DESCRIPTION("BLK_STS_INVAL completion injector (p2pdma divergence test rig)");

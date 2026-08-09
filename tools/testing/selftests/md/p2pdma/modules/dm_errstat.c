// SPDX-License-Identifier: GPL-2.0
/*
 * dm-errstat: linear passthrough that, when armed, fails armed data I/O
 * with a configurable blk_status_t; metadata/flush-class writes
 * (REQ_META/REQ_PREFLUSH/REQ_FUA -- md superblock traffic) always pass, so
 * an armed window cannot fault an md leg via its own superblock update.
 * Lets a test make an md member return BLK_STS_TARGET / BLK_STS_INVAL /
 * BLK_STS_P2PDMA -- statuses dm-flakey cannot produce. Starts disarmed so
 * array creation (superblock writes) succeeds; arm only around the I/O
 * under test.
 *
 * Table load: <dev> <status-spec>
 *   <status-spec> := <slot> | <slot>,<slot>
 *   <slot>        := <errno 0-600> | p2pdma   (case-insensitive)
 *
 * A single <slot> fails every armed, eligible bio with that status. A
 * "<first>,<rest>" pair fails the FIRST armed, eligible bio with <first>
 * and every one after it (until "reset") with <rest> -- this reproduces,
 * deterministically and without racy userspace timing, the scenario where
 * a write's initial attempt hits a real (non-P2P) error and md's
 * per-block narrow_write_error() retries then hit a P2PDMA status.
 *
 * Messages:
 *   dmsetup message legB 0 arm [write|read|both]   (default: write)
 *   dmsetup message legB 0 disarm
 *   dmsetup message legB 0 reset                   (rearm the first/rest
 *                                                    sequence at "first")
 *
 * Example:
 *   dmsetup create legB --table \
 *       "0 $(blockdev --getsz /dev/ram1) errstat /dev/ram1 5,p2pdma"
 *   dmsetup message legB 0 arm
 */
#include <linux/module.h>
#include <linux/device-mapper.h>
#include <linux/bio.h>
#include <linux/string.h>

/*
 * Upstream v6 patch 1 ("block: add BLK_STS_P2PDMA for unsupported
 * peer-to-peer transfers") adds this status; every kernel that predates
 * it leaves index 18 as a zero-filled hole in blk_errors[], so
 * blk_status_to_errno(18) returns 0 there -- that asymmetry is exactly
 * what several of the selftests in this directory exist to probe, so the
 * injector must be able to produce the raw value on any host kernel.
 */
#ifndef BLK_STS_P2PDMA
#define BLK_STS_P2PDMA ((__force blk_status_t)18)
#endif

#define ERRSTAT_OP_WRITE 0x1
#define ERRSTAT_OP_READ  0x2

struct errstat_ctx {
	struct dm_dev *dev;
	blk_status_t status_first;
	blk_status_t status_rest;
	bool has_rest;
	atomic_t seq_done;	/* 0 = next failure uses status_first */
	bool armed;
	unsigned int armed_ops;	/* ERRSTAT_OP_{WRITE,READ} bitmask */
};

/*
 * Recorded at map time: whether the bio carried data, and whether it is
 * exempt from failure (metadata/flush class). The underlying driver may
 * consume the clone's bi_iter in place while processing it (brd on 6.17
 * does), leaving bio_sectors() == 0 by end_io time, so data writes
 * cannot be told from empty flushes at completion; bi_opf is likewise
 * snapshotted at map time.
 */
struct errstat_pb {
	bool had_data;
	bool exempt;
	bool killed;
	enum req_op op;
};

/* parse one <slot>: an errno (0-600) or the literal "p2pdma" */
static bool errstat_parse_slot(const char *s, blk_status_t *out)
{
	long err;

	if (!strcasecmp(s, "p2pdma")) {
		*out = BLK_STS_P2PDMA;
		return true;
	}
	if (kstrtol(s, 10, &err) || err < 0 || err > 600)
		return false;
	*out = errno_to_blk_status(-(int)err);
	return true;
}

static int errstat_ctr(struct dm_target *ti, unsigned int argc, char **argv)
{
	struct errstat_ctx *ec;
	char buf[32];
	char *comma;
	int r;

	if (argc != 2) {
		ti->error = "need: <dev> <status-spec>";
		return -EINVAL;
	}
	if (strscpy(buf, argv[1], sizeof(buf)) < 0) {
		ti->error = "status-spec too long";
		return -EINVAL;
	}
	ec = kzalloc(sizeof(*ec), GFP_KERNEL);
	if (!ec)
		return -ENOMEM;

	comma = strchr(buf, ',');
	if (comma) {
		*comma = '\0';
		ec->has_rest = true;
		if (!errstat_parse_slot(buf, &ec->status_first) ||
		    !errstat_parse_slot(comma + 1, &ec->status_rest)) {
			ti->error = "bad status-spec";
			kfree(ec);
			return -EINVAL;
		}
	} else {
		if (!errstat_parse_slot(buf, &ec->status_first)) {
			ti->error = "bad status-spec";
			kfree(ec);
			return -EINVAL;
		}
		ec->status_rest = ec->status_first;
	}
	ec->armed_ops = ERRSTAT_OP_WRITE;
	atomic_set(&ec->seq_done, 0);

	r = dm_get_device(ti, argv[0], dm_table_get_mode(ti->table), &ec->dev);
	if (r) {
		ti->error = "device lookup failed";
		kfree(ec);
		return r;
	}
	ti->num_flush_bios = 1;
	ti->per_io_data_size = sizeof(struct errstat_pb);
	ti->private = ec;
	return 0;
}

static void errstat_dtr(struct dm_target *ti)
{
	struct errstat_ctx *ec = ti->private;

	dm_put_device(ti, ec->dev);
	kfree(ec);
}

static int errstat_map(struct dm_target *ti, struct bio *bio)
{
	struct errstat_ctx *ec = ti->private;
	struct errstat_pb *pb = dm_per_bio_data(bio, sizeof(*pb));
	unsigned int op_bit = 0;

	pb->had_data = bio_sectors(bio) != 0;
	pb->exempt = (bio->bi_opf & (REQ_META | REQ_PREFLUSH | REQ_FUA)) != 0;
	pb->killed = false;
	pb->op = bio_op(bio);

	if (pb->op == REQ_OP_WRITE)
		op_bit = ERRSTAT_OP_WRITE;
	else if (pb->op == REQ_OP_READ)
		op_bit = ERRSTAT_OP_READ;

	if (READ_ONCE(ec->armed) && pb->had_data && !pb->exempt &&
	    (op_bit & READ_ONCE(ec->armed_ops))) {
		/*
		 * Fail WITHOUT submitting downstream. A real unroutable
		 * P2P transfer dies at DMA mapping, before any byte moves,
		 * so the armed leg must never see the data either --
		 * completion-path override (remap, then rewrite the status
		 * in end_io) leaves the legs byte-identical yet fenced,
		 * which test_divergence_oracle.sh rightly rejects as
		 * inconsistent.
		 */
		pb->killed = true;
		if (ec->has_rest && atomic_cmpxchg(&ec->seq_done, 0, 1) != 0)
			bio->bi_status = ec->status_rest;
		else
			bio->bi_status = ec->status_first;
		bio_endio(bio);
		return DM_MAPIO_SUBMITTED;
	}

	bio_set_dev(bio, ec->dev->bdev);
	return DM_MAPIO_REMAPPED;
}

static int errstat_end_io(struct dm_target *ti, struct bio *bio,
			   blk_status_t *error)
{
	struct errstat_ctx *ec = ti->private;
	struct errstat_pb *pb = dm_per_bio_data(bio, sizeof(*pb));
	unsigned int op_bit;

	/* bios we already failed at map time keep their status as-is */
	if (pb->killed)
		return DM_ENDIO_DONE;
	if (!READ_ONCE(ec->armed) || !pb->had_data || pb->exempt)
		return DM_ENDIO_DONE;

	if (pb->op == REQ_OP_WRITE)
		op_bit = ERRSTAT_OP_WRITE;
	else if (pb->op == REQ_OP_READ)
		op_bit = ERRSTAT_OP_READ;
	else
		return DM_ENDIO_DONE;

	if (!(op_bit & READ_ONCE(ec->armed_ops)))
		return DM_ENDIO_DONE;

	if (ec->has_rest && atomic_cmpxchg(&ec->seq_done, 0, 1) != 0)
		*error = ec->status_rest;
	else
		*error = ec->status_first;
	return DM_ENDIO_DONE;
}

static int errstat_message(struct dm_target *ti, unsigned int argc,
			   char **argv, char *result, unsigned int maxlen)
{
	struct errstat_ctx *ec = ti->private;

	if (argc < 1 || argc > 2)
		return -EINVAL;
	if (!strcmp(argv[0], "arm")) {
		unsigned int ops = ERRSTAT_OP_WRITE;

		if (argc == 2) {
			if (!strcmp(argv[1], "read"))
				ops = ERRSTAT_OP_READ;
			else if (!strcmp(argv[1], "write"))
				ops = ERRSTAT_OP_WRITE;
			else if (!strcmp(argv[1], "both"))
				ops = ERRSTAT_OP_WRITE | ERRSTAT_OP_READ;
			else
				return -EINVAL;
		}
		WRITE_ONCE(ec->armed_ops, ops);
		WRITE_ONCE(ec->armed, true);
	} else if (!strcmp(argv[0], "disarm")) {
		if (argc != 1)
			return -EINVAL;
		WRITE_ONCE(ec->armed, false);
	} else if (!strcmp(argv[0], "reset")) {
		if (argc != 1)
			return -EINVAL;
		atomic_set(&ec->seq_done, 0);
	} else {
		return -EINVAL;
	}
	return 0;
}

static struct target_type errstat_target = {
	.name     = "errstat",
	.version  = {1, 1, 0},
	.module   = THIS_MODULE,
	.ctr      = errstat_ctr,
	.dtr      = errstat_dtr,
	.map      = errstat_map,
	.end_io   = errstat_end_io,
	.message  = errstat_message,
};

static int __init dm_errstat_init(void)
{
	return dm_register_target(&errstat_target);
}

static void __exit dm_errstat_exit(void)
{
	dm_unregister_target(&errstat_target);
}

module_init(dm_errstat_init);
module_exit(dm_errstat_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("dm passthrough failing armed read/write I/O with a chosen blk_status, optionally sequenced");

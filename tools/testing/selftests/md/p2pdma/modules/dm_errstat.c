// SPDX-License-Identifier: GPL-2.0
/*
 * dm-errstat: linear passthrough that, when armed, fails armed data
 * WRITEs with a configurable blk_status_t (given as an errno at table
 * load); metadata/flush-class writes (REQ_META/REQ_PREFLUSH/REQ_FUA —
 * md superblock traffic) always pass, so an armed window cannot fault
 * an md leg via its own superblock update. Lets a test make an md
 * member return BLK_STS_TARGET / BLK_STS_INVAL — statuses dm-flakey
 * cannot produce. Starts disarmed so array creation (superblock
 * writes) succeeds; arm only around the I/O under test:
 *
 *   dmsetup create legB --table "0 $(blockdev --getsz /dev/ram1) errstat /dev/ram1 121"
 *   dmsetup message legB 0 arm
 */
#include <linux/module.h>
#include <linux/device-mapper.h>
#include <linux/bio.h>

struct errstat_ctx {
	struct dm_dev *dev;
	blk_status_t status;
	bool armed;
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
};

static int errstat_ctr(struct dm_target *ti, unsigned int argc, char **argv)
{
	struct errstat_ctx *ec;
	long err;
	int r;

	if (argc != 2) {
		ti->error = "need: <dev> <errno>";
		return -EINVAL;
	}
	ec = kzalloc(sizeof(*ec), GFP_KERNEL);
	if (!ec)
		return -ENOMEM;
	if (kstrtol(argv[1], 10, &err) || err < 0 || err > 600) {
		ti->error = "bad errno";
		kfree(ec);
		return -EINVAL;
	}
	ec->status = errno_to_blk_status(-(int)err);
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

	pb->had_data = bio_sectors(bio) != 0;
	pb->exempt = (bio->bi_opf & (REQ_META | REQ_PREFLUSH | REQ_FUA)) != 0;
	bio_set_dev(bio, ec->dev->bdev);
	return DM_MAPIO_REMAPPED;
}

static int errstat_end_io(struct dm_target *ti, struct bio *bio,
			  blk_status_t *error)
{
	struct errstat_ctx *ec = ti->private;
	struct errstat_pb *pb = dm_per_bio_data(bio, sizeof(*pb));

	if (READ_ONCE(ec->armed) && ec->status &&
	    bio_op(bio) == REQ_OP_WRITE && pb->had_data && !pb->exempt)
		*error = ec->status;
	return DM_ENDIO_DONE;
}

static int errstat_message(struct dm_target *ti, unsigned int argc,
			   char **argv, char *result, unsigned int maxlen)
{
	struct errstat_ctx *ec = ti->private;

	if (argc != 1)
		return -EINVAL;
	if (!strcmp(argv[0], "arm"))
		WRITE_ONCE(ec->armed, true);
	else if (!strcmp(argv[0], "disarm"))
		WRITE_ONCE(ec->armed, false);
	else
		return -EINVAL;
	return 0;
}

static struct target_type errstat_target = {
	.name     = "errstat",
	.version  = {1, 0, 0},
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
MODULE_DESCRIPTION("dm passthrough failing armed WRITEs with a chosen blk_status");

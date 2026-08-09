// SPDX-License-Identifier: GPL-2.0
/*
 * md_p2p_test: submit one WRITE or READ bio built from PCI P2PDMA pages
 * (pci_alloc_p2pmem() from a provider such as an NVMe CMB) to a block
 * device, then report the completion status.
 *
 * The whole test happens in module_init:
 *   insmod md_p2p_test.ko provider=0000:02:00.0 target=/dev/ms0 op=write
 * Result is logged as:
 *   md_p2p_test: result op=write target=/dev/ms0 status=8 errno=-22
 * and module_init returns that errno: a failed I/O fails the insmod (no
 * module left behind); a successful one loads and must be rmmod'ed.
 */
#include <linux/module.h>
#include <linux/pci.h>
#include <linux/pci-p2pdma.h>
#include <linux/blkdev.h>
#include <linux/bio.h>

static char *provider = "";
module_param(provider, charp, 0444);
MODULE_PARM_DESC(provider, "PCI BDF of the p2pmem provider, e.g. 0000:02:00.0");

static char *target = "";
module_param(target, charp, 0444);
MODULE_PARM_DESC(target, "block device to submit to, e.g. /dev/ms0");

static char *op = "write";
module_param(op, charp, 0444);
MODULE_PARM_DESC(op, "write (default) or read");

static unsigned int kib = 8;
module_param(kib, uint, 0444);
MODULE_PARM_DESC(kib, "I/O size in KiB, page-multiple (default 8)");

static int __init md_p2p_test_init(void)
{
	unsigned int domain, bus, slot, func, npages, i;
	struct pci_dev *pdev = NULL;
	struct file *bdev_file = NULL;
	struct block_device *bdev;
	void *mem = NULL;
	struct bio *bio = NULL;
	size_t size = (size_t)kib * 1024;
	blk_opf_t opf;
	int ret;

	if (sscanf(provider, "%x:%x:%x.%x", &domain, &bus, &slot, &func) != 4) {
		pr_err("md_p2p_test: bad provider BDF '%s'\n", provider);
		return -EINVAL;
	}
	if (!size || (size & ~PAGE_MASK) || (size >> PAGE_SHIFT) > BIO_MAX_VECS) {
		pr_err("md_p2p_test: kib must be a page multiple <= %lu KiB\n",
		       (unsigned long)BIO_MAX_VECS << (PAGE_SHIFT - 10));
		return -EINVAL;
	}
	npages = size >> PAGE_SHIFT;

	if (!strcmp(op, "write"))
		opf = REQ_OP_WRITE | REQ_NOMERGE | REQ_SYNC;
	else if (!strcmp(op, "read"))
		opf = REQ_OP_READ | REQ_NOMERGE;
	else
		return -EINVAL;

	pdev = pci_get_domain_bus_and_slot(domain, bus, PCI_DEVFN(slot, func));
	if (!pdev) {
		pr_err("md_p2p_test: provider %s not found\n", provider);
		return -ENODEV;
	}

	mem = pci_alloc_p2pmem(pdev, size);
	if (!mem) {
		pr_err("md_p2p_test: pci_alloc_p2pmem(%zu) failed\n", size);
		ret = -ENOMEM;
		goto out_pdev;
	}

	bdev_file = bdev_file_open_by_path(target,
			BLK_OPEN_READ | BLK_OPEN_WRITE, NULL, NULL);
	if (IS_ERR(bdev_file)) {
		ret = PTR_ERR(bdev_file);
		pr_err("md_p2p_test: open %s: %d\n", target, ret);
		bdev_file = NULL;
		goto out_mem;
	}
	bdev = file_bdev(bdev_file);

	bio = bio_alloc(bdev, npages, opf, GFP_KERNEL);
	bio->bi_iter.bi_sector = 0;
	for (i = 0; i < npages; i++) {
		if (bio_add_page(bio, virt_to_page(mem + i * PAGE_SIZE),
				 PAGE_SIZE, 0) != PAGE_SIZE) {
			pr_err("md_p2p_test: bio_add_page failed\n");
			ret = -EIO;
			goto out_bio;
		}
	}
	if (op_is_write(opf))
		memset(mem, 0xa5, size);   /* CMB is memremapped: CPU-writable */

	ret = submit_bio_wait(bio);
	pr_info("md_p2p_test: result op=%s target=%s status=%u errno=%d\n",
		op, target, (unsigned int)bio->bi_status, ret);

out_bio:
	bio_put(bio);
	fput(bdev_file);
out_mem:
	pci_free_p2pmem(pdev, mem, size);
out_pdev:
	pci_dev_put(pdev);
	return ret;
}

static void __exit md_p2p_test_exit(void) { }

module_init(md_p2p_test_init);
module_exit(md_p2p_test_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("submit one PCI P2PDMA bio and report its status");

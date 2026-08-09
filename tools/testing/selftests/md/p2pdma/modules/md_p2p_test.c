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
 *
 * mixed=1 builds a bio whose FIRST segment is an ordinary host page and
 * whose remaining segments are P2P (device) pages. A bio is tagged as a
 * P2P bio purely from bi_io_vec[0] (see md_bio_is_p2pdma() in the md
 * tree), so a mixed bio is never tagged even though most of its payload
 * is device memory -- it takes the ordinary (non-P2P) error path. Needs
 * npages >= 2.
 *
 * check_fill=<byte> (op=read only) verifies the data actually read back
 * matches the given byte, catching the read-side analogue of silent
 * divergence: a completion reported as success (errno 0) that actually
 * returned stale/wrong data.
 */
#include <linux/module.h>
#include <linux/pci.h>
#include <linux/pci-p2pdma.h>
#include <linux/blkdev.h>
#include <linux/bio.h>
#include <linux/mm.h>

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

static unsigned long sector;
module_param(sector, ulong, 0444);
MODULE_PARM_DESC(sector, "array-relative starting sector (default 0)");

static unsigned char fill = 0xa5;
module_param(fill, byte, 0444);
MODULE_PARM_DESC(fill, "byte pattern written on a write op (default 0xa5)");

static bool mixed;
module_param(mixed, bool, 0444);
MODULE_PARM_DESC(mixed, "make bi_io_vec[0] an ordinary host page (untagged bio); needs kib >= 8");

static int check_fill = -1;
module_param(check_fill, int, 0444);
MODULE_PARM_DESC(check_fill, "op=read only: expected fill byte (0-255) to verify the read data against; -1 = don't check (default). A completion that reports success but returns the wrong bytes is itself a silent-divergence bug, so a mismatch overrides a 0 errno to -EIO.");

static bool probe_mixed;
module_param(probe_mixed, bool, 0444);
MODULE_PARM_DESC(probe_mixed, "probe only: report whether this kernel permits a host page and a P2P page in the SAME bio, then return without submitting any I/O");

/*
 * Positive probe of this kernel's bio-composition rule (probe_mixed=1).
 *
 * From 6.17 on, bio_add_page() refuses a page whose pgmap does not match
 * the previous bvec's, so a host page followed by a P2P page cannot be
 * put in one bio at all. 6.12/6.14 have no such rule.
 *
 * bio_add_page() also returns 0 for reasons that have nothing to do with
 * that rule -- a cloned bio, a full bvec array, a size overflow -- so "the
 * add was refused" proves nothing on its own. Inferring the rule from a
 * bare failure would let an unrelated bug in this module read as "the
 * kernel closed the hole", which is precisely the laundering the callers
 * of this probe exist to avoid. So two CONTROLS run alongside the case
 * under test, on identically-shaped bios:
 *
 *   host_pair  host page  + host page  -> must be permitted
 *   dev_pair   P2P page   + P2P page   -> must be permitted (same pgmap)
 *   mixed      host page  + P2P page   -> the question
 *
 * Only "host_pair=1 dev_pair=1 mixed=0" is evidence of the pgmap rule;
 * any other combination means the probe itself is untrustworthy and the
 * caller must treat the result as indeterminate. Reported as:
 *   md_p2p_test: mixed_pgmap_probe host_pair=1 dev_pair=1 mixed=0
 *
 * The bios are built and freed, never submitted, so this needs a target
 * only to give bio_alloc() a bdev.
 */
static int __init md_p2p_probe_mixed(struct block_device *bdev,
				     struct pci_dev *pdev)
{
	struct page *host_a = NULL, *host_b = NULL;
	void *mem = NULL;
	struct bio *bio;
	int host_pair = 0, dev_pair = 0, mixed = 0;
	int ret = 0;

	host_a = alloc_page(GFP_KERNEL);
	host_b = alloc_page(GFP_KERNEL);
	mem = pci_alloc_p2pmem(pdev, 2 * PAGE_SIZE);
	if (!host_a || !host_b || !mem) {
		pr_err("md_p2p_test: probe_mixed: allocation failed\n");
		ret = -ENOMEM;
		goto out;
	}

	/* Both adds count: if the FIRST one fails the control is broken too. */
	bio = bio_alloc(bdev, 2, REQ_OP_WRITE, GFP_KERNEL);
	host_pair = bio_add_page(bio, host_a, PAGE_SIZE, 0) == PAGE_SIZE &&
		    bio_add_page(bio, host_b, PAGE_SIZE, 0) == PAGE_SIZE;
	bio_put(bio);

	bio = bio_alloc(bdev, 2, REQ_OP_WRITE, GFP_KERNEL);
	dev_pair = bio_add_page(bio, virt_to_page(mem),
				PAGE_SIZE, 0) == PAGE_SIZE &&
		   bio_add_page(bio, virt_to_page(mem + PAGE_SIZE),
				PAGE_SIZE, 0) == PAGE_SIZE;
	bio_put(bio);

	bio = bio_alloc(bdev, 2, REQ_OP_WRITE, GFP_KERNEL);
	mixed = bio_add_page(bio, host_a, PAGE_SIZE, 0) == PAGE_SIZE &&
		bio_add_page(bio, virt_to_page(mem), PAGE_SIZE, 0) == PAGE_SIZE;
	bio_put(bio);

	pr_info("md_p2p_test: mixed_pgmap_probe host_pair=%d dev_pair=%d mixed=%d\n",
		host_pair, dev_pair, mixed);
out:
	if (mem)
		pci_free_p2pmem(pdev, mem, 2 * PAGE_SIZE);
	if (host_b)
		__free_page(host_b);
	if (host_a)
		__free_page(host_a);
	return ret;
}

static int __init md_p2p_test_init(void)
{
	unsigned int domain, bus, slot, func, npages, i, ndev;
	struct pci_dev *pdev = NULL;
	struct file *bdev_file = NULL;
	struct block_device *bdev;
	void *mem = NULL;
	struct page *host_page = NULL;
	struct bio *bio = NULL;
	size_t size = (size_t)kib * 1024;
	size_t dev_size;
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
	if (mixed && npages < 2) {
		pr_err("md_p2p_test: mixed=1 needs kib >= 2*(PAGE_SIZE/1024)\n");
		return -EINVAL;
	}
	ndev = mixed ? npages - 1 : npages;
	dev_size = (size_t)ndev << PAGE_SHIFT;

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

	mem = pci_alloc_p2pmem(pdev, dev_size);
	if (!mem) {
		pr_err("md_p2p_test: pci_alloc_p2pmem(%zu) failed\n", dev_size);
		ret = -ENOMEM;
		goto out_pdev;
	}

	if (mixed) {
		host_page = alloc_page(GFP_KERNEL);
		if (!host_page) {
			ret = -ENOMEM;
			goto out_mem;
		}
	}

	bdev_file = bdev_file_open_by_path(target,
			BLK_OPEN_READ | BLK_OPEN_WRITE, NULL, NULL);
	if (IS_ERR(bdev_file)) {
		ret = PTR_ERR(bdev_file);
		pr_err("md_p2p_test: open %s: %d\n", target, ret);
		bdev_file = NULL;
		goto out_host_page;
	}
	bdev = file_bdev(bdev_file);

	if (probe_mixed) {
		ret = md_p2p_probe_mixed(bdev, pdev);
		fput(bdev_file);
		goto out_host_page;
	}

	bio = bio_alloc(bdev, npages, opf, GFP_KERNEL);
	bio->bi_iter.bi_sector = sector;

	if (mixed) {
		if (bio_add_page(bio, host_page, PAGE_SIZE, 0) != PAGE_SIZE) {
			pr_err("md_p2p_test: bio_add_page (host) failed\n");
			ret = -EIO;
			goto out_bio;
		}
	}
	for (i = 0; i < ndev; i++) {
		if (bio_add_page(bio, virt_to_page(mem + i * PAGE_SIZE),
				 PAGE_SIZE, 0) != PAGE_SIZE) {
			/*
			 * A refusal of the FIRST device page of a mixed bio is
			 * the >= 6.17 pgmap rule (see md_p2p_probe_mixed()):
			 * the bio cannot be built, so no I/O happens and no
			 * result line follows. Say so distinctly -- a caller
			 * must be able to tell "this kernel forbids the
			 * scenario" from "this module broke", and both used to
			 * surface identically as a missing result line.
			 */
			if (mixed && i == 0) {
				pr_err("md_p2p_test: mixed_pgmap_rejected: kernel refused a P2P page after a host page; no I/O submitted (run probe_mixed=1 to confirm the rule)\n");
				ret = -EOPNOTSUPP;
			} else {
				pr_err("md_p2p_test: bio_add_page (dev) failed at %u/%u\n",
				       i, ndev);
				ret = -EIO;
			}
			goto out_bio;
		}
	}
	if (op_is_write(opf)) {
		memset(mem, fill, dev_size);   /* CMB is memremapped: CPU-writable */
		if (mixed)
			memset(page_address(host_page), fill, PAGE_SIZE);
	}

	ret = submit_bio_wait(bio);

	if (!ret && !op_is_write(opf) && check_fill >= 0) {
		u8 *p = mem;
		size_t j;

		for (j = 0; j < dev_size; j++) {
			if (p[j] != (u8)check_fill) {
				pr_err("md_p2p_test: content mismatch at byte %zu: got 0x%02x want 0x%02x\n",
				       j, p[j], (u8)check_fill);
				ret = -EIO;
				break;
			}
		}
	}

	pr_info("md_p2p_test: result op=%s target=%s sector=%lu mixed=%d status=%u errno=%d\n",
		op, target, sector, mixed, (unsigned int)bio->bi_status, ret);

out_bio:
	bio_put(bio);
	fput(bdev_file);
out_host_page:
	if (host_page)
		__free_page(host_page);
out_mem:
	pci_free_p2pmem(pdev, mem, dev_size);
out_pdev:
	pci_dev_put(pdev);
	return ret;
}

static void __exit md_p2p_test_exit(void) { }

module_init(md_p2p_test_init);
module_exit(md_p2p_test_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("submit one PCI P2PDMA (optionally mixed-pgmap) bio and report its status");

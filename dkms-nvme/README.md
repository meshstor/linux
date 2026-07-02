# meshstor-nvme-rdma — P2PDMA-enabled nvme-rdma backport (DKMS)

Rebuilds the target kernel's **own** `nvme-rdma` driver with upstream
`23528aa3320a` ("nvme: enable PCI P2PDMA support for RDMA transport",
first in v7.1-rc2) backported, and installs it to `/updates` where
depmod prefers it over the in-tree module (Ubuntu: `search updates
ubuntu built-in`; RHEL: `search updates extra built-in weak-updates`).
Removing the package restores the stock module — nothing is overwritten.

In-tree `nvme-core`/`nvme-fabrics` are used unchanged: the
`supports_pci_p2pdma` ctrl op they consult has been in-tree since v6.0
(`2f8594412b4b`); only the RDMA transport never wired it up before 7.1.

Supported kernel families (see `BUILD_EXCLUSIVE_KERNEL` in dkms.conf):

| Variant     | Family            | Source of vendored files            |
|-------------|-------------------|-------------------------------------|
| `u2404-hwe` | `6.17.*-generic`  | Launchpad noble `Ubuntu-hwe-6.17-*` |
| `u2604`     | `7.0.*-generic`   | Launchpad resolute `Ubuntu-7.0.0-*` |
| `rhel10`    | `6.12.*.el10*`    | Rocky 10 BaseOS kernel SRPM         |

## Why variant selection is version-keyed (exception to the HAVE_* rule)

`rdma.c` includes the private headers `nvme.h` and `fabrics.h`, which no
linux-headers / kernel-devel package ships, and `struct nvme_ctrl` is
shared **by layout** with the running nvme-core (it is embedded in
`nvme_rdma_ctrl`). A capability grep cannot probe headers that are not
on the target system, and MODVERSIONS does not catch the mismatch for
out-of-tree modules (modpost copies import CRCs verbatim from
Module.symvers). So each supported kernel family carries its own
byte-identical vendored copy of the three files, selected by kernel
release string and cross-checked against `KDIR`'s `utsrelease.h`.
Everything else in this repo gates on detected capabilities; this
package cannot.

## Refreshing after a distro kernel update

1. `bin/vendor-nvme-sources [--u2404 TAG] [--u2604 TAG] [--rhel10 NVR]`
   (defaults to latest; exit 3 = files changed).
2. For each variant `V` whose vendored `rdma.c` changed, regenerate that
   variant's patch:

   ```bash
   V=rhel10   # or u2404-hwe / u2604
   d="$(mktemp -d)"
   cp "dkms-nvme/vendor/$V/rdma.c" "$d/a-rdma.c"
   cp "dkms-nvme/vendor/$V/rdma.c" "$d/b-rdma.c"

   # (a) insert the capability-check helper immediately before the
   #     nvme_ctrl_ops table it feeds.
   perl -0pi -e 's/(static const struct nvme_ctrl_ops nvme_rdma_ctrl_ops = \{)/static bool nvme_rdma_supports_pci_p2pdma(struct nvme_ctrl *ctrl)\n\{\n\tstruct nvme_rdma_ctrl *r_ctrl = to_rdma_ctrl(ctrl);\n\n\treturn ib_dma_pci_p2p_dma_supported(r_ctrl->device->dev);\n}\n\n$1/' "$d/b-rdma.c"

   # (b) wire the op into the table, immediately before its closing "};"
   #     (scoped to the ops-table block so it doesn't match some other
   #     struct's closing brace earlier in the file).
   perl -0pi -e 's/(static const struct nvme_ctrl_ops nvme_rdma_ctrl_ops = \{.*?\n)\};\n/$1\t.supports_pci_p2pdma\t= nvme_rdma_supports_pci_p2pdma,\n};\n/s' "$d/b-rdma.c"

   {
       echo "Backport of upstream 23528aa3320a (\"nvme: enable PCI P2PDMA support"
       echo "for RDMA transport\", first in v7.1-rc2) onto the $V vendored rdma.c."
       echo "Applied by bin/build-nvme-tarball: patch -p1 --fuzz=0 -d <variant dir>."
       echo "Regeneration after re-vendoring: dkms-nvme/README.md, 'Refreshing'."
       echo
       diff -u --label a/rdma.c --label b/rdma.c "$d/a-rdma.c" "$d/b-rdma.c"
   } > "dkms-nvme/patches/$V/0001-nvme-rdma-enable-pci-p2pdma.patch"
   ```

   The `--label` form keeps the diff free of embedded timestamps
   (deliberate improvement over the original hand-generation). Verify it
   applies clean before trusting it:

   ```bash
   patch -p1 --dry-run --fuzz=0 -d dkms-nvme/vendor/$V \
       < "dkms-nvme/patches/$V/0001-nvme-rdma-enable-pci-p2pdma.patch"
   bash tools/testing/selftests/dkms/test_nvme_tarball_assembles.sh
   ```
3. Rebuild + redeploy the package.

## Caveats

- A host that carries `nvme-rdma` in its initramfs (NVMe-oF boot) must
  regenerate it after install/remove; our fleet boots from local NVMe.
- Secure Boot hosts need the DKMS MOK enrolled first (`bin/mok-enroll`).
- Ubuntu z-stream ABI bumps within a family (e.g. 6.17.0-35 → -41) keep
  building (family regex matches) against vendored files from the pinned
  ABI. `nvme.h` layout churn within a stable series is rare but not
  impossible — re-vendor on fleet kernel updates rather than trusting
  the family match blindly.

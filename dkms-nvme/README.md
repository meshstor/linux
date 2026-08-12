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

Beyond advertising P2P support, the backport also fixes how a failed P2P
transfer is *reported*: `ib_dma_map_sg()` folded every mapping error into a
bare zero, so an unroutable transfer surfaced as `-EIO` — a retryable
host-path error that multipath requeues forever. Patches 0002-0004 (upstream
v6 patches 9-11) switch to `ib_dma_map_sgtable_attrs()`, which preserves the
real errno, and translate `-EREMOTEIO` into the non-retryable
`BLK_STS_P2PDMA` (status 18, defined in `compat.h` since no shipped kernel
has it yet). The sibling `dkms/` package defines the same value and consumes
it directly — this status crosses the module boundary between the two
drivers, so the two definitions must never drift apart.

`compat.h` is therefore a **required top-level tarball file**, alongside
`Makefile`/`README.md`/`COPYING` — `bin/build-nvme-tarball` copies it to the
tarball root (not per-variant) because every variant's vendored `rdma.c`
`#include`s it from there. A future edit to that script's file list must not
drop it, or every variant fails to build with `rdma.c: fatal error:
compat.h: No such file or directory`.

## DEPLOYMENT HAZARD: pair only with an `ms` build that has `0012`

**Never install this package on a host whose `meshstor-ms` was built from a
tree where `dkms/patches/0012-p2pdma-blk-sts-compat.patch` was skipped.** That
combination loses writes silently, and neither package can detect it.

Because this package emits the **native** status 18, and `0012` is what
teaches `ms` to handle a status the host block layer does not know, an `ms`
built without `0012` does the following on a kernel whose `blk_errors[]` has a
zero-filled hole at index 18:

1. `raid1_should_handle_error()` passes status 18 through — it is neither
   `BLK_STS_INVAL` nor `BLK_STS_TARGET`, so nothing swallows it;
2. the ordinary write-error path runs and reaches `narrow_write_error()`;
3. `submit_bio_wait()` on the retry chunk returns
   `blk_status_to_errno(18)` = **0**;
4. the chunk is recorded as *written*, **no badblock is set**, and
5. the master write is acked to the application.

Data the application believes reached that member is not there, and md has no
record that anything went wrong. **Before this package was patched, that leg
returned a real errno and md's ordinary path fenced it correctly — so
patching `nvme-rdma` is what introduced this hazard** for any `ms` build
lacking `0012`.

The trap is that `0012` skipping is quiet: `bin/build-tarball` prints an
ordinary `Skipping 0012-p2pdma-blk-sts-compat.patch (guard not satisfied: ...)`
line, indistinguishable from the intended skip on a bare-upstream `master`
baseline. So deploy the two packages **together, from the same build**, and
before installing this one, confirm the `ms` tarball's build log says
*Applying* `0012-p2pdma-blk-sts-compat.patch`, not *Skipping*. A host carrying
only one of the two packages is safe: unpatched `nvme-rdma` never emits 18,
and `ms` with `0012` copes whether or not anything emits it.
(Mirror of the same warning in `dkms/patches/README.md`; keep the two in step.)

## HAZARD: a GDS/O_DIRECT writer on the RAW namespace, not through `ms`

On **Ubuntu with `nvme_core.multipath=N`**, this package's patched
`nvme-rdma` makes `/dev/nvmeXnY` itself advertise P2P and return status 18 on
an unroutable transfer. A GDS / `O_DIRECT` writer talking to that **raw block
device — not through an `ms` array —** gets `blk_status_to_errno(18)` = **0**
back from the blkdev direct-I/O completion. The write is reported
**successful and nothing is written**: silent data loss, outside md's
boundary, created by this package.

`ms` is not involved and cannot help: `0012`'s clamp and status checks live
inside md, and a raw-device writer never enters them. This is a supported-use
constraint on this package, not an md bug.

- **Unreachable on RHEL 10**, where an rdma namespace always gets a multipath
  head and the head gendisk never advertises P2P, so no P2P I/O is granted to
  the raw device in the first place.
- **Reachable on Ubuntu booted `nvme_core.multipath=N`**, which is exactly the
  configuration recommended for GDS-native on an rdma leg.
- The clean fix is the **host kernel carrying upstream v6 p1** ("block: add
  `BLK_STS_P2PDMA` …"), which puts a real errno at index 18 of `blk_errors[]`.
  Until then, on such a host, route GDS traffic through `/dev/msN` and treat
  raw `/dev/nvmeXnY` GDS writes as unsupported.

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

Each variant now carries **four** patches applied in order, not one:

| Patch | Upstream | Does |
|-------|----------|------|
| `0001-nvme-rdma-enable-pci-p2pdma.patch` | `23528aa3320a` (pre-v6, already upstream) | Advertise P2P support (`supports_pci_p2pdma` ctrl op) |
| `0002-nvme-rdma-use-ib_dma_map_sgtable_attrs.patch` | v6 p9 | Preserve the DMA mapping errno instead of folding it into a bare zero |
| `0003-nvme-rdma-return-BLK_STS_P2PDMA.patch` | v6 p10 | Translate `-EREMOTEIO` to `BLK_STS_P2PDMA`; adds `#include "compat.h"` |
| `0004-nvme-rdma-ratelimit-map-failure-message.patch` | v6 p11 | Ratelimit the per-request map-failure log line |

`bin/vendor-nvme-sources` exit 3 (files changed) means **re-checking all
four** patches for that variant, not just 0001 — a distro rebase can shift
context anywhere in `rdma.c`, including the regions 0002-0004 touch.

1. `bin/vendor-nvme-sources [--u2404 TAG] [--u2604 TAG] [--rhel10 NVR]`
   (defaults to latest; exit 3 = files changed).
2. For each variant `V` whose vendored `rdma.c` changed, regenerate that
   variant's patches, in order:

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

   Then regenerate 0002-0004 on top of the (possibly just-changed) 0001, by
   replaying the local patch stack and re-applying the three upstream v6
   patches (9, 10, 11 — the map-failure-reporting series; **skip v6 p12**, a
   pure refactor with no runtime effect) against a scratch copy, then
   re-diffing each step. The upstream patches live wherever the v6 series was
   staged for review (e.g. `build/p2pdma-upstream-aux/final-v2/v6/send/`):

   ```bash
   V6=/path/to/v6/send   # wherever v6-0009..v6-0011 are staged
   S="$(mktemp -d)"
   for V in rhel10 u2404-hwe u2604; do
       mkdir -p "$S/$V"; cp "dkms-nvme/vendor/$V/rdma.c" "$S/$V/"
       patch -p1 --fuzz=0 -d "$S/$V" \
           < "dkms-nvme/patches/$V/0001-nvme-rdma-enable-pci-p2pdma.patch"
       for p in "$V6"/v6-0009*.patch "$V6"/v6-0010*.patch "$V6"/v6-0011*.patch; do
           cp "$S/$V/rdma.c" "$S/$V/rdma.c.orig"
           patch -p4 --fuzz=0 -d "$S/$V" < "$p"    # -p4: a/drivers/nvme/host/rdma.c -> rdma.c
           # patch 10 (-> our 0003) additionally needs:
           #   #include "compat.h"   added after the system includes, alongside
           #   the other quoted local headers ("nvme.h" / "fabrics.h") — do this
           #   by hand on $S/$V/rdma.c before diffing that step.
           diff -u --label a/rdma.c --label b/rdma.c \
               "$S/$V/rdma.c.orig" "$S/$V/rdma.c"
           # prepend a description block (see the existing 000{2,3,4} patches
           # for the convention), then save as the next NNNN- file for $V.
       done
   done
   ```

   Verify **all four** patches for every changed variant apply clean and
   together still produce a working driver:

   ```bash
   bash tools/testing/selftests/dkms/test_nvme_tarball_assembles.sh
   bash tools/testing/selftests/dkms/test_nvme_build_smoke.sh
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

# GDS L40S window runbook (p2pdma campaign)

Design: `docs/superpowers/specs/2026-07-01-gds-l40s-p2pdma-campaign-design.md`
(local archive). Everything below assumes the kit was built and rehearsed
(`bin/gds-make-kit <ver>`, `bin/gds-campaign --rehearsal`) BEFORE the window.

## Before the window (dev machine)
1. `bin/gds-make-kit 0.1.0` → `build/gds-kit-0.1.0.tar.gz` (featured + baseline
   tarballs verified to build against 6.17 here).
2. `sudo bin/gds-campaign --rehearsal` → every phase green or SKIP with a
   GPU-only reason. Fix anything else before travel.
3. `scp build/gds-kit-0.1.0.tar.gz l40s:/opt/`

## On the box (few-hours window — order matters)
1. `tar xzf /opt/gds-kit-0.1.0.tar.gz -C /opt && cd /opt/gds-kit-0.1.0`
2. `sudo ./install.sh`  (dkms featured + modprobe + udev rule; needs kernel
   headers, dkms, bpftrace, nvme-cli, fio preinstalled — install via distro if
   missing BEFORE anything else)
3. Test partitions: `sudo bin/perf-make-test-partitions /dev/nvmeXnY` (pick a
   4K-LBA NVMe with trailing free space; run on a second drive too if you want
   the raid10 fabric case — 4 partitions total).
4. `sudo MDADM=$PWD/bin/mdadm-ms GDS_KIT_DIR=$PWD bin/gds-campaign --results /root/gds-results`
   - **Note — p6 needs its own invocation.** A full unattended p0..p6 run in
     one shot will SKIP p6 (divergence): p4's hot-add-clear traffic triggers
     mdadm's udev incremental-assembly, which reloads the **in-tree** `raid1`
     module (kprobe symbol ambiguity — `inval-inject`'s `register_kprobe()`
     can silently bind to the in-tree module's copy of the symbol instead of
     `raid1_ms`'s, and never fires). To actually exercise p6:
     - preferred: run it as a **separate invocation** after the rest of the
       campaign is on disk — stop any in-tree md array, then
       `sudo modprobe -r raid1 raid10` to clear the in-tree copies, then
       `sudo MDADM=$PWD/bin/mdadm-ms GDS_KIT_DIR=$PWD bin/gds-campaign --phases p6`; or
     - alternative: front-load it with `--phases p0,p6` before any of the
       md-superblock-creating phases (p3 onward) run.
     Running p6 on its own is the recommended order — don't rely on it
     surviving inside the same invocation as p4.
5. Watch `column -t -s $'\t' /root/gds-results/*/verdict.tsv`. The campaign
   continues past failures; it stops only if the node heartbeat dies.
   - **Caveat — `merge_control` FAIL on `none` scheduler.** The Layer-B
     non-P2P regression suite (`test_nonp2p_merge_control.sh`, run under p4)
     FAILs on any host whose NVMe uses the `none` I/O scheduler — there are no
     observable request merges to assert on, confirmed even on a raw device
     with no md involved at all. This is **not** a p2pdma regression. Before
     treating a merge_control result on the L40S as a real finding, check
     `cat /sys/block/<dev>/queue/scheduler`; a FAIL while it reads `none` is
     expected and should not block the rest of the campaign.
6. OPTIONAL manual P5 GDS step (only after p0–p4 are on disk): with the
   baseline installed by p5, mkfs+mount the tcp-leg array, then
   `bin/gds-p2p-witness -o /root/p5-witness.txt -- gdsio -f /mnt/.../f -d 0 -w 4 -s 256M -i 1M -x 0 -I 1`
   and save dmesg. This is the crash-riskiest step of the window.
7. `sudo bin/probe-cufile-recognition /mnt/<ms-array-mountpoint>` on a mounted
   ms array (P2's array works) — cuFile RAID-classification verdict.

## Copy off the box (BEFORE the window ends)
`tar czf gds-evidence.tgz /root/gds-results && scp` — plus `/var/log/kern.log`
if anything crashed.

## Abort criteria
- Node wedged (heartbeat failure, D-state kthreads): copy results out, reboot,
  re-run remaining phases with `--phases pN,...`.
- P1 FAIL: stop the md phases; run `gdscheck -p`, check `nvidia-smi topo -m`
  for the GPU↔NVMe path, IOMMU/ACS state (p0 evidence) — the box cannot do
  native GDS; collect the diagnosis bundle and use the remaining time on
  P4/P6 (GPU-independent).
- p6 SKIP right after a combined p0..p6 run is **not** an abort condition —
  it means p4 reloaded the in-tree `raid1` module out from under the kprobe
  (see the on-box step 4 note above); rerun p6 standalone once the rest of
  the evidence is safely on disk.

## What each phase proves
See the spec §4 table. TL;DR: p1 = box does native GDS; p2 = headline
(GDS-native on ms raid1, kernel-witnessed, legs identical); p3 = CSI fabric
topology + Finding-E rdma answer; p4 = member-AND + hot-add-clear + Layer-B
regressions; p5 = upstream baseline falsely advertises (justifies the fork's
member-AND); p6 = BLK_STS_INVAL silent divergence reproduced (follow-up
evidence).

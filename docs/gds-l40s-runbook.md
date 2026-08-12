# GDS L40S window runbook (p2pdma campaign)

Copy-paste procedure for the few-hours hardware window. Deep context, expected
results per phase, and the full debugging playbook live in
`docs/gds-l40s-agent-briefing.md` — hand that file to an assisting model.
Every block below is paste-able as-is; run everything **from the kit root**
(`cd /opt/gds-kit-0.1.0`) as a sudo-capable user.

## Before the window (dev machine)

```bash
bin/gds-make-kit 0.1.0                       # -> build/gds-kit-0.1.0.tar.gz
sudo bin/gds-campaign --rehearsal            # every row PASS or SKIP-with-GPU-only-reason
scp build/gds-kit-0.1.0.tar.gz l40s:/opt/
```

## On the box — step 0: sanity gates (do these FIRST; each can kill the window)

```bash
mokutil --sb-state                            # want: SecureBoot disabled
grep CONFIG_PCI_P2PDMA "/boot/config-$(uname -r)"   # want: =y  (else native P2P impossible — stop)
grep CONFIG_DEBUG_INFO_BTF "/boot/config-$(uname -r)"  # want: =y (bpftrace tools are BTF-only)
uname -r                                      # want: >= 6.11 (6.17-class expected)
modinfo -F license nvidia                     # want: GPL/MIT (OpenRM open module; proprietary = no native P2P)
command -v bpftrace nvme fio gdsio gdscheck   # all must resolve (gds tools: CUDA 12.8+ package)
nvidia-smi topo -m                            # note which GPU has PIX/PXB (not SYS) to the test NVMe
```

- Secure Boot **enabled** → enroll the DKMS MOK + reboot (`mokutil --import
  /var/lib/dkms/mok.pub`, or `bin/mok-enroll` from a git checkout), or disable SB.
- Missing distro tools: `sudo apt install -y dkms "linux-headers-$(uname -r)" bpftrace nvme-cli fio`.

## Step 1: install + partitions

```bash
tar xzf /opt/gds-kit-0.1.0.tar.gz -C /opt && cd /opt/gds-kit-0.1.0
sudo ./install.sh                             # dkms featured variant + modprobe + udev rule
grep Personalities /proc/msstat               # want: [raid1] [raid10]
sudo bin/perf-make-test-partitions /dev/nvmeXnY    # 4K-LBA NVMe with trailing free space
ls /dev/disk/by-partlabel/*-meshstor-test-*   # want: >=2 labels (4, across two drives, for raid10 fabric)
```

## Step 2: verify gdsio's interface (the wrappers were written from docs, never run on a GPU box)

```bash
gdsio -h    # cross-check: -x 0 = GDS, -x 1 = POSIX/CPU, -I 1 write / 0 read, -V verify, -d = GPU index
```

If the installed gdsio's mode numbering or verify flag differs, fix ONLY
`gds_gdsio_write` / `gds_gdsio_readverify` in `selftests/p2pdma/gds/lib.sh`, then
re-run `bash selftests/p2pdma/gds/test_unit_helpers.sh` (want `PASS: unit helpers`).
Pick the `-d` GPU index with the tightest PCIe path to the NVMe (step 0's topo output).

## Step 3: the main run (p0–p5; p6 runs separately — see step 5)

```bash
sudo MDADM=$PWD/bin/mdadm-ms GDS_KIT_DIR=$PWD bin/gds-campaign \
     --phases p0,p1,p2,p3,p4,p5 --results /root/gds-results
column -t -s $'\t' /root/gds-results/verdict.tsv 2>/dev/null || cat /root/gds-results/verdict.tsv
```

The campaign continues past failures; it stops only on a node-heartbeat wedge
(exit 3). Read `verdict.tsv`, not just the exit code. Two **expected** oddities:

- **`merge_control` FAIL when the NVMe scheduler is `none`.** No observable
  request merges exist even on a raw device (confirmed with no md involved).
  Check `cat /sys/block/<dev>/queue/scheduler`; a FAIL while it reads `none`
  is environment noise, not a p2pdma regression.
- **p5 restore check:** after p5, confirm the featured package is back —
  `dkms status | grep meshstor` must show `*.gds1`. If the campaign aborted
  with exit 3 during p5, the box is on the BASELINE module: rerun
  `sudo ./install.sh` before anything else.

## Step 4: cuFile RAID-classification probe (needs a mounted ms array — the tests stop theirs)

```bash
M0=$(ls /dev/disk/by-partlabel/*-meshstor-test-* | sed -n 1p)
M1=$(ls /dev/disk/by-partlabel/*-meshstor-test-* | sed -n 2p)
sudo $PWD/bin/mdadm-ms --create /dev/ms0 --level=1 --raid-devices=2 --metadata=1.2 \
     --homehost=any --assume-clean --bitmap=internal --bitmap-chunk=128M \
     --consistency-policy=bitmap --failfast --run "$M0" "$M1"
sudo mkfs.xfs -f -q /dev/ms0 && sudo mkdir -p /mnt/ms0 && sudo mount /dev/ms0 /mnt/ms0
sudo MSADM=$PWD/bin/mdadm-ms bin/probe-cufile-recognition /mnt/ms0 |& tee /root/gds-results/cufile-recognition.txt
sudo umount /mnt/ms0 && sudo $PWD/bin/mdadm-ms --stop /dev/ms0
```

Exit 0 = cuFile takes real GDS on `/dev/ms0`. Exit 1 = compat fallback — the
kernel side may still be perfect (the witness proves that); the failure is
cuFile's userspace classification of the `ms` naming. See briefing §4.6.

## Step 5: p6 divergence repro — its OWN invocation (p4 traffic makes udev reload in-tree raid1, which steals the kprobe symbol and p6 SKIPs)

```bash
cat /proc/mdstat                              # stop any in-tree /dev/mdN with the SYSTEM mdadm first
sudo modprobe -r raid1 raid10                 # clear the in-tree copies
sudo MDADM=$PWD/bin/mdadm-ms GDS_KIT_DIR=$PWD bin/gds-campaign --phases p6 --results /root/gds-results
```

Want: `p6 divergence PASS ... injected=N` — PASS means the known bug reproduced
(write reported success while a leg went silently stale). A p6 SKIP right after
a combined run is not an abort — rerun standalone as above.

## Step 6 (OPTIONAL, crash-riskiest — only after all evidence above is off-box): strict GDS write against the falsely-advertising BASELINE array

```bash
# swap to baseline
TB=$(ls $PWD/tarballs/*gds0*.dkms.tar.gz); TMP=$(mktemp -d); tar xzf "$TB" -C "$TMP"
VER=$(ls "$TMP" | sed 's/^meshstor-ms-//'); sudo cp -r "$TMP/meshstor-ms-$VER" /usr/src/
sudo modprobe -r raid10_ms raid1_ms ms_mod
sudo dkms remove meshstor-ms/0.1.0.gds1 --all; sudo dkms add "meshstor-ms/$VER" && sudo dkms install "meshstor-ms/$VER"
sudo modprobe ms_mod && sudo modprobe raid1_ms && sudo modprobe raid10_ms
# local + loopback-tcp array (the shape baseline FALSELY advertises)
M0=$(ls /dev/disk/by-partlabel/*-meshstor-test-* | sed -n 1p)
M1=$(ls /dev/disk/by-partlabel/*-meshstor-test-* | sed -n 2p)
sudo modprobe nvmet nvmet-tcp nvme-fabrics nvme-tcp
NQN="nqn.2025-12.io.meshstor:tcp:gdstest:$(hostname -s)"
SS=/sys/kernel/config/nvmet/subsystems/$NQN; PT=/sys/kernel/config/nvmet/ports/7431
sudo mkdir -p "$SS/namespaces/1" "$PT"
echo 1 | sudo tee "$SS/attr_allow_any_host" >/dev/null
echo -n "$M1" | sudo tee "$SS/namespaces/1/device_path" >/dev/null
echo 1 | sudo tee "$SS/namespaces/1/enable" >/dev/null
echo tcp | sudo tee "$PT/addr_trtype" >/dev/null; echo ipv4 | sudo tee "$PT/addr_adrfam" >/dev/null
echo 127.0.0.1 | sudo tee "$PT/addr_traddr" >/dev/null; echo 4420 | sudo tee "$PT/addr_trsvcid" >/dev/null
sudo ln -s "$SS" "$PT/subsystems/$NQN"
sudo nvme connect -t tcp -a 127.0.0.1 -s 4420 -n "$NQN" --nr-io-queues=16 \
     --keep-alive-tmo=1 --ctrl-loss-tmo=3 --reconnect-delay=1
sleep 2; REMOTE=""
for c in /sys/class/nvme/nvme*; do [ "$(cat "$c/subsysnqn" 2>/dev/null)" = "$NQN" ] \
     && REMOTE=/dev/$(ls "$c" | grep -m1 '^nvme[0-9]*n[0-9]*$'); done; echo "REMOTE=$REMOTE"
sudo $PWD/bin/mdadm-ms --create /dev/ms0 --level=1 --raid-devices=2 --metadata=1.2 \
     --homehost=any --assume-clean --bitmap=internal --bitmap-chunk=128M \
     --consistency-policy=bitmap --failfast --run "$M0" "$REMOTE"
sudo bin/ms-queue-features /dev/ms0        # want: ADVERTISED (that's the baseline bug being shown)
sudo mkfs.xfs -f -q /dev/ms0 && sudo mkdir -p /mnt/ms0 && sudo mount /dev/ms0 /mnt/ms0
# strict cufile + witnessed write
cat > /tmp/cufile-strict.json <<'JSON'
{ "logging": { "dir": "/tmp", "level": "TRACE" },
  "properties": { "use_pci_p2pdma": true, "allow_compat_mode": false },
  "fs": { "generic": { "posix_unaligned_writes": false },
          "block": { "nvme": {"use_pci_p2pdma": true}, "nvmeof": {"use_pci_p2pdma": true}, "raid": {"use_pci_p2pdma": true} } } }
JSON
sudo dmesg > /root/dmesg-before-p5manual.txt
sudo CUFILE_ENV_PATH_JSON=/tmp/cufile-strict.json bin/gds-p2p-witness -o /root/p5-witness.txt -- \
     gdsio -f /mnt/ms0/p5probe.bin -d 0 -w 4 -s 256M -i 1M -x 0 -I 1 |& tee /root/p5-manual.txt
sudo dmesg > /root/dmesg-after-p5manual.txt
# teardown + RESTORE FEATURED before anything else runs
sudo umount /mnt/ms0; sudo $PWD/bin/mdadm-ms --stop /dev/ms0
sudo nvme disconnect -n "$NQN"; sudo rm -f "$PT/subsystems/$NQN"; sudo rmdir "$PT"
echo 0 | sudo tee "$SS/namespaces/1/enable" >/dev/null; sudo rmdir "$SS/namespaces/1" "$SS"
sudo ./install.sh && dkms status | grep gds1
```

Whatever happens (INVAL errors, works-but-slow, oops) **is** the finding — save
it verbatim. Never leave the box on baseline.

## Copy off the box (BEFORE the window ends)

```bash
tar czf /root/gds-evidence.tgz /root/gds-results /root/p5-*.txt /root/dmesg-*.txt 2>/dev/null
scp /root/gds-evidence.tgz <you>@<devbox>:/tmp/    # plus /var/log/kern.log if anything crashed
```

## Abort criteria

- **Node wedged** (heartbeat exit 3, D-state kthreads): copy evidence out,
  reboot, resume with `--phases pN,...`.
- **P1 FAIL** (box can't do native GDS at all): stop the GDS phases; save
  `gdscheck -p`, `nvidia-smi topo -m`, IOMMU/ACS state (p0 evidence) as the
  diagnosis bundle; spend the remaining time on P4/P6 (GPU-independent).

## What each phase proves

p1 = box does native GDS (witness-calibrated); p2 = **headline** — GDS-native on
ms raid1, kernel-witnessed, both legs identical; p3 = CSI fabric topology +
whether an nvme-rdma leg advertises P2P (new empirical data); p4 = member-AND +
hot-add-clear + Layer-B non-P2P regressions; p5 = upstream-baseline falsely
advertises with a tcp leg (justifies the fork's member-AND); p6 = BLK_STS_INVAL
silent divergence reproduced (evidence for the fail-the-write follow-up);
step 4's probe = cuFile actually classifies `/dev/msN` as RAID and takes the
real P2P path (the kernel flag alone is necessary, not sufficient).

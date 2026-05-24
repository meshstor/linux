# meshstor-ms documentation

`meshstor-ms` is a parallel `ms_*` MD subsystem shipped as a DKMS
package. It coexists with the kernel's built-in `md_mod` rather than
replacing it: our modules, symbols, devices, and sysfs paths all use
distinct names. Customers run kernel-md and meshstor-ms arrays on the
same host concurrently without collision.

The package delivers selected upstream md performance work — the
lockless bitmap (llbitmap), per-rdev latency-aware read balancing
(EWMA), per-bucket barrier arrays for raid10, and zero-copy
raid1→raid10 takeover — on kernels that don't yet have them in
released builds.

## If you are a customer

Reading order:

- [install.md](install.md) — how to install the rpm/deb on RHEL 9.x,
  RHEL 10.x, Ubuntu 24.04 LTS HWE, or Ubuntu 26.04 LTS, including
  Secure Boot and MOK enrollment.
- [admin.md](admin.md) — how to operate the modules and arrays
  day-to-day, including bitmap selection, takeover, and troubleshooting.
- [compat.md](compat.md) — confirm your distro/kernel is supported
  and check for per-kernel caveats.

## If you are operating arrays

- [admin.md](admin.md) — runbook covering `/proc/msstat`, sysfs
  inspection, latency-EWMA reading, raid1↔raid10 takeover,
  coexistence with kernel md, and the four most common failure modes.
- [performance.md](performance.md) — measured perf characteristics
  with guidance on when llbitmap is a win.

## If you are maintaining the project

- [architecture.md](architecture.md) — design vocabulary used by
  every other doc (parallel subsystem, rename pass, on-disk
  compatibility model).
- [maintainer.md](maintainer.md) — upstream-rebase workflow,
  compat-shim authoring, feature-flag detection, and the two
  non-obvious gotchas (KBUILD_EXTMOD, sysctl-sentinel) already
  costing engineering time.
- [build.md](build.md) — release engineering: tarball pipeline,
  rpm/deb packaging, signing infrastructure, release flow.

## Document set

| File | Topic | Audience |
|---|---|---|
| [install.md](install.md) | End-user install | Customer |
| [admin.md](admin.md) | Operator runbook | Operator |
| [compat.md](compat.md) | Distro × kernel matrix | Reference |
| [architecture.md](architecture.md) | Parallel-subsystem design | Maintainer |
| [build.md](build.md) | Release engineering | Maintainer |
| [maintainer.md](maintainer.md) | Rebase + shim authoring | Maintainer |
| [performance.md](performance.md) | Perf characteristics + benchmarks | Operator/Maintainer |
| [index.md](index.md) | This page | All |

# meshstor-md compat patches

Patches in this directory are applied (in glob-sorted order) by
`dkms/scripts/build-tarball.sh` to the unpacked DKMS source tree
*after* copying from `drivers/md/` and *before* the `tar czf` step.

## When to use a patch vs `dkms/compat/compat.h`

Use **compat.h** when the upstream change can be papered over by
defining a missing symbol, macro, or inline. Most API renames and
new helper functions fit this.

Use a **patch** when the upstream change touches code structure in
a way no header trick can cover:
- Struct field added that doesn't exist on older kernels (can't add
  fields to kernel-owned structs)
- Function signature changed in a way that affects callbacks/tables
- Source-level syntax that needs version-conditional compilation

## Patch conventions

- Filename: `NNNN-short-description.patch` where NNNN is a 4-digit
  ordering prefix (`0001`, `0002`, ...).
- Format: standard unified diff with `-p1` paths (i.e. `a/raid5.c`,
  `b/raid5.c` — the tarball-flat layout, not `drivers/md/`).
- Each patch should bracket its changes in `#if LINUX_VERSION_CODE`
  so the same tarball builds against both old and new kernels with
  identical behavior on new ones.
- One patch per logical compat issue. Don't bundle.

## Listing

| Patch | What it fixes | Why a patch (not compat.h) |
|---|---|---|
| `0001-md-getgeo-pre-6.14-signature.patch` | `block_device_operations.getgeo` callback signature changed | We need a wrapper function and a conditional `.getgeo =` assignment |
| `0002-raid5-pre-6.18-no-wzeroes-unmap-field.patch` | `struct queue_limits.max_hw_wzeroes_unmap_sectors` doesn't exist on older kernels | Can't add fields to kernel-owned struct; must `#ifdef` the assignment |

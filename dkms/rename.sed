# meshstor md_*-to-ms_* rename pass
# Applied to every .c and .h in the DKMS tarball after kernel-API compat
# patches but before tarball compression. See dkms/patches/README.md for the
# pre-rename patch step.
#
# WHAT IS RENAMED
#   md_<lower>      -> ms_<lower>          (function/var prefix at identifier boundary)
#   mddev*          -> mssev*              (struct name and identifiers using it as prefix)
#   MD_<upper>      -> MS_<upper>          (most macros)
#   "md_mod"        -> "ms_mod"            (string literal — module name)
#   "mdstat"        -> "msstat"            (string literal — proc filename)
#   "md: "          -> "ms: "              (log-line prefix)
#   #include "md*.h"-> #include "ms*.h"    (local-include filenames after file rename)
#
# WHAT IS PRESERVED (NOT renamed)
#   <linux/raid/md_p.h>, <linux/raid/md_u.h>   kernel-provided UAPI header paths
#   MD_SB_*, MD_FEATURE_*, MD_DISK_*           on-disk superblock format constants
#   MD_RESYNC_*, MD_RECOVERY_*                 on-disk / recovery state values
#   MD_BITMAP_BIT_*, MD_DEFAULT_BITMAP_*       on-disk bitmap layout values
#
# Renaming the preserved list would change either a kernel-header path
# (preventing the file from being found at compile time) or the compiled
# value of an on-disk-format constant (breaking the bit-for-bit superblock
# compatibility guarantee with kernel md per spec §4.2).

# === Step 0: protect kernel UAPI header paths ===
# Run BEFORE any md_*->ms_* substitution; the placeholder tokens contain no
# "md_" or "MD_" substring so subsequent rules cannot rewrite them.
s|<linux/raid/md_p\.h>|<__KEEP_INC_RAID_P__>|g
s|<linux/raid/md_u\.h>|<__KEEP_INC_RAID_U__>|g

# === Step 0b: protect kernel UAPI struct fields and helpers (DYNAMIC) ===
# Lowercase md_* identifiers from <linux/raid/md_p.h> and <linux/raid/md_u.h>:
# struct field names (md_magic, md_minor) and helper functions (md_event).
# build-tarball.sh prepends auto-generated rules here from a similar grep.

# === Step 1: protect kernel UAPI names from rename (DYNAMIC) ===
# build-tarball.sh prepends auto-generated rules at this position by reading
# /lib/modules/$(uname -r)/build/include/uapi/linux/raid/{md_p,md_u}.h and
# emitting a `s/\bNAME\b/__KEEP_NAME/g` line for every MD_*/md_* identifier
# defined there. This file (rename.sed) intentionally contains no UAPI
# enumeration — that would require constant maintenance as kernel headers
# add new symbols. The build-time generation makes it self-updating.
#
# See dkms/scripts/build-tarball.sh near the rename pass for the generator.
#
# Static keep entries that aren't auto-extractable from headers go here:
#   MD_MAJOR — defined in <linux/major.h>, not the raid/ headers

# === Step 2: lowercase symbol prefix md_<lower> -> ms_<lower> ===
# Catches function names, variable names, and macro names like md_personality,
# register_md_personality, md_mod_init, etc.
s/\bmd_/ms_/g

# === Step 3: mddev -> mssev (no trailing word-boundary) ===
# Catches "mddev" standalone, "mddev_detach", "mddev_create_serial_pool", etc.
s/\bmddev/mssev/g

# === Step 4: global MD_* uppercase macro/enum prefix rename ===
s/\bMD_/MS_/g

# === Step 5: restore the protected names ===
s/\b__KEEP_MD_/MD_/g
s/\b__KEEP_md_/md_/g
s|<__KEEP_INC_RAID_P__>|<linux/raid/md_p.h>|g
s|<__KEEP_INC_RAID_U__>|<linux/raid/md_u.h>|g

# === Step 6: rename local-include strings to match renamed header files ===
# build-tarball.sh renames md.h -> ms.h, md-bitmap.h -> ms-bitmap.h, etc.
# Update #include "md*.h" lines to match the new on-disk filenames.
s|"md\.h"|"ms.h"|g
s|"md-bitmap\.h"|"ms-bitmap.h"|g
s|"md-cluster\.h"|"ms-cluster.h"|g
s|"raid1\.h"|"raid1_ms.h"|g
s|"raid10\.h"|"raid10_ms.h"|g
s|"raid1-10\.c"|"raid1-10_ms.c"|g

# === Step 7: string literals ===
# Module names referenced in strings (e.g. MODULE_ALIAS, request_module).
s/"md_mod"/"ms_mod"/g
s/"md-mod"/"ms-mod"/g

# /proc filenames and the block-class name.
s/"mdstat"/"msstat"/g
s/"md_d"/"ms_d"/g

# Log-line prefix in pr_* / printk.
s/"md: /"ms: /g
s/"md\/%s/"ms\/%s/g
s/"md\/%/"ms\/%/g

# === Step 8: parallel-subsystem semantics (block-device registration) ===
# Kernel md uses MD_MAJOR=9 for "md" and a dynamic major (mdp_major) for "mdp".
# Our ms subsystem uses dynamic majors for both, with names "ms" and "msp".
# Add a static `ms_major` variable as a sibling of mdp_major, rename mdp_major
# to msp_major, and rewrite the register_blkdev / unregister_blkdev call sites.

# Insert `int ms_major;` definition near the top of ms.c, before its first use
# at file scope. Non-static so other TUs in the module (ms-autodetect.c, etc.)
# can reference it via the extern declaration in ms.h (added by build-tarball.sh
# step 5b after the rename).
# Anchor on the first existing `static const char` line.
s|^static const char \*action_name|int ms_major;\
static const char *action_name|

# Convert the existing `int mdp_major = 0;` definition to msp_major (variable
# rename — kernel md uses mdp_major for the partitioned-array dynamic major;
# we use msp_major for the same purpose in our subsystem).
s/\bmdp_major\b/msp_major/g

# Rewrite the two registration call sites in ms_init.
s|ret = __register_blkdev(MD_MAJOR, "md", ms_probe);|ms_major = __register_blkdev(0, "ms", ms_probe); ret = ms_major;|
s|ret = __register_blkdev(0, "mdp", ms_probe);|msp_major = __register_blkdev(0, "msp", ms_probe); ret = msp_major;|

# Rewrite all unregister_blkdev call sites.
s|unregister_blkdev(MD_MAJOR, "md")|unregister_blkdev(ms_major, "ms")|g
s|unregister_blkdev(MD_MAJOR,"md")|unregister_blkdev(ms_major, "ms")|g
s|unregister_blkdev(msp_major, "mdp")|unregister_blkdev(msp_major, "msp")|g

# Replace remaining MD_MAJOR references (MKDEV, MAJOR comparisons) with ms_major.
# At runtime ms_major is set during ms_init() before any of these are reached.
s/\bMD_MAJOR\b/ms_major/g

# === Step 9: rename non-md_-prefixed exports that collide with vmlinux md ===
# Kernel md exports a few functions that don't follow the md_* convention,
# OR have md_ embedded mid-identifier (where \bmd_ doesn't match the start).
# Our renamed source would still export them with the original names,
# colliding with the in-vmlinux versions. Rename explicitly.
s/\brdev_set_badblocks\b/ms_rdev_set_badblocks/g
s/\brdev_clear_badblocks\b/ms_rdev_clear_badblocks/g
s/\bsync_page_io\b/ms_sync_page_io/g
s/\bregister_md_submodule\b/register_ms_submodule/g
s/\bunregister_md_submodule\b/unregister_ms_submodule/g

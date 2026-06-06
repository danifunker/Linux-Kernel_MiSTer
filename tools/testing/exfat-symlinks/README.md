# exFAT symlink test harness

Validates the MiSTer exFAT symlink support — mainline exFAT plus
SYSTEM-attribute symbolic links (the "Option B" approach) — entirely on a
Linux host with QEMU. **No DE10-Nano hardware is required**: exFAT is
hardware-independent, so the filesystem logic is what gets tested.

## What is being tested

A symbolic link on exFAT is stored as an ordinary file flagged with the
standard **SYSTEM** attribute (0x04), whose body is the target path. Using the
*standard* attribute is what lets a link survive being copied on Windows/macOS
(normal copy tools preserve it). The harness proves:

| Check | Proves |
|-------|--------|
| `ln -s` then `readlink` (relative + absolute) | links are created and resolved |
| `cat` through a link to a real file | resolution actually follows the target |
| on-disk `rlink`/`dlink` carry the SYSTEM bit (`exfat_attr.py`) | correct on-disk format / Windows-copy survival |
| a plain file does **not** become a link | no false positives |
| flip SYSTEM on a hand-made file, remount, `readlink` works | **backward compatibility** with legacy / Windows-made links |
| values survive unmount + remount | persistence |

The `exfat_attr.py` helper parses (and minimally edits) the raw image without
using the kernel driver, so the on-disk format is checked independently. When
it sets the SYSTEM bit it also recomputes the exFAT entry-set checksum, exactly
as a real Windows-made entry would have.

## Prerequisites (Debian/Ubuntu names)

```
build-essential flex bison bc libelf-dev libssl-dev xz-utils cpio \
qemu-system-x86 exfatprogs python3 curl
```

## Usage

```
./run.sh            # full run (downloads linux-5.15, builds it, runs QEMU x2)
KEEP=1 ./run.sh     # reuse a previous kernel build (fast iteration)
JOBS=8 ./run.sh     # override parallelism
```

The first run downloads the linux-5.15 tarball and a static busybox, and builds
a kernel — expect several minutes. KVM is used automatically if `/dev/kvm` is
writable. Artifacts and logs land in `.work/` (phase1.log, phase2.log).

A successful run ends with `ALL TESTS PASSED`.

## Files

- `run.sh` — orchestrator (fetch/build/boot/verify)
- `vm-init.sh` — PID 1 in the VM; runs one test phase against `/dev/sda`
- `exfat_attr.py` — host-side exFAT directory walker (verify + fabricate)

## Notes

- Only `fs/exfat/` from this repo is overlaid onto a pristine 5.15 tree, so the
  driver is tested in isolation from the rest of the MiSTer changes.
- exFAT is built **in** (`CONFIG_EXFAT_FS=y`) so the initramfs can mount it.

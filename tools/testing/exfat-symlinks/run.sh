#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Turnkey test for the MiSTer exFAT symlink support (Option B: mainline exFAT
# + SYSTEM-attribute symlinks).  Runs entirely on a Linux host with QEMU; no
# DE10-Nano hardware is needed because exFAT is hardware-independent.
#
# What it does:
#   1. fetches a pristine linux-5.15 source tree
#   2. overlays THIS repo's fs/exfat/ (the patched driver) on top of it
#   3. builds a bzImage with exFAT built in
#   4. builds a tiny busybox initramfs containing vm-init.sh as /init
#   5. boots QEMU (phase 1) to create symlinks on an exFAT image
#   6. on the host, verifies the on-disk SYSTEM-bit format and fabricates a
#      "legacy"/Windows-made link (exfat_attr.py)
#   7. boots QEMU (phase 2) to confirm the driver reads everything back,
#      including the fabricated legacy link (backward compatibility)
#
# Prereqs (Debian/Ubuntu names): build-essential flex bison bc libelf-dev
#   libssl-dev xz-utils cpio qemu-system-x86 exfatprogs python3 curl
#
# Usage:  ./run.sh           # full run
#         KEEP=1 ./run.sh    # reuse an existing kernel build
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WORK="${WORK:-$SCRIPT_DIR/.work}"
JOBS="${JOBS:-$(nproc)}"
KVER="${KVER:-5.15}"
KSRC="$WORK/linux-$KVER"
BUSYBOX_URL="${BUSYBOX_URL:-https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox}"
IMG="$WORK/test.img"
LOG1="$WORK/phase1.log"
LOG2="$WORK/phase2.log"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
step()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

need() { command -v "$1" >/dev/null 2>&1 || { red "missing prerequisite: $1"; MISSING=1; }; }

step "checking prerequisites"
MISSING=0
for t in gcc make flex bison bc xz cpio qemu-system-x86_64 mkfs.exfat python3 curl ld; do need "$t"; done
# libelf/ssl headers are checked implicitly by the kernel build.
[ "$MISSING" = 0 ] || { red "install the missing tools and re-run"; exit 1; }
green "all prerequisites present"

mkdir -p "$WORK"

step "fetching linux-$KVER source"
if [ ! -d "$KSRC" ]; then
	tarball="$WORK/linux-$KVER.tar.xz"
	[ -f "$tarball" ] || curl -fL --retry 3 -o "$tarball" \
		"https://cdn.kernel.org/pub/linux/kernel/v5.x/linux-$KVER.tar.xz"
	tar -C "$WORK" -xf "$tarball"
fi

step "overlaying patched fs/exfat from $REPO"
cp -f "$REPO"/fs/exfat/* "$KSRC"/fs/exfat/

if [ "${KEEP:-0}" != 1 ] || [ ! -f "$KSRC/arch/x86/boot/bzImage" ]; then
	step "configuring kernel"
	make -C "$KSRC" defconfig >/dev/null
	"$KSRC"/scripts/config --file "$KSRC/.config" \
		-e EXFAT_FS \
		-e NLS -e NLS_UTF8 \
		-e BLK_DEV_INITRD -e DEVTMPFS -e DEVTMPFS_MOUNT \
		-e SCSI -e BLK_DEV_SD -e ATA -e ATA_PIIX \
		-e SERIAL_8250 -e SERIAL_8250_CONSOLE
	# exFAT must be built-in (=y), not a module, so the initramfs can mount it.
	"$KSRC"/scripts/config --file "$KSRC/.config" --set-val EXFAT_FS y
	make -C "$KSRC" olddefconfig >/dev/null
	grep -q '^CONFIG_EXFAT_FS=y' "$KSRC/.config" || { red "EXFAT_FS not built-in"; exit 1; }

	step "building kernel (-j$JOBS, this is the slow part)"
	make -C "$KSRC" -j"$JOBS" bzImage
else
	step "reusing existing kernel build (KEEP=1)"
fi

step "building busybox initramfs"
ID="$WORK/initramfs.d"
rm -rf "$ID"; mkdir -p "$ID"/{bin,proc,sys,dev,mnt}
[ -f "$WORK/busybox" ] || curl -fL --retry 3 -o "$WORK/busybox" "$BUSYBOX_URL"
chmod +x "$WORK/busybox"
cp "$WORK/busybox" "$ID/bin/busybox"
cp "$SCRIPT_DIR/vm-init.sh" "$ID/init"
chmod +x "$ID/init"
( cd "$ID" && find . | cpio -o -H newc 2>/dev/null | gzip ) > "$WORK/initramfs.cpio.gz"

step "creating exFAT image"
rm -f "$IMG"
truncate -s 64M "$IMG"
mkfs.exfat "$IMG" >/dev/null

QEMU_ACCEL=()
[ -w /dev/kvm ] && QEMU_ACCEL=(-enable-kvm -cpu host)

run_vm() { # run_vm <phase> <logfile>
	timeout 600 qemu-system-x86_64 "${QEMU_ACCEL[@]}" -nographic -no-reboot -m 512 \
		-kernel "$KSRC/arch/x86/boot/bzImage" \
		-initrd "$WORK/initramfs.cpio.gz" \
		-drive file="$IMG",format=raw,if=ide \
		-append "console=ttyS0 panic=-1 mister.phase=$1" \
		2>&1 | tee "$2"
}

step "phase 1: create symlinks in the VM"
run_vm 1 "$LOG1"
grep -q '^PHASE1_OK' "$LOG1" || { red "phase 1 failed"; exit 1; }

step "host-side on-disk checks + fabricate a legacy/Windows-made link"
PY="python3 $SCRIPT_DIR/exfat_attr.py $IMG"
$PY has-system rlink
$PY has-system dlink
$PY no-system  plain
[ "$($PY body dlink)" = "/target/abs" ] && green "ok: dlink body == /target/abs" \
	|| { red "FAIL: dlink on-disk body wrong"; exit 1; }
# Flip SYSTEM on the plain 'legacy' file so the driver must read it as a link.
$PY set-system legacy

step "phase 2: verify reads (incl. the fabricated legacy link)"
run_vm 2 "$LOG2"
grep -q '^PHASE2_OK' "$LOG2" || { red "phase 2 failed"; exit 1; }

step "summary"
if grep -q '^RESULT: PASS' "$LOG1" && grep -q '^RESULT: PASS' "$LOG2"; then
	green "ALL TESTS PASSED"
	exit 0
fi
red "TESTS FAILED — see $LOG1 and $LOG2"
exit 1

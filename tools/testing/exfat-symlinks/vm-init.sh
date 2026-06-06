#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
#
# PID 1 inside the QEMU test VM.  Runs one phase of the exFAT symlink test
# against the exFAT image exposed as /dev/sda, then powers off.  The phase is
# read from the kernel command line (mister.phase=1|2).
#
# Sentinels printed on the serial console are scraped by run.sh:
#   PHASE<n>_OK / PHASE<n>_FAIL and a final RESULT: PASS/FAIL.

export PATH=/bin:/sbin:/usr/bin:/usr/sbin
/bin/busybox --install -s /bin 2>/dev/null

mount -t proc     proc /proc
mount -t sysfs    sys  /sys
mount -t devtmpfs dev  /dev
mkdir -p /mnt

phase=1
for arg in $(cat /proc/cmdline); do
	case "$arg" in
	mister.phase=*) phase="${arg#mister.phase=}" ;;
	esac
done

fail=0
check() { # check "desc" "expected" "actual"
	if [ "$2" = "$3" ]; then
		echo "  ok   : $1"
	else
		echo "  FAIL : $1 (expected [$2], got [$3])"
		fail=1
	fi
}

DEV=/dev/sda

echo "=== exFAT symlink test: phase $phase ==="

if ! mount -t exfat "$DEV" /mnt 2>/dev/null; then
	echo "PHASE${phase}_FAIL: cannot mount exfat on $DEV"
	echo "RESULT: FAIL"
	poweroff -f
fi

if [ "$phase" = "1" ]; then
	# Driver-created content.
	printf %s "HELLO" > /mnt/realfile
	ln -s realfile     /mnt/rlink        || fail=1   # relative symlink
	ln -s /target/abs  /mnt/dlink        || fail=1   # absolute symlink
	# A plain regular file whose body is a path; run.sh's host step flips its
	# SYSTEM bit so phase 2 can prove a "legacy"/Windows-made link is read.
	printf %s "/target/legacy" > /mnt/legacy
	# A plain regular file that must stay a regular file.
	printf %s "PLAINDATA" > /mnt/plain
	sync

	check "rlink is a symlink"           "yes" "$([ -L /mnt/rlink ] && echo yes || echo no)"
	check "rlink target"                 "realfile"    "$(readlink /mnt/rlink)"
	check "rlink resolves to file"       "HELLO"       "$(cat /mnt/rlink)"
	check "dlink target"                 "/target/abs" "$(readlink /mnt/dlink)"
	check "plain is a regular file"      "yes" "$([ -f /mnt/plain ] && [ ! -L /mnt/plain ] && echo yes || echo no)"

	umount /mnt
	[ "$fail" = 0 ] && echo "PHASE1_OK" || echo "PHASE1_FAIL"
	[ "$fail" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
else
	# Phase 2: re-mount after host flipped legacy's SYSTEM bit.
	check "rlink survives remount"       "realfile"       "$(readlink /mnt/rlink)"
	check "dlink survives remount"       "/target/abs"    "$(readlink /mnt/dlink)"
	check "legacy is now a symlink"      "yes" "$([ -L /mnt/legacy ] && echo yes || echo no)"
	check "legacy (Windows-made) target" "/target/legacy" "$(readlink /mnt/legacy)"
	check "plain still a regular file"   "yes" "$([ -f /mnt/plain ] && [ ! -L /mnt/plain ] && echo yes || echo no)"
	check "plain body intact"            "PLAINDATA"      "$(cat /mnt/plain)"

	umount /mnt
	[ "$fail" = 0 ] && echo "PHASE2_OK" || echo "PHASE2_FAIL"
	[ "$fail" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
fi

poweroff -f

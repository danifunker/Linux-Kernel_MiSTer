#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
#
# MiSTer exFAT symlink test helper.
#
# A minimal, read/write exFAT directory walker used by the symlink test
# harness.  It can:
#
#   * print the FileAttributes and body of a named entry in the root dir
#   * assert that an entry has (or does not have) the SYSTEM attribute (0x04)
#   * flip the SYSTEM attribute on an entry (recomputing the entry-set
#     checksum), to fabricate a "legacy" / Windows-made symlink and prove the
#     driver reads it back.
#
# This deliberately does NOT use the kernel driver, so it is an independent
# check of the on-disk format that makes links survive a copy on Windows/macOS.
#
# Only what the test needs is implemented: files live in the root directory,
# names are ASCII, bodies fit in the first cluster.

import struct
import sys

ATTR_SYSTEM = 0x04

EXFAT_FILE      = 0x85   # file directory entry (in use)
EXFAT_STREAM    = 0xC0   # stream extension
EXFAT_NAME      = 0xC1   # file name
ENTRY_SIZE      = 32


class Exfat:
    def __init__(self, path):
        self.path = path
        with open(path, "rb") as f:
            self.data = bytearray(f.read())
        bs = self.data
        if bs[3:11] != b"EXFAT   ":
            raise ValueError("not an exFAT image (bad filesystem name)")
        self.fat_offset      = struct.unpack_from("<I", bs, 0x50)[0]
        self.cluster_heap    = struct.unpack_from("<I", bs, 0x58)[0]
        self.root_cluster    = struct.unpack_from("<I", bs, 0x60)[0]
        self.bytes_per_sec   = 1 << bs[0x6C]
        self.sec_per_clu     = 1 << bs[0x6D]
        self.bytes_per_clu   = self.bytes_per_sec * self.sec_per_clu

    def _clu_to_off(self, clu):
        return (self.cluster_heap + (clu - 2) * self.sec_per_clu) * self.bytes_per_sec

    def _fat_next(self, clu):
        off = self.fat_offset * self.bytes_per_sec + clu * 4
        return struct.unpack_from("<I", self.data, off)[0]

    def _clusters(self, start):
        clu = start
        seen = set()
        while clu not in (0, 0xFFFFFFFF) and clu >= 2 and clu not in seen:
            seen.add(clu)
            yield clu
            clu = self._fat_next(clu)

    def _read_chain(self, start, length):
        out = bytearray()
        for clu in self._clusters(start):
            out += self.data[self._clu_to_off(clu):self._clu_to_off(clu) + self.bytes_per_clu]
            if len(out) >= length:
                break
        return bytes(out[:length])

    def _root_entries(self):
        """Yield (absolute_offset_of_0x85_entry, entry_bytes_concat) per set."""
        buf = bytearray()
        offs = []
        for clu in self._clusters(self.root_cluster):
            base = self._clu_to_off(clu)
            for i in range(0, self.bytes_per_clu, ENTRY_SIZE):
                buf += self.data[base + i:base + i + ENTRY_SIZE]
                offs.append(base + i)
        i = 0
        n = len(buf) // ENTRY_SIZE
        while i < n:
            etype = buf[i * ENTRY_SIZE]
            if etype == 0x00:
                break
            if etype == EXFAT_FILE:
                secondary = buf[i * ENTRY_SIZE + 1]
                count = secondary + 1
                yield offs[i], buf[i * ENTRY_SIZE:(i + count) * ENTRY_SIZE], offs[i:i + count]
                i += count
            else:
                i += 1

    def _name_of(self, set_bytes):
        secondary = set_bytes[1]
        name = ""
        name_len = 0
        for k in range(1, secondary + 1):
            e = set_bytes[k * ENTRY_SIZE:(k + 1) * ENTRY_SIZE]
            if e[0] == EXFAT_STREAM:
                name_len = e[3]
            elif e[0] == EXFAT_NAME:
                chars = e[2:32]
                name += chars.decode("utf-16-le")
        return name[:name_len]

    def find(self, name):
        for file_off, set_bytes, set_offs in self._root_entries():
            if self._name_of(set_bytes) == name:
                return file_off, set_bytes, set_offs
        return None

    def attr(self, name):
        hit = self.find(name)
        if not hit:
            raise KeyError(name)
        _, set_bytes, _ = hit
        return struct.unpack_from("<H", set_bytes, 4)[0]

    def body(self, name):
        hit = self.find(name)
        if not hit:
            raise KeyError(name)
        _, set_bytes, _ = hit
        stream = set_bytes[ENTRY_SIZE:2 * ENTRY_SIZE]
        first_clu = struct.unpack_from("<I", stream, 20)[0]
        data_len  = struct.unpack_from("<Q", stream, 24)[0]
        if data_len == 0:
            return b""
        return self._read_chain(first_clu, data_len)

    @staticmethod
    def _set_checksum(set_bytes):
        csum = 0
        for idx, b in enumerate(set_bytes):
            if idx in (2, 3):
                continue
            csum = (((csum << 15) | (csum >> 1)) + b) & 0xFFFF
        return csum

    def set_system_bit(self, name):
        """Set SYSTEM on an entry and fix the entry-set checksum, in place."""
        hit = self.find(name)
        if not hit:
            raise KeyError(name)
        file_off, set_bytes, set_offs = hit
        attr = struct.unpack_from("<H", set_bytes, 4)[0] | ATTR_SYSTEM
        struct.pack_into("<H", set_bytes, 4, attr)
        csum = self._set_checksum(set_bytes)
        struct.pack_into("<H", set_bytes, 2, csum)
        # write the whole set back to its on-disk locations
        for k, off in enumerate(set_offs):
            self.data[off:off + ENTRY_SIZE] = set_bytes[k * ENTRY_SIZE:(k + 1) * ENTRY_SIZE]
        with open(self.path, "r+b") as f:
            f.write(self.data)


def main(argv):
    if len(argv) < 4:
        print(__doc__)
        print("usage: exfat_attr.py <image> <cmd> <name> [expected]")
        print("  cmds: attr | body | has-system | no-system | set-system")
        return 2
    img, cmd, name = argv[1], argv[2], argv[3]
    fs = Exfat(img)

    if cmd == "attr":
        print("0x%04x" % fs.attr(name))
    elif cmd == "body":
        sys.stdout.buffer.write(fs.body(name))
    elif cmd == "has-system":
        a = fs.attr(name)
        if not (a & ATTR_SYSTEM):
            print("FAIL: %s attr=0x%04x has no SYSTEM bit" % (name, a))
            return 1
        print("ok: %s has SYSTEM (attr=0x%04x)" % (name, a))
    elif cmd == "no-system":
        a = fs.attr(name)
        if a & ATTR_SYSTEM:
            print("FAIL: %s attr=0x%04x unexpectedly has SYSTEM bit" % (name, a))
            return 1
        print("ok: %s has no SYSTEM (attr=0x%04x)" % (name, a))
    elif cmd == "set-system":
        fs.set_system_bit(name)
        print("ok: set SYSTEM on %s (attr now 0x%04x)" % (name, fs.attr(name)))
    else:
        print("unknown cmd: %s" % cmd)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

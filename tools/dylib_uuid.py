#!/usr/bin/env python3
"""Print the Mach-O LC_UUID of the DYLuckyBag.dylib inside each .deb.

Why this exists
---------------
When the user reports "it still crashes after your fix", the FIRST question is
not "why did the fix fail" but "was the fix even installed?". A tweak is
injected at process launch, so installing a new .deb without killing and
relaunching the host app leaves the OLD dylib resident in the process.

The only trustworthy build fingerprint is the dylib's LC_UUID, which appears in
the crash report's usedImages entry. Matching it against the UUIDs of the debs
we built tells us exactly which commit was running on the device.

    crash report  -> usedImages[N].uuid (dashed 8-4-4-4-12)
    this tool     -> 32 hex chars, no dashes

Compare case-insensitively with the dashes stripped.

Usage
-----
    python3 tools/dylib_uuid.py output/b371fe7/DYLuckyBag-*.deb
    python3 tools/dylib_uuid.py --uuid 2a8bac91-c4c1-45f8-a4b5-1107d3ff48af <debs...>

Windows notes: there is no `ar`, `otool`, `nm` or `dpkg-deb` here, so the .deb
ar archive and the Mach-O load commands are parsed by hand.
"""
import glob
import io
import lzma
import os
import struct
import sys
import tarfile


def decompress(member):
    """data.tar may be lzma/zst/gz/plain depending on the dpkg version."""
    for opener in (
        lambda b: tarfile.open(fileobj=io.BytesIO(lzma.decompress(b))),
        lambda b: tarfile.open(fileobj=io.BytesIO(b)),
    ):
        try:
            return opener(member)
        except Exception:
            continue
    return None


def dylib_from_deb(path):
    """Extract the first DYLuckyBag.dylib found in a .deb, as bytes."""
    with open(path, "rb") as fh:
        data = fh.read()
    if not data.startswith(b"!<ar"):
        return None
    pos = 8
    while pos < len(data):
        header = data[pos:pos + 60]
        if len(header) < 60:
            break
        name = header[0:16].decode(errors="replace").strip().strip("/")
        size = int(header[48:58].decode().strip() or 0)
        pos += 60
        body = data[pos:pos + size]
        pos += size + (size & 1)  # members are 2-byte aligned
        if name.startswith("data.tar"):
            tf = decompress(body)
            if tf is None:
                return None
            for member in tf.getmembers():
                if member.name.endswith("DYLuckyBag.dylib"):
                    return tf.extractfile(member).read()
    return None


def macho_uuid(blob):
    """Return the list of LC_UUIDs (hex, no dashes) from a Mach-O or fat file."""
    if blob is None:
        return []
    magic = struct.unpack("<I", blob[:4])[0]
    if magic in (0xCFFAEDFE, 0xBEBAFECA):   # 0xcafebabe / 0xbebafeca big-endian
        nfat = struct.unpack(">I", blob[4:8])[0]
        offsets = []
        off = 8
        for _ in range(nfat):
            _cpu, _sub, arch_off, _size, _align = struct.unpack(">5I", blob[off:off + 20])
            off += 20
            offsets.append(arch_off)
        return [u for ao in offsets for u in [single_uuid(blob[ao:])] if u]
    return [u for u in [single_uuid(blob)] if u]


def single_uuid(blob):
    magic = struct.unpack("<I", blob[:4])[0]
    endian = "<" if magic in (0xFEEDFACF, 0xFEEDFACE) else ">"
    ncmds = struct.unpack(endian + "I", blob[16:20])[0]
    pos = 32                                  # sizeof(mach_header_64)
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack(endian + "II", blob[pos:pos + 8])
        if cmd == 0x1B:                       # LC_UUID
            return blob[pos + 8:pos + 24].hex()
        pos += cmdsize
    return None


def main():
    args = sys.argv[1:]
    wanted = None
    if args and args[0] == "--uuid":
        wanted = args[1].replace("-", "").lower()
        args = args[2:]
    if not args:
        print(__doc__)
        return 1
    paths = []
    for pattern in args:
        expanded = sorted(glob.glob(pattern))
        paths.extend(expanded if expanded else [pattern])
    hit = False
    for path in paths:
        if not os.path.exists(path):
            print("%-58s (missing)" % path)
            continue
        uuids = macho_uuid(dylib_from_deb(path))
        tag = ""
        if wanted:
            if wanted in [u.lower() for u in uuids]:
                tag = "   <<< MATCH"
                hit = True
        print("%-58s %s%s" % (path, uuids or "(no dylib found)", tag))
    if wanted and not hit:
        print("\nno deb matched uuid %s" % wanted)
    return 0


if __name__ == "__main__":
    sys.exit(main())

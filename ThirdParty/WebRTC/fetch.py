#!/usr/bin/env python3
"""Fetch the macOS slice of LiveKit's pinned WebRTC build into a vendor dir.

LiveKit publishes one 687 MB zip with every Apple platform and its dSYMs. Jarvis
needs only the 29 MB macOS framework, so this reads the zip's directory and the
macOS members with HTTP range requests, writes a macOS-only xcframework, and
checks the result against a pinned tree hash. The tree hash was taken from a
copy extracted from the full zip after verifying LiveKit's published checksum
(ZIP_SHA256 below).

usage: fetch.py [dest]   (default build/vendor/WebRTC)
"""
import hashlib
import os
import plistlib
import shutil
import struct
import sys
import tempfile
import urllib.request
import zlib

VERSION = "150.7871.08"
URL = f"https://github.com/livekit/webrtc-xcframework/releases/download/{VERSION}/LiveKitWebRTC.xcframework.zip"
ZIP_SHA256 = "008dbf8187843ab708afa44b65b8041d8ce8da99e530608cd85aa6ea3551529a"
TREE_SHA256 = "4ed82dc4e7ad18a5cea37a3a81cae95816edb4b30592b6144f2cb1176ba3f2e1"
ROOT = "LiveKitWebRTC.xcframework/"
SLICE = ROOT + "macos-arm64_x86_64/LiveKitWebRTC.framework/"


class Remote:
    def __init__(self, url):
        self.url = urllib.request.urlopen(urllib.request.Request(url, method="HEAD")).url
        self.size = int(urllib.request.urlopen(urllib.request.Request(self.url, method="HEAD")).headers["Content-Length"])

    def read(self, start, length):
        request = urllib.request.Request(self.url, headers={"Range": f"bytes={start}-{start + length - 1}"})
        with urllib.request.urlopen(request) as response:
            data = response.read()
        if len(data) != length:
            raise SystemExit(f"short read at {start}: {len(data)} of {length}")
        return data


def central_directory(remote):
    tail = remote.read(remote.size - 65536 - 22, 65536 + 22)
    at = tail.rfind(b"PK\x05\x06")
    if at < 0:
        raise SystemExit("no end of central directory")
    entries, size, offset = struct.unpack("<10xHII", tail[at:at + 20])
    if offset == 0xFFFFFFFF or entries == 0xFFFF:
        locator = tail.rfind(b"PK\x06\x07")
        (zip64_end,) = struct.unpack("<8xQ", tail[locator:locator + 16])
        record = remote.read(zip64_end, 56)
        entries, size, offset = struct.unpack("<32xQQQ", record)
    data = remote.read(offset, size)
    members, pos = [], 0
    for _ in range(entries):
        (method, crc, csize, usize, nlen, xlen, clen, attr, local) = struct.unpack(
            "<10xH4xIIIHHH4xII", data[pos:pos + 46])
        name = data[pos + 46:pos + 46 + nlen].decode()
        extra = data[pos + 46 + nlen:pos + 46 + nlen + xlen]
        if 0xFFFFFFFF in (csize, usize, local):
            fields, x = {}, 0
            while x < len(extra):
                tag, length = struct.unpack("<HH", extra[x:x + 4])
                fields[tag] = extra[x + 4:x + 4 + length]
                x += 4 + length
            values = list(struct.unpack(f"<{len(fields[1]) // 8}Q", fields[1]))
            if usize == 0xFFFFFFFF: usize = values.pop(0)
            if csize == 0xFFFFFFFF: csize = values.pop(0)
            if local == 0xFFFFFFFF: local = values.pop(0)
        members.append((name, method, crc, csize, usize, attr >> 16, local))
        pos += 46 + nlen + xlen + clen
    return members


def member_bytes(remote, member):
    name, method, crc, csize, usize, mode, local = member
    header = remote.read(local, 30)
    nlen, xlen = struct.unpack("<26xHH", header)
    raw = remote.read(local + 30 + nlen + xlen, csize) if csize else b""
    data = zlib.decompress(raw, -15) if method == 8 else raw
    if len(data) != usize or zlib.crc32(data) & 0xFFFFFFFF != crc:
        raise SystemExit(f"bad member {name}")
    return data


def member_path(work, name):
    """Where a member goes, refusing any that would land outside work."""
    if name.startswith("/") or ".." in name.split("/"):
        raise SystemExit(f"unsafe member {name}")
    path = os.path.join(work, name)
    if not os.path.realpath(os.path.dirname(path)).startswith(work + os.sep):
        raise SystemExit(f"unsafe member {name}")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if os.path.lexists(path):
        raise SystemExit(f"duplicate member {name}")
    return path


def tree_hash(root):
    lines = []
    for folder, dirs, files in os.walk(root):
        dirs.sort()
        for entry in sorted(dirs + files):
            path = os.path.join(folder, entry)
            rel = os.path.relpath(path, root)
            if os.path.islink(path):
                lines.append(f"L {rel} {os.readlink(path)}")
            elif os.path.isfile(path):
                with open(path, "rb") as f:
                    lines.append(f"F {rel} {hashlib.sha256(f.read()).hexdigest()}")
    return hashlib.sha256("\n".join(lines).encode()).hexdigest()


def main():
    dest = sys.argv[1] if len(sys.argv) > 1 else "build/vendor/WebRTC"
    stamp = os.path.join(dest, ".pinned")
    if os.path.exists(stamp) and open(stamp).read().strip() == TREE_SHA256:
        return
    remote = Remote(URL)
    members = central_directory(remote)
    work = os.path.realpath(tempfile.mkdtemp())
    try:
        out = os.path.join(work, "LiveKitWebRTC.xcframework")
        for member in members:
            name, mode = member[0], member[5]
            wanted = name.startswith(SLICE) or name in (ROOT + "LICENSE", ROOT + "Info.plist")
            if not wanted or name.endswith("/"):
                continue
            path = member_path(work, name)
            data = member_bytes(remote, member)
            if mode & 0o170000 == 0o120000:
                os.symlink(data.decode(), path)
                continue
            with open(path, "wb") as f:
                f.write(data)
            os.chmod(path, (mode & 0o777) or 0o644)
        info_path = os.path.join(out, "Info.plist")
        with open(info_path, "rb") as f:
            info = plistlib.load(f)
        info["AvailableLibraries"] = [lib for lib in info["AvailableLibraries"]
                                      if lib["LibraryIdentifier"] == "macos-arm64_x86_64"]
        for lib in info["AvailableLibraries"]:
            lib.pop("DebugSymbolsPath", None)
        with open(info_path, "wb") as f:
            plistlib.dump(info, f, sort_keys=True)
        got = tree_hash(out)
        if len(sys.argv) > 2 and sys.argv[2] == "--print-tree-hash":
            print(got)
            return
        if got != TREE_SHA256:
            raise SystemExit(f"WebRTC tree hash {got} does not match the pinned {TREE_SHA256}")
        shutil.rmtree(dest, ignore_errors=True)
        os.makedirs(dest)
        shutil.move(out, os.path.join(dest, "LiveKitWebRTC.xcframework"))
        with open(stamp, "w") as f:
            f.write(TREE_SHA256 + "\n")
        print(f"WebRTC {VERSION} ready in {dest}")
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Verify that target strings are present inside a built .deb's dylib.

The dylib stores CJK literals as UTF-16LE (ASCII search misses them), so we scan
both UTF-16LE and UTF-8/ASCII forms. Pure-python: ar parse + lzma/gz decompress
+ tarfile, no external binaries needed.

Usage: verify_deb.py <deb-path> [target1 target2 ...]
If no targets given, a default set for the comment fill/send hardening is used.
"""
import gzip
import io
import lzma
import os
import sys
import tarfile

DEFAULT_TARGETS = [
    "评论框已消失，参与未完成",
    "发送按钮已消失，参与未完成",
    "评论发送异常，已跳过",
    "评论可能未发出",
    "检测/参与异常，已跳过",
    # sanity: prior comment-path strings must still be present
    "已发评论",
    "comment sent",
    "fillAndSend",
    "评论发送",
    # method-name markers confirming the guards compiled in
    "attemptCommentSend",
    "verifyCommentSent",
    "handleHits",
]


def parse_ar(data):
    """Yield (name, bytes) for each ar member."""
    assert data[:8] == b"!<arch>\n", "not an ar archive"
    off = 8
    members = []
    while off < len(data):
        if data[off:off + 8] == b"!<arch>\n":
            off = 8  # safety: reset
            continue
        header = data[off:off + 60]
        if len(header) < 60:
            break
        name = header[0:16].decode("utf-8", "replace").strip()
        size = int(header[48:58].decode("ascii").strip())
        off += 60
        body = data[off:off + size]
        off += size
        if size % 2 == 1:  # ar pads odd-sized members with a trailing newline
            off += 1
        members.append((name, body))
    return members


def extract_dylib(deb_path):
    with open(deb_path, "rb") as fh:
        data = fh.read()
    for name, body in parse_ar(data):
        if name.startswith("data.tar"):
            if name.endswith(".lzma") or name.endswith(".xz"):
                tar_bytes = lzma.decompress(body)
            elif name.endswith(".gz"):
                tar_bytes = gzip.decompress(body)
            else:
                tar_bytes = body
            with tarfile.open(fileobj=io.BytesIO(tar_bytes), mode="r:") as tf:
                for m in tf.getmembers():
                    if m.name.endswith(".dylib"):
                        return tf.extractfile(m).read()
    raise SystemExit("dylib not found in %s" % deb_path)


def main():
    deb = sys.argv[1]
    targets = sys.argv[2:] or DEFAULT_TARGETS
    dylib = extract_dylib(deb)
    print("dylib size: %d bytes" % len(dylib))
    all_ok = True
    for t in targets:
        utf16 = t.encode("utf-16-le")
        utf8 = t.encode("utf-8")
        found = (utf16 in dylib) or (utf8 in dylib)
        marker = "FOUND " if found else "MISSING"
        if not found:
            all_ok = False
        print("  [%s] %s" % (marker, t))
    # also report raw ASCII-only markers that should always be there
    print("RESULT: %s" % ("ALL FOUND" if all_ok else "SOME MISSING"))
    sys.exit(0 if all_ok else 1)


if __name__ == "__main__":
    main()

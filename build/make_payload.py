# -*- coding: utf-8 -*-
"""把应用脚本、版本、图标及 exiftool_bin 拼接到 launcher 后面。
用法: python3 make_payload.py <launcher> <输出文件> <源目录(含app.ps1和exiftool_bin)>"""
import os
import struct
import sys
import hashlib

MAGIC = b"AITAGPK1"


def build_payload(src_dir):
    chunks = []
    entries = []
    # Required files fail the build early rather than producing an incomplete EXE.
    required = ("app.ps1", "runtime.ps1", "metadata.ps1", "ui.ps1", "VERSION")
    targets = [(name, os.path.join(src_dir, name)) for name in required]
    for _rel, full in targets:
        if not os.path.isfile(full):
            raise FileNotFoundError(f"缺少必需的打包文件: {full}")
    ico = os.path.join(src_dir, "assets", "SynthTag.ico")
    if not os.path.isfile(ico):
        raise FileNotFoundError(f"缺少图标: {ico}")
    targets.append(("SynthTag.ico", ico))   # 供窗口/任务栏图标使用
    et = os.path.join(src_dir, "exiftool_bin")
    if not os.path.isfile(os.path.join(et, "exiftool.exe")):
        raise FileNotFoundError("缺少 exiftool_bin/exiftool.exe")
    for dependency in ("perl.exe", "perl532.dll", "exiftool.pl", "lib/Image/ExifTool.pm"):
        full = os.path.join(et, "exiftool_files", *dependency.split("/"))
        if not os.path.isfile(full):
            raise FileNotFoundError(f"缺少 ExifTool 必需依赖: {full}")
    for root, _dirs, files in os.walk(et):
        _dirs.sort()
        for f in sorted(files):
            full = os.path.join(root, f)
            rel = "exiftool_bin/" + os.path.relpath(full, et).replace(os.sep, "/")
            targets.append((rel, full))
    for rel, full in targets:
        with open(full, "rb") as source:
            data = source.read()
        rel_b = rel.encode("utf-8")
        chunks.append(struct.pack("<I", len(rel_b)) + rel_b +
                      struct.pack("<Q", len(data)) + data)
        entries.append((rel, len(data)))
    return b"".join(chunks), entries


def main():
    launcher, out, src = sys.argv[1], sys.argv[2], sys.argv[3]
    stub = open(launcher, "rb").read()
    payload, entries = build_payload(src)
    with open(out, "wb") as f:
        f.write(stub)
        f.write(payload)
        f.write(MAGIC + struct.pack("<Q", len(stub)))
    print(f"文件数: {len(entries)}  payload: {len(payload)/1e6:.1f} MB  "
          f"输出: {out} ({(len(stub)+len(payload)+16)/1e6:.1f} MB)")
    print(f"Payload SHA-256: {hashlib.sha256(payload).hexdigest()}")


if __name__ == "__main__":
    main()

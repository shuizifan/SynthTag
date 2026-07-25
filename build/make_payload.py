# -*- coding: utf-8 -*-
"""把 app.ps1 + exiftool_bin 打成 payload 并拼接到 launcher 后面, 产出单文件 exe。
用法: python3 make_payload.py <launcher> <输出文件> <源目录(含app.ps1和exiftool_bin)>"""
import os
import struct
import sys

MAGIC = b"AITAGPK1"


def build_payload(src_dir):
    chunks = []
    entries = []
    # app.ps1 在根, exiftool_bin 整体保留结构
    targets = [("app.ps1", os.path.join(src_dir, "app.ps1"))]
    ico = os.path.join(src_dir, "assets", "SynthTag.ico")
    if os.path.isfile(ico):
        targets.append(("SynthTag.ico", ico))   # 供窗口/任务栏图标使用
    et = os.path.join(src_dir, "exiftool_bin")
    for root, _dirs, files in os.walk(et):
        for f in sorted(files):
            full = os.path.join(root, f)
            rel = "exiftool_bin/" + os.path.relpath(full, et).replace(os.sep, "/")
            targets.append((rel, full))
    for rel, full in targets:
        data = open(full, "rb").read()
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


if __name__ == "__main__":
    main()

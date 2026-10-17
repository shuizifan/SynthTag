"""Native launcher regressions. Compile with -DTEST_CLI and -lbcrypt first.

python build/test_launcher.py build/launcher_test.exe
"""
import ctypes
import hashlib
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

LAUNCHER = Path(sys.argv.pop(1)).resolve()
REQUIRED = {"app.ps1": b"old", "runtime.ps1": b"runtime", "metadata.ps1": b"metadata",
            "VERSION": b"1.1.0", "SynthTag.ico": b"icon", "exiftool_bin/exiftool.exe": b"exe",
            "exiftool_bin/exiftool_files/perl.exe": b"perl executable",
            "exiftool_bin/exiftool_files/perl532.dll": b"perl runtime",
            "exiftool_bin/exiftool_files/exiftool.pl": b"exiftool script",
            "exiftool_bin/exiftool_files/lib/Image/ExifTool.pm": b"exiftool library"}


def entry(name, data, size=None):
    name = name.encode("utf-8")
    return struct.pack("<I", len(name)) + name + struct.pack("<Q", len(data) if size is None else size) + data


class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="SynthTag-launcher-")
        self.root = Path(self.temp.name)
        self.dest = self.root / "cache"

    def tearDown(self):
        self.temp.cleanup()

    def package(self, files=None, raw=None):
        payload = raw if raw is not None else b"".join(entry(n, d) for n, d in (files or REQUIRED).items())
        package = self.root / "package.bin"
        package.write_bytes(b"stub" + payload + b"AITAGPK1" + struct.pack("<Q", 4))
        return package, hashlib.sha256(payload).hexdigest()

    def run_extract(self, package, success=True):
        result = subprocess.run([str(LAUNCHER), str(package), str(self.dest)], capture_output=True, text=True)
        if success:
            self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        else:
            self.assertNotEqual(0, result.returncode, result.stdout + result.stderr)
            self.assertFalse((self.dest / "install.ver").is_file(), "Failure must not leave a success marker")
        return result

    def test_valid_unicode_and_cache_identity(self):
        files = dict(REQUIRED, **{"images/测试.png": b"image"})
        package, digest = self.package(files)
        self.run_extract(package)
        self.assertEqual(b"image", (self.dest / "images/测试.png").read_bytes())
        self.assertEqual(digest, (self.dest / "install.ver").read_text())
        self.run_extract(package)
        files["app.ps1"] = b"new"  # Same payload byte count, different actual content.
        package, changed = self.package(files)
        self.assertNotEqual(digest, changed)
        self.run_extract(package)
        self.assertEqual(b"new", (self.dest / "app.ps1").read_bytes())
        self.assertEqual(changed, (self.dest / "install.ver").read_text())

    def test_deleted_required_file_repaired(self):
        package, _ = self.package()
        self.run_extract(package)
        (self.dest / "runtime.ps1").unlink()
        self.run_extract(package)
        self.assertEqual(b"runtime", (self.dest / "runtime.ps1").read_bytes())

    def test_deleted_nested_dependency_repaired(self):
        package, _ = self.package()
        self.run_extract(package)
        name = "exiftool_bin/exiftool_files/perl.exe"
        (self.dest / name).unlink()
        self.run_extract(package)
        self.assertEqual(REQUIRED[name], (self.dest / name).read_bytes())

    def test_same_size_corruption_and_truncated_dependency_repaired(self):
        package, _ = self.package()
        self.run_extract(package)
        for name in ("app.ps1", "exiftool_bin/exiftool_files/lib/Image/ExifTool.pm"):
            with self.subTest(name=name):
                (self.dest / name).write_bytes(b"x" * len(REQUIRED[name]))
                self.run_extract(package)
                self.assertEqual(REQUIRED[name], (self.dest / name).read_bytes())
                (self.dest / name).write_bytes(b"")
                self.run_extract(package)
                self.assertEqual(REQUIRED[name], (self.dest / name).read_bytes())

    def test_truncated_header_is_failure(self):
        package, _ = self.package(raw=b"\x01\x02")
        self.run_extract(package, False)

    def test_oversized_entry_is_failure(self):
        package, _ = self.package(raw=entry("app.ps1", b"short", size=9999))
        self.run_extract(package, False)

    def test_invalid_offset_is_failure(self):
        package, _ = self.package()
        data = package.read_bytes()
        package.write_bytes(data[:-8] + struct.pack("<Q", len(data) + 100))
        self.run_extract(package, False)

    def test_traversal_is_failure(self):
        package, _ = self.package(raw=entry("../escape", b"no"))
        self.run_extract(package, False)
        self.assertFalse((self.root / "escape").exists())

    def test_embedded_null_is_failure(self):
        package, _ = self.package(raw=entry("app.ps1\x00evil", b"no"))
        self.run_extract(package, False)

    def test_windows_normalization_and_devices_are_rejected(self):
        for name in (".. /escape", "folder./escape", "NUL", "dir/AUX.png", "app.ps1:alternate"):
            with self.subTest(name=name):
                package, _ = self.package(raw=entry(name, b"no"))
                self.run_extract(package, False)

    def test_output_open_failure_is_failure(self):
        self.dest.mkdir()
        (self.dest / "app.ps1").mkdir()  # Existing directory cannot be fopen'd.
        package, _ = self.package()
        self.run_extract(package, False)

    def test_parent_directory_failure_is_failure(self):
        self.dest.mkdir()
        (self.dest / "exiftool_bin").write_bytes(b"block")
        package, _ = self.package()
        self.run_extract(package, False)

    def test_locked_destination_is_failure(self):
        self.dest.mkdir()
        locked = self.dest / "app.ps1"
        locked.write_bytes(b"preserve")
        create = ctypes.windll.kernel32.CreateFileW
        create.argtypes = [ctypes.c_wchar_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_void_p,
                           ctypes.c_ulong, ctypes.c_ulong, ctypes.c_void_p]
        create.restype = ctypes.c_void_p
        handle = create(str(locked), 0x80000000, 0, None, 3, 0, None)
        self.assertNotEqual(ctypes.c_void_p(-1).value, handle)
        try:
            package, _ = self.package()
            self.run_extract(package, False)
        finally:
            close = ctypes.windll.kernel32.CloseHandle
            close.argtypes = [ctypes.c_void_p]
            close(handle)
        self.assertEqual(b"preserve", locked.read_bytes())

    def test_marker_write_failure_is_failure(self):
        self.dest.mkdir()
        (self.dest / "install.ver").mkdir()
        package, _ = self.package()
        self.run_extract(package, False)

    def test_inaccessible_marker_blocks_changes_to_cache(self):
        self.dest.mkdir()
        (self.dest / "app.ps1").write_bytes(b"preserve")
        marker = self.dest / "install.ver"
        marker.write_bytes(b"obsolete")
        create = ctypes.windll.kernel32.CreateFileW
        create.argtypes = [ctypes.c_wchar_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_void_p,
                           ctypes.c_ulong, ctypes.c_ulong, ctypes.c_void_p]
        create.restype = ctypes.c_void_p
        handle = create(str(marker), 0x80000000, 0, None, 3, 0, None)
        self.assertNotEqual(ctypes.c_void_p(-1).value, handle)
        try:
            package, _ = self.package()
            result = subprocess.run([str(LAUNCHER), str(package), str(self.dest)], capture_output=True)
            self.assertNotEqual(0, result.returncode)
            self.assertEqual(b"preserve", (self.dest / "app.ps1").read_bytes())
        finally:
            close = ctypes.windll.kernel32.CloseHandle
            close.argtypes = [ctypes.c_void_p]
            close(handle)


if __name__ == "__main__":
    unittest.main(verbosity=2)

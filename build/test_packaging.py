"""Build-boundary and GUI-launcher smoke tests (no application window opened).

python build/test_packaging.py launcher.exe
"""
from datetime import date, timedelta
import hashlib
import importlib.util
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import time
import unittest

LAUNCHER = Path(sys.argv.pop(1)).resolve()
spec = importlib.util.spec_from_file_location("make_payload", Path(__file__).with_name("make_payload.py"))
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="SynthTag-package-")
        self.root = Path(self.temp.name)
        self.source = self.root / "source"
        self.source.mkdir()
        for name in ("app.ps1", "runtime.ps1", "metadata.ps1", "VERSION"):
            (self.source / name).write_text("1.1.0" if name == "VERSION" else "", encoding="utf-8")
        (self.source / "assets").mkdir()
        (self.source / "assets/SynthTag.ico").write_bytes(b"test icon")
        (self.source / "exiftool_bin").mkdir()
        (self.source / "exiftool_bin/exiftool.exe").write_bytes(b"test exiftool")
        for name in ("perl.exe", "perl532.dll", "exiftool.pl", "lib/Image/ExifTool.pm"):
            full = self.source / "exiftool_bin/exiftool_files" / name
            full.parent.mkdir(parents=True, exist_ok=True)
            full.write_bytes(b"test dependency")

    def tearDown(self):
        self.temp.cleanup()

    def test_missing_runtime_rejects_build(self):
        (self.source / "runtime.ps1").unlink()
        with self.assertRaises(FileNotFoundError):
            packager.build_payload(self.source)

    def test_missing_exiftool_dependency_rejects_build(self):
        for name in ("perl.exe", "perl532.dll", "exiftool.pl", "lib/Image/ExifTool.pm"):
            full = self.source / "exiftool_bin/exiftool_files" / name
            data = full.read_bytes()
            full.unlink()
            try:
                with self.subTest(name=name), self.assertRaises(FileNotFoundError):
                    packager.build_payload(self.source)
            finally:
                full.write_bytes(data)

    def test_launcher_uses_local_versioned_cache_and_rotates_logs(self):
        # This script creates a marker and exits; it never opens the actual UI.
        (self.source / "app.ps1").write_text(
            "[IO.File]::WriteAllText((Join-Path $env:LOCALAPPDATA 'started.txt'), $PSScriptRoot)\n",
            encoding="ascii")
        payload, entries = packager.build_payload(self.source)
        self.assertEqual({"app.ps1", "runtime.ps1", "metadata.ps1", "VERSION", "SynthTag.ico", "exiftool_bin/exiftool.exe",
                          "exiftool_bin/exiftool_files/perl.exe", "exiftool_bin/exiftool_files/perl532.dll",
                          "exiftool_bin/exiftool_files/exiftool.pl", "exiftool_bin/exiftool_files/lib/Image/ExifTool.pm"},
                         {name for name, _ in entries})
        stub = LAUNCHER.read_bytes()
        exe = self.root / "SynthTag.exe"
        exe.write_bytes(stub + payload + b"AITAGPK1" + struct.pack("<Q", len(stub)))
        local = self.root / "local"
        logs = local / "SynthTag/Logs"
        logs.mkdir(parents=True)
        old_name = "launcher-" + str(date.today() - timedelta(days=30)) + ".log"
        retained_name = "launcher-" + str(date.today() - timedelta(days=29)) + ".log"
        (logs / old_name).write_text("old")
        (logs / retained_name).write_text("keep")
        (logs / "user.log").write_text("unrelated")
        env = dict(os.environ, LOCALAPPDATA=str(local))
        subprocess.run([str(exe)], env=env, timeout=30, check=True)
        marker = local / "started.txt"
        for _ in range(100):
            if marker.exists():
                break
            time.sleep(0.1)
        self.assertTrue(marker.exists(), "PowerShell application did not start")
        digest = hashlib.sha256(payload).hexdigest()
        cache = local / f"SynthTag/Cache/1.1.0-{digest}"
        self.assertEqual(str(cache), marker.read_text())
        self.assertEqual(digest, (cache / "install.ver").read_text())
        self.assertFalse((logs / old_name).exists())
        self.assertTrue((logs / retained_name).exists())
        self.assertTrue((logs / "user.log").exists())
        current = logs / f"launcher-{date.today()}.log"
        self.assertIn("[INFO] version=1.1.0 PowerShell started", current.read_text())
        self.assertFalse((self.root / "launcher.log").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)

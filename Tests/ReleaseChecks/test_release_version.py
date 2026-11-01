import importlib.util
import os
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("release_version", Path(__file__).parents[2] / "scripts/release-version.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseVersionTests(unittest.TestCase):
    def test_only_exact_version_tags(self):
        for tag in ("v0.1.0", "v1.2.3", "v12.34.56"):
            self.assertEqual(release.tag_version(tag), tag[1:])
        for tag in ("1.2.3", "v01.2.3", "v1.2", "v1.2.3-beta", "v1.2.3\n", "v1.2.3;echo secret"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release.tag_version(tag)

    def test_stamps_version_and_preserves_permissions_metadata(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "Info.plist"
            original = {"CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1", "NSMicrophoneUsageDescription": "Record microphone"}
            path.write_bytes(plistlib.dumps(original))
            with patch.dict(os.environ, {"APP_VERSION": "1.2.3", "BUILD_NUMBER": "42"}):
                release.stamp(path)
            result = plistlib.loads(path.read_bytes())
            self.assertEqual(result, dict(original, CFBundleShortVersionString="1.2.3", CFBundleVersion="42"))

    def test_invalid_input_does_not_modify_bundle(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "Info.plist"
            original = plistlib.dumps({"CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1"})
            for version, build in (("v1.2.3", "1"), ("1.2.3", "0"), ("1.2.3", "-1"), ("1.2.3", "abc")):
                path.write_bytes(original)
                with patch.dict(os.environ, {"APP_VERSION": version, "BUILD_NUMBER": build}), self.assertRaises(ValueError):
                    release.stamp(path)
                self.assertEqual(path.read_bytes(), original)

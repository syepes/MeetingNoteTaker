import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).parents[2]
spec = importlib.util.spec_from_file_location('platform_check', ROOT / 'scripts/validate-platform.py')
platform = importlib.util.module_from_spec(spec)
spec.loader.exec_module(platform)


def commands(minimum='26.0', target='1'):
    return f'Load command 10\n cmd LC_BUILD_VERSION\n cmdsize 32\n platform {target}\n minos {minimum}\n sdk 27.0\nLoad command 11\n cmd LC_UUID\n'


class PlatformTests(unittest.TestCase):
    def test_accepts_arm64_macos26(self):
        platform.validate_binary('arm64\n', commands())
        platform.validate_binary('arm64', commands('26.0.0', 'MACOS'))
        platform.validate_metadata({'LSMinimumSystemVersion': '26.0'})

    def test_rejects_wrong_or_universal_architecture(self):
        for arch in ('x86_64', 'arm64 x86_64', 'arm64e', ''):
            with self.subTest(arch=arch), self.assertRaises(ValueError):
                platform.validate_binary(arch, commands())

    def test_rejects_wrong_or_missing_deployment_target(self):
        for data in (commands('15.0'), commands('26.1'), commands('27.0'), commands(target='2'), '', 'cmd LC_VERSION_MIN_MACOSX\n version 15.0'):
            with self.subTest(data=data), self.assertRaises(ValueError):
                platform.validate_binary('arm64', data)

    def test_rejects_mismatched_metadata(self):
        for value in ('15.0', '26.1', '27.0', 'invalid'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                platform.validate_metadata({'LSMinimumSystemVersion': value})

    def test_rejects_missing_helpers(self):
        with tempfile.TemporaryDirectory() as folder:
            app = Path(folder)
            (app / 'Contents').mkdir()
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'LSMinimumSystemVersion': '26.0', 'CFBundleExecutable': 'MeetingNoteTaker'}))
            with self.assertRaisesRegex(ValueError, 'Missing or invalid executable'):
                platform.validate_bundle(app)

    def test_source_metadata_and_package_agree(self):
        platform.validate_metadata(plistlib.loads((ROOT / 'Resources/Info.plist').read_bytes()))
        self.assertIn('.macOS("26.0")', (ROOT / 'Package.swift').read_text())

    def test_checks_extra_bundled_binaries_too(self):
        with tempfile.TemporaryDirectory() as folder:
            app = Path(folder)
            paths = ['MacOS/MeetingNoteTaker', 'Helpers/whisper-worker', 'Helpers/whisper-cli', 'Helpers/llama-server', 'Frameworks/extra.dylib']
            for relative in paths:
                path = app / 'Contents' / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(bytes.fromhex('cffaedfe'))
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'LSMinimumSystemVersion': '26.0', 'CFBundleExecutable': 'MeetingNoteTaker'}))
            def inspect(args, **kwargs):
                if args[0] == 'lipo':
                    return 'x86_64' if args[-1].endswith('extra.dylib') else 'arm64'
                return commands()
            with patch.object(platform.subprocess, 'check_output', side_effect=inspect), self.assertRaisesRegex(ValueError, 'extra.dylib'):
                platform.validate_bundle(app)

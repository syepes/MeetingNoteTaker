#!/usr/bin/env python3
"""Reject bundles that violate the macOS 26 / Apple Silicon baseline."""
import plistlib
import re
import subprocess
import sys
from pathlib import Path

MINIMUM = (26, 0, 0)
MACHO_MAGIC = {bytes.fromhex(value) for value in (
    'feedface', 'cefaedfe', 'feedfacf', 'cffaedfe',
    'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}


def version(value):
    parts = tuple(int(part) for part in value.split('.'))
    return parts + (0,) * (3 - len(parts))


def validate_metadata(metadata):
    if version(metadata.get('LSMinimumSystemVersion', '0')) != MINIMUM:
        raise ValueError('Application metadata must require macOS 26.0.')


def validate_binary(architectures, load_commands):
    if architectures.split() != ['arm64']:
        raise ValueError('Executable must contain only arm64.')
    builds = re.findall(r'\bcmd LC_BUILD_VERSION\b(.*?)(?=Load command|\Z)', load_commands, re.S)
    if len(builds) != 1:
        raise ValueError('Expected one modern deployment-target load command.')
    platform = re.search(r'\bplatform\s+(\S+)', builds[0])
    minimum = re.search(r'\bminos\s+(\S+)', builds[0])
    if not platform or platform[1].lower() not in ('1', 'macos'):
        raise ValueError('Executable must target macOS.')
    if not minimum or version(minimum[1]) != MINIMUM:
        raise ValueError('Executable must target macOS 26.0.')


def validate_bundle(app):
    with (app / 'Contents/Info.plist').open('rb') as stream:
        metadata = plistlib.load(stream)
    validate_metadata(metadata)
    required = [app / 'Contents/MacOS' / metadata['CFBundleExecutable']]
    required += [app / 'Contents/Helpers' / name for name in ('whisper-worker', 'whisper-cli', 'llama-server')]
    binaries = set()
    for path in app.rglob('*'):
        if path.is_file():
            with path.open('rb') as stream:
                if stream.read(4) in MACHO_MAGIC:
                    binaries.add(path)
    for path in required:
        if path not in binaries:
            raise ValueError(f'Missing or invalid executable: {path}')
    for path in sorted(binaries):
        try:
            arch = subprocess.check_output(['lipo', '-archs', str(path)], text=True)
            commands = subprocess.check_output(['otool', '-l', str(path)], text=True)
            validate_binary(arch, commands)
        except ValueError as error:
            raise ValueError(f'{path}: {error}') from error
    print(f'Validated macOS 26.0 / arm64 baseline for {len(binaries)} bundled binaries.')


if __name__ == '__main__':
    try:
        validate_bundle(Path(sys.argv[1]))
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))

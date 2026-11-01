"""Validate release tags and stamp only the packaged app, never source Info.plist."""
import os
import plistlib
import re
import sys

VERSION = r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"


def tag_version(tag):
    if not re.fullmatch("v" + VERSION, tag):
        raise ValueError("Release tag must be vX.X.X (no prerelease suffix or leading zeros)")
    return tag[1:]


def stamp(path):
    with open(path, "rb") as file:
        info = plistlib.load(file)
    version = os.environ.get("APP_VERSION", info["CFBundleShortVersionString"])
    build = os.environ.get("BUILD_NUMBER", info["CFBundleVersion"])
    if not re.fullmatch(VERSION, version):
        raise ValueError("APP_VERSION must be X.X.X")
    if not re.fullmatch(r"[1-9][0-9]*", build):
        raise ValueError("BUILD_NUMBER must be a positive integer")
    info.update(CFBundleShortVersionString=version, CFBundleVersion=build)
    with open(path, "wb") as file:
        plistlib.dump(info, file, sort_keys=False)


if __name__ == "__main__":
    try:
        if len(sys.argv) == 3 and sys.argv[1] == "tag":
            print(tag_version(sys.argv[2]))
        elif len(sys.argv) == 3 and sys.argv[1] == "stamp":
            stamp(sys.argv[2])
        else:
            raise ValueError("Usage: release-version.py tag vX.X.X | stamp Info.plist")
    except (ValueError, OSError) as error:
        sys.exit(str(error))

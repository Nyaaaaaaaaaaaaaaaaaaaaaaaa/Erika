"""Check the Flutter artifact manifest against a release's SHA256SUMS."""

import argparse
from pathlib import Path
import re


ARTIFACTS = {
    "ERIKA_ANDROID_ARM64_V8A_SHA256": "erika-flutter-android-arm64-v8a.zip",
    "ERIKA_ANDROID_ARMEABI_V7A_SHA256": "erika-flutter-android-armeabi-v7a.zip",
    "ERIKA_ANDROID_X86_64_SHA256": "erika-flutter-android-x86_64.zip",
    "ERIKA_ANDROID_X86_SHA256": "erika-flutter-android-x86.zip",
    "ERIKA_IOS_SHA256": "erika-capi-ios.zip",
    "ERIKA_TVOS_SHA256": "erika-capi-tvos.zip",
    "ERIKA_MACOS_ARM64_SHA256": "erika-capi-macos-arm64.zip",
    "ERIKA_MACOS_X64_SHA256": "erika-capi-macos-x64.zip",
    "ERIKA_MACOS_UNIVERSAL_SHA256": "erika-capi-macos-universal.zip",
    "ERIKA_WINDOWS_X64_SHA256": "erika-capi-windows-x64.zip",
    "ERIKA_WINDOWS_ARM64_SHA256": "erika-capi-windows-arm64.zip",
    "ERIKA_OPENHARMONY_ARM64_SHA256": "erika-capi-openharmony-arm64.zip",
}


def verify(manifest: str, checksums: str) -> None:
    properties = dict(
        line.strip().split("=", 1)
        for line in manifest.splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    )
    released = {}
    for line in checksums.splitlines():
        if not line.strip():
            continue
        digest, name = line.split(maxsplit=1)
        name = name.removeprefix("*")
        if name in released:
            raise ValueError(f"Duplicate release checksum: {name}")
        released[name] = digest
    for key, name in ARTIFACTS.items():
        digest = properties.get(key, "")
        if not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise ValueError(f"Missing or invalid manifest checksum: {key}")
        if released.get(name) != digest:
            raise ValueError(f"Manifest does not match release checksum: {name}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("checksums", type=Path)
    args = parser.parse_args()
    verify(args.manifest.read_text(), args.checksums.read_text())
    print(f"Verified {len(ARTIFACTS)} native artifact checksums")

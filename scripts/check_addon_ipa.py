#!/usr/bin/env python3
"""Sanity check for the Instagram X add-on IPA.

The closed tweak stays. The add-on is one extra weak load, plus its dylib,
an unmapped Xray core, and the Instagram X icon.
"""

from __future__ import annotations

import plistlib
import sys
import tempfile
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ipa_macho import dylib_loads  # noqa: E402


def fail(message: str) -> int:
    print(f"check failed: {message}", file=sys.stderr)
    return 1


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: check_addon_ipa.py <ipa>", file=sys.stderr)
        return 2
    ipa = Path(sys.argv[1])
    with zipfile.ZipFile(ipa) as archive:
        bad = archive.testzip()
        if bad:
            return fail(f"corrupt zip entry {bad}")
        names = archive.namelist()
        apps = sorted({n.split("/")[1] for n in names if n.startswith("Payload/") and n.split("/")[1].endswith(".app")})
        if len(apps) != 1:
            return fail(f"expected one .app, found {apps}")
        app = apps[0]
        info = plistlib.loads(archive.read(f"Payload/{app}/Info.plist"))
        display = info.get("CFBundleDisplayName")
        print(f"[*] display={display!r} version={info.get('CFBundleShortVersionString')!r} id={info.get('CFBundleIdentifier')!r}")
        if display != "Instagram X":
            return fail(f"display name is {display!r}")
        if info.get("CFBundleIdentifier") != "com.burbn.instagram":
            return fail("bundle id changed")
        primary = ((info.get("CFBundleIcons") or {}).get("CFBundlePrimaryIcon") or {})
        if "IXAppIcon60x60" not in (primary.get("CFBundleIconFiles") or []):
            return fail(f"icon files are {primary.get('CFBundleIconFiles')}")

        required = [
            f"Payload/{app}/Frameworks/RyukGram.dylib",
            f"Payload/{app}/Frameworks/InstagramXAddon.dylib",
            f"Payload/{app}/Frameworks/IXRayCore.dylib",
            f"Payload/{app}/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
            f"Payload/{app}/Frameworks/zxPluginsInject.dylib",
            f"Payload/{app}/RyukGram.bundle/en.lproj/Localizable.strings",
            f"Payload/{app}/libswiftIU.dylib",
            f"Payload/{app}/IXAppIcon60x60@2x.png",
            f"Payload/{app}/IXAppIcon60x60@3x.png",
        ]
        for name in required:
            try:
                entry = archive.getinfo(name)
            except KeyError:
                return fail(f"missing {name}")
            print(f"[*] present {entry.file_size:10} {name}")
        if archive.getinfo(f"Payload/{app}/Frameworks/RyukGram.dylib").file_size < 1_000_000:
            return fail("RyukGram.dylib looks truncated")
        addon_size = archive.getinfo(f"Payload/{app}/Frameworks/InstagramXAddon.dylib").file_size
        if addon_size > 16_000_000:
            return fail(f"add-on is {addon_size} bytes; Xray must not be linked into it")
        xray_size = archive.getinfo(f"Payload/{app}/Frameworks/IXRayCore.dylib").file_size
        if xray_size < 8_000_000:
            return fail(f"IXRayCore.dylib is only {xray_size} bytes")

        addon = archive.read(f"Payload/{app}/Frameworks/InstagramXAddon.dylib")
        for needle in (b"MSHookFunction", b"x_cgo_init", b"runtime.rt0_go"):
            if needle in addon:
                return fail(f"InstagramXAddon.dylib contains {needle.decode()}")
        if b"ixray_start" not in addon:
            return fail("add-on does not reference ixray_start")
        xray = archive.read(f"Payload/{app}/Frameworks/IXRayCore.dylib")
        if b"MSHookFunction" in xray:
            return fail("IXRayCore.dylib contains MSHookFunction")
        if b"ixray_start" not in xray or b"x_cgo_init" not in xray:
            return fail("IXRayCore.dylib is missing its export or the Go runtime")

        exe_name = f"Payload/{app}/{info.get('CFBundleExecutable', 'Instagram')}"
        with tempfile.TemporaryDirectory() as tmp:
            exe = Path(tmp) / "Instagram"
            exe.write_bytes(archive.read(exe_name))
            loads = [path for _kind, path in dylib_loads(exe)]
        print("[*] main binary loads:")
        for path in loads:
            if any(token in path for token in ("RyukGram", "InstagramX", "IXRay", "zxPlugins", "SCInsta", "FLEX", "Substrate")):
                print(f"    {path}")
        if loads.count(f"@rpath/InstagramXAddon.dylib") != 1:
            return fail(f"add-on load count is {loads.count('@rpath/InstagramXAddon.dylib')}")
        if not any(path.endswith("RyukGram.dylib") for path in loads):
            return fail("RyukGram load command was removed")
        if any("IXRayCore" in path for path in loads):
            return fail("IXRayCore must not be a load command")
        if any(path.endswith("SCInsta.dylib") for path in loads):
            return fail("SCInsta.dylib was injected")
    print("[*] add-on IPA checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

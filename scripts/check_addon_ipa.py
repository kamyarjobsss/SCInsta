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
from ipa_macho import MachOError, cryptids, dylib_loads, is_macho, signature_status  # noqa: E402


def fail(message: str) -> int:
    print(f"check failed: {message}", file=sys.stderr)
    return 1


def _sideload_signature(label: str, data: bytes) -> str | None:
    try:
        kind = signature_status(data)
    except MachOError as exc:
        return f"{label} signature could not be read ({exc})"
    print(f"[*] {label} signature={kind}")
    if kind not in ("unsigned", "adhoc"):
        return f"{label} is {kind}; Sideloadly needs an ldid ad-hoc signature or no signature"
    return None


def main() -> int:
    args = sys.argv[1:]
    lite = False
    if args and args[0] == "--lite":
        lite = True
        args = args[1:]
    if len(args) != 1:
        print("usage: check_addon_ipa.py [--lite] <ipa>", file=sys.stderr)
        return 2
    ipa = Path(args[0])
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
        expected_display = "Instagram X Lite" if lite else "Instagram X"
        if display != expected_display:
            return fail(f"display name is {display!r}")
        if info.get("CFBundleIdentifier") != "com.burbn.instagram":
            return fail("bundle id changed")
        primary = ((info.get("CFBundleIcons") or {}).get("CFBundlePrimaryIcon") or {})
        if "IXAppIcon60x60" not in (primary.get("CFBundleIconFiles") or []):
            return fail(f"icon files are {primary.get('CFBundleIconFiles')}")

        required = [
            f"Payload/{app}/Frameworks/RyukGram.dylib",
            f"Payload/{app}/Frameworks/InstagramXAddon.dylib",
            f"Payload/{app}/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
            f"Payload/{app}/Frameworks/zxPluginsInject.dylib",
            f"Payload/{app}/RyukGram.bundle/en.lproj/Localizable.strings",
            f"Payload/{app}/libswiftIU.dylib",
            f"Payload/{app}/IXAppIcon60x60@2x.png",
            f"Payload/{app}/IXAppIcon60x60@3x.png",
        ]
        if not lite:
            required.insert(2, f"Payload/{app}/Frameworks/IXRayCore.dylib")
        for name in required:
            try:
                entry = archive.getinfo(name)
            except KeyError:
                return fail(f"missing {name}")
            print(f"[*] present {entry.file_size:10} {name}")
        if archive.getinfo(f"Payload/{app}/Frameworks/RyukGram.dylib").file_size < 1_000_000:
            return fail("RyukGram.dylib looks truncated")
        xray_name = f"Payload/{app}/Frameworks/IXRayCore.dylib"
        addon_size = archive.getinfo(f"Payload/{app}/Frameworks/InstagramXAddon.dylib").file_size
        if addon_size > 16_000_000:
            return fail(f"add-on is {addon_size} bytes; Xray must not be linked into it")
        if lite:
            if xray_name in names:
                return fail("lite IPA contains IXRayCore.dylib")
        else:
            xray_size = archive.getinfo(xray_name).file_size
            if xray_size < 8_000_000:
                return fail(f"IXRayCore.dylib is only {xray_size} bytes")

        addon = archive.read(f"Payload/{app}/Frameworks/InstagramXAddon.dylib")
        for needle in (b"MSHookFunction", b"x_cgo_init", b"runtime.rt0_go"):
            if needle in addon:
                return fail(f"InstagramXAddon.dylib contains {needle.decode()}")
        if lite:
            if b"ixray_start" in addon:
                return fail("lite add-on references ixray_start")
            if b"IX_ADDON_LITE_BUILD" not in addon:
                return fail("lite add-on is missing IX_ADDON_LITE_BUILD")
        else:
            if b"ixray_start" not in addon:
                return fail("add-on does not reference ixray_start")
            if b"IX_ADDON_LITE_BUILD" in addon:
                return fail("full add-on contains the lite marker")
            xray = archive.read(xray_name)
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

        macho_count = 0
        for info in archive.infolist():
            if info.is_dir():
                continue
            with archive.open(info) as handle:
                prefix = handle.read(4)
            if not is_macho(prefix):
                continue
            macho_count += 1
            blob = archive.read(info.filename)
            try:
                ids = cryptids(blob)
            except MachOError as exc:
                return fail(f"could not read encryption info in {info.filename} ({exc})")
            bad_ids = [value for value in ids if value]
            if bad_ids:
                return fail(f"{info.filename} is still encrypted (cryptid {bad_ids})")
        print(f"[*] mach-o files {macho_count}, encrypted 0")
        if macho_count < 5:
            return fail(f"only found {macho_count} Mach-O files")

        signed = [
            ("main executable", archive.read(exe_name)),
            ("InstagramXAddon.dylib", addon),
        ]
        if not lite:
            signed.append(("IXRayCore.dylib", archive.read(xray_name)))
        for label, blob in signed:
            problem = _sideload_signature(label, blob)
            if problem:
                return fail(problem)
    print("[*] add-on IPA checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Sanity-check a sideload IPA produced by ./build.sh sideload.

Fails if the archive is corrupt, the main binary loads SCInsta more than
once, a required injected file is missing, or the display name was not set.
"""

from __future__ import annotations

import plistlib
import sys
import tempfile
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ipa_macho import MachOError, dylib_loads  # noqa: E402


def fail(message: str) -> int:
    print(f"[!] {message}", file=sys.stderr)
    return 1


def main() -> int:
    args = sys.argv[1:]
    lite = "--lite" in args
    args = [arg for arg in args if arg != "--lite"]
    if len(args) != 1:
        print("usage: check_sideload_ipa.py <ipa> [--lite]", file=sys.stderr)
        return 2
    ipa = Path(args[0])
    expected_display = "Instagram X Lite" if lite else "Instagram X"
    if not ipa.is_file():
        return fail(f"IPA not found: {ipa}")

    print(f"[*] {ipa.name} size {ipa.stat().st_size} bytes")
    try:
        archive = zipfile.ZipFile(ipa)
        bad = archive.testzip()
    except zipfile.BadZipFile as exc:
        return fail(f"not a zip: {exc}")
    if bad:
        return fail(f"corrupt zip entry {bad}")

    names = archive.namelist()
    if not any(n.startswith("Payload/") and n.endswith(".app/Info.plist") for n in names):
        return fail("Payload/*.app/Info.plist missing")
    app_names = sorted({n.split("/")[1] for n in names if n.startswith("Payload/") and n.split("/")[1].endswith(".app")})
    if len(app_names) != 1:
        return fail(f"expected one .app, found {app_names}")
    app_name = app_names[0]
    info_name = f"Payload/{app_name}/Info.plist"
    try:
        info = plistlib.loads(archive.read(info_name))
    except Exception as exc:
        return fail(f"Info.plist is not readable: {exc}")

    version = info.get("CFBundleShortVersionString")
    display = info.get("CFBundleDisplayName")
    executable = info.get("CFBundleExecutable")
    print(f"[*] display={display!r} version={version!r} id={info.get('CFBundleIdentifier')!r} exe={executable!r}")
    if display != expected_display:
        return fail(f"display name is {display!r}, expected {expected_display!r}")
    if not version or not executable:
        return fail("Info.plist is missing a version or executable")

    primary = ((info.get("CFBundleIcons") or {}).get("CFBundlePrimaryIcon") or {})
    if primary.get("CFBundleIconName"):
        return fail(f"asset-catalog icon name still set: {primary.get('CFBundleIconName')}")
    icon_files = primary.get("CFBundleIconFiles") or []
    if "IXAppIcon60x60" not in icon_files:
        return fail(f"primary icon files are {icon_files}")

    required = [
        f"Payload/{app_name}/Frameworks/SCInsta.dylib",
        f"Payload/{app_name}/Frameworks/FLEXing.dylib",
        f"Payload/{app_name}/Frameworks/libflex.dylib",
        f"Payload/{app_name}/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
        f"Payload/{app_name}/IXAppIcon60x60@2x.png",
        f"Payload/{app_name}/IXAppIcon60x60@3x.png",
        f"Payload/{app_name}/{executable}",
    ]
    for name in required:
        try:
            info_entry = archive.getinfo(name)
        except KeyError:
            return fail(f"missing {name}")
        print(f"[*] present {info_entry.file_size:10} {name}")

    scinsta_name = f"Payload/{app_name}/Frameworks/SCInsta.dylib"
    xray_name = f"Payload/{app_name}/Frameworks/IXRayCore.dylib"
    scinsta_size = archive.getinfo(scinsta_name).file_size
    if scinsta_size > 16_000_000:
        return fail(f"SCInsta.dylib is {scinsta_size} bytes; Xray must not be linked into the tweak")
    xray_present = xray_name in names
    if lite and xray_present:
        return fail("lite IPA still contains IXRayCore.dylib")
    if not lite:
        if not xray_present:
            return fail("full IPA is missing Frameworks/IXRayCore.dylib")
        xray_size = archive.getinfo(xray_name).file_size
        print(f"[*] present {xray_size:10} {xray_name}")
        if xray_size < 8_000_000:
            return fail(f"IXRayCore.dylib is only {xray_size} bytes")

    with tempfile.TemporaryDirectory(prefix="ix-check-") as tmp:
        work = Path(tmp)
        binary_name = f"Payload/{app_name}/{executable}"
        dylib_name = f"Payload/{app_name}/Frameworks/SCInsta.dylib"
        binary_path = work / "Instagram"
        dylib_path = work / "SCInsta.dylib"
        binary_path.write_bytes(archive.read(binary_name))
        dylib_path.write_bytes(archive.read(dylib_name))
        try:
            loads = dylib_loads(binary_path)
            tweak_loads = dylib_loads(dylib_path)
        except MachOError as exc:
            return fail(f"Mach-O parse failed: {exc}")

    print("[*] non-system loads in the main binary:")
    counts: dict[str, int] = {}
    for kind, path in loads:
        base = path.rsplit("/", 1)[-1]
        if path.startswith("/usr/lib/") or path.startswith("/System/"):
            continue
        counts[base] = counts.get(base, 0) + 1
        print(f"    {kind:22} {path}")

    for name, expect in (
        ("SCInsta.dylib", 1),
        ("FLEXing.dylib", 1),
        ("libflex.dylib", 1),
        ("zxPluginsInject.dylib", 1),
    ):
        got = counts.get(name, 0)
        if got != expect:
            return fail(f"main binary loads {name} {got} times, expected {expect}")
    if counts.get("IXRayCore.dylib", 0):
        return fail("main binary has a load command for IXRayCore.dylib; it must be dlopened later")
    if counts.get("CydiaSubstrate", 0) > 1:
        return fail("main binary loads CydiaSubstrate more than once")

    for kind, path in loads:
        if not path.startswith("@rpath/"):
            continue
        rel = f"Payload/{app_name}/Frameworks/{path[len('@rpath/'):]}"
        try:
            archive.getinfo(rel)
        except KeyError:
            return fail(f"main binary loads {path} but {rel} is missing")

    substrate = [path for _kind, path in tweak_loads if "substrate" in path.lower() or "ellekit" in path.lower()]
    print("[*] hooking runtime linked by SCInsta.dylib:")
    if not substrate:
        return fail("SCInsta.dylib does not link CydiaSubstrate or ElleKit")
    for path in substrate:
        print(f"    {path}")
        if not path.startswith("@rpath/"):
            return fail(f"hooking runtime is not @rpath: {path}")

    blob = archive.read(scinsta_name)
    # ixray_start is the dlsym name inside the full tweak. The Go runtime
    # markers are what show the core was linked into SCInsta itself.
    banned = [b"MSHookFunction", b"x_cgo_init", b"runtime.rt0_go"]
    if lite:
        banned.append(b"ixray_start")
    for needle in banned:
        if needle in blob:
            return fail(f"SCInsta.dylib still contains {needle.decode()}")
    if not lite:
        xray_blob = archive.read(xray_name)
        for needle in (b"ixray_start", b"x_cgo_init", b"runtime.rt0_go"):
            if needle not in xray_blob:
                return fail(f"IXRayCore.dylib is missing {needle.decode()}")
        if b"MSHookFunction" in xray_blob:
            return fail("IXRayCore.dylib contains MSHookFunction")

    # Extensions must not keep the old tweak, and must not load the injector twice.
    with tempfile.TemporaryDirectory(prefix="ix-check-extra-") as extra_tmp:
        extra = Path(extra_tmp) / "macho"
        for info_entry in archive.infolist():
            name = info_entry.filename
            if name == binary_name or name.endswith("/IXRayCore.dylib") or info_entry.file_size < 64 or info_entry.file_size > 80_000_000:
                continue
            if name.endswith((".png", ".car", ".json", ".plist", ".ttf", ".otf", ".metallib", ".strings")):
                continue
            with archive.open(name) as handle:
                magic = handle.read(4)
            if magic not in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"):
                continue
            extra.write_bytes(archive.read(name))
            try:
                extra_loads = dylib_loads(extra)
            except MachOError as exc:
                return fail(f"{name}: {exc}")
            extra_counts: dict[str, int] = {}
            for _kind, path in extra_loads:
                base = path.rsplit("/", 1)[-1]
                extra_counts[base] = extra_counts.get(base, 0) + 1
            for banned in ("SCInsta.dylib", "InstagramX.dylib", "FLEXing.dylib", "libflex.dylib"):
                if extra_counts.get(banned, 0):
                    return fail(f"{name} still loads {banned}")
            if extra_counts.get("zxPluginsInject.dylib", 0) > 1:
                return fail(f"{name} loads zxPluginsInject.dylib more than once")

    print("[*] IPA checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

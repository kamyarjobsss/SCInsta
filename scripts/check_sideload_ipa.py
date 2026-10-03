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
    if len(sys.argv) != 2:
        print("usage: check_sideload_ipa.py <ipa>", file=sys.stderr)
        return 2
    ipa = Path(sys.argv[1])
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
    if display != "Instagram X":
        return fail(f"display name is {display!r}, expected 'Instagram X'")
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

    scinsta_size = archive.getinfo(f"Payload/{app_name}/Frameworks/SCInsta.dylib").file_size
    if scinsta_size < 8_000_000:
        return fail(f"SCInsta.dylib is only {scinsta_size} bytes; Xray did not get linked")

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
    ):
        got = counts.get(name, 0)
        if got != expect:
            return fail(f"{name} is loaded {got} times, expected {expect}")
    injector = f"Payload/{app_name}/Frameworks/zxPluginsInject.dylib"
    injector_loads = counts.get("zxPluginsInject.dylib", 0)
    try:
        archive.getinfo(injector)
        has_injector = True
    except KeyError:
        has_injector = False
    if has_injector and injector_loads != 1:
        return fail(f"zxPluginsInject.dylib is present but loaded {injector_loads} times")
    if not has_injector and injector_loads != 0:
        return fail("main binary loads zxPluginsInject.dylib but the file is missing")
    if counts.get("CydiaSubstrate", 0) > 1:
        return fail("main binary loads CydiaSubstrate more than once")

    substrate = [path for _kind, path in tweak_loads if "substrate" in path.lower() or "ellekit" in path.lower()]
    print("[*] hooking runtime linked by SCInsta.dylib:")
    if not substrate:
        return fail("SCInsta.dylib does not link CydiaSubstrate or ElleKit")
    for path in substrate:
        print(f"    {path}")
        if not path.startswith("@rpath/"):
            return fail(f"hooking runtime is not @rpath: {path}")

    blob = archive.read(f"Payload/{app_name}/Frameworks/SCInsta.dylib")
    if b"ixray_start" not in blob and b"xray-core" not in blob:
        return fail("SCInsta.dylib has no Xray marker (ixray_start / xray-core)")

    print("[*] IPA checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

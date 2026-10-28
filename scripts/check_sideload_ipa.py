#!/usr/bin/env python3
"""Sanity-check a sideload IPA produced by ./build.sh sideload.

Fails if the archive is corrupt, the main binary loads SCInsta more than
once, a required injected file is missing, or the display name was not set.
"""

from __future__ import annotations

import plistlib
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ipa_macho import MachOError, bind_ordinal_errors, constructors_follow_framework, dylib_loads  # noqa: E402
from macho_closure import (  # noqa: E402
    missing_loads,
    resolve_load_paths,
    structure_errors,
    undefined_from_nm,
    unresolved_symbols,
)


def fail(message: str) -> int:
    print(f"[!] {message}", file=sys.stderr)
    return 1


def main() -> int:
    raw = sys.argv[1:]
    lite = "--lite" in raw
    original_ipa: Path | None = None
    sdk: Path | None = None
    args: list[str] = []
    index = 0
    while index < len(raw):
        if raw[index] == "--lite":
            index += 1
            continue
        if raw[index] == "--base" and index + 1 < len(raw):
            original_ipa = Path(raw[index + 1])
            index += 2
            continue
        if raw[index] == "--sdk" and index + 1 < len(raw):
            sdk = Path(raw[index + 1])
            index += 2
            continue
        args.append(raw[index])
        index += 1
    if len(args) != 1 or original_ipa is None:
        print("usage: check_sideload_ipa.py <ipa> --base <original.ipa> [--sdk <sdk>] [--lite]", file=sys.stderr)
        return 2
    if sdk is None:
        sdk = Path("/home/ubuntu/theos/sdks/iPhoneOS16.5.sdk")
    if not sdk.is_dir():
        return fail(f"iOS SDK not found: {sdk}")
    nm = shutil.which("llvm-nm") or "/home/ubuntu/theos/toolchain/linux/iphone/bin/llvm-nm"
    ldid = shutil.which("ldid") or "/home/ubuntu/theos/toolchain/linux/iphone/bin/ldid"
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
    ats = info.get("NSAppTransportSecurity") or {}
    if ats.get("NSAllowsArbitraryLoads") is not True:
        return fail("NSAllowsArbitraryLoads is not set; IP-literal HTTPS can fail before the pin check")

    required = [
        f"Payload/{app_name}/Frameworks/SCInsta.dylib",
        f"Payload/{app_name}/Frameworks/FLEXing.dylib",
        f"Payload/{app_name}/Frameworks/libflex.dylib",
        f"Payload/{app_name}/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
        f"Payload/{app_name}/IXAppIcon60x60@2x.png",
        f"Payload/{app_name}/IXAppIcon60x60@3x.png",
        f"Payload/{app_name}/InstagramX.bundle/en.lproj/Localizable.strings",
        f"Payload/{app_name}/{executable}",
    ]
    for name in required:
        try:
            info_entry = archive.getinfo(name)
        except KeyError:
            return fail(f"missing {name}")
        print(f"[*] present {info_entry.file_size:10} {name}")

    for name in names:
        if name.endswith("/RyukGram.dylib") or "/RyukGram.bundle/" in name or name.rstrip("/").endswith("/RyukGram.bundle"):
            return fail(f"closed RyukGram payload still present: {name}")

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
            patched_binary = binary_path.read_bytes()
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

    if not constructors_follow_framework([path for _kind, path in loads]):
        return fail(
            "SCInsta and zxPluginsInject must load after FBSharedFramework; "
            "initializing them first crashed 2.4.9 at launch"
        )
    if not original_ipa.is_file():
        return fail(f"original IPA not found: {original_ipa}")
    try:
        with zipfile.ZipFile(original_ipa) as original_archive:
            original_binary = original_archive.read(binary_name)
    except KeyError:
        return fail(f"original IPA has no {binary_name}")
    except zipfile.BadZipFile as exc:
        return fail(f"original IPA is not a zip: {exc}")
    try:
        mismatches = bind_ordinal_errors(original_binary, patched_binary)
    except MachOError as exc:
        return fail(f"bind ordinal check failed: {exc}")
    if mismatches:
        return fail(
            "main-binary binds no longer resolve to the original libraries "
            f"({mismatches[0]}). A load command was inserted mid-list; "
            "2.4.13 crashed in dyld looking for _swift_bridgeObjectRelease."
        )
    print("[*] main-binary bind ordinals match the original IPA")
    if counts.get("IXInstallGuard.dylib", 0):
        return fail("IXInstallGuard.dylib is a load command; inserting it shifts bind ordinals")
    layout = structure_errors(patched_binary)
    if layout:
        return fail(f"main binary is not codesign-able: {layout[0]}")
    absent = missing_loads(set(names), loads, patched_binary, binary_name, f"Payload/{app_name}", sdk)
    if absent:
        return fail(f"main binary loads {absent[0]} but that file is not in the IPA")
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

    link_targets = [
        binary_name,
        f"Payload/{app_name}/Frameworks/SCInsta.dylib",
        f"Payload/{app_name}/Frameworks/FLEXing.dylib",
        f"Payload/{app_name}/Frameworks/libflex.dylib",
        f"Payload/{app_name}/Frameworks/zxPluginsInject.dylib",
        f"Payload/{app_name}/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
    ]
    name_set = set(names)
    with tempfile.TemporaryDirectory(prefix="ix-link-") as link_tmp:
        root = Path(link_tmp)
        for member in link_targets:
            if member not in name_set:
                return fail(f"missing {member}")
            data = archive.read(member)
            layout = structure_errors(data)
            if layout:
                return fail(f"{member} is not codesign-able: {layout[0]}")
            blob_path = root / Path(member).name
            blob_path.write_bytes(data)
            signed = root / f"signed-{blob_path.name}"
            signed.write_bytes(data)
            result = subprocess.run([ldid, "-S", str(signed)], capture_output=True)
            if result.returncode != 0:
                detail = (result.stderr or result.stdout or b"").decode("utf-8", "replace")[:200]
                return fail(f"ldid cannot sign {member}: {detail}")
            try:
                member_loads = dylib_loads(blob_path)
            except MachOError as exc:
                return fail(f"{member}: {exc}")
            absent = missing_loads(name_set, member_loads, data, member, f"Payload/{app_name}", sdk)
            if absent:
                return fail(f"{member} loads {absent[0]} but that file is not in the IPA")
            if member == binary_name:
                continue
            try:
                undef = undefined_from_nm(nm, blob_path)
            except MachOError as exc:
                return fail(f"{member}: {exc}")
            exports: dict[str, set[str]] = {}
            for _kind, dep in member_loads:
                candidates = resolve_load_paths(dep, member, f"Payload/{app_name}", ["@executable_path/Frameworks", "@loader_path"])
                member_dep = next((item for item in candidates if item in name_set), None)
                if not member_dep or member_dep not in name_set or dep in exports:
                    continue
                dep_path = root / Path(member_dep).name
                if not dep_path.exists():
                    dep_path.write_bytes(archive.read(member_dep))
                defined = subprocess.run(
                    [nm, "-defined-only", "-extern-only", str(dep_path)],
                    capture_output=True,
                    text=True,
                )
                names_found: set[str] = set()
                for line in defined.stdout.splitlines():
                    parts = line.split()
                    if parts:
                        names_found.add(parts[-1])
                exports[dep] = names_found
            missing_syms = unresolved_symbols(undef, [path for _kind, path in member_loads], sdk, exports)
            if missing_syms:
                return fail(f"{member} has an unresolved symbol {missing_syms[0]}")
            print(f"[*] {Path(member).name}: {len(undef)} undefined symbols resolve")

    print("[*] IPA checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

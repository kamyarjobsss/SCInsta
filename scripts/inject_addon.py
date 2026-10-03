#!/usr/bin/env python3
"""Add Instagram X Add-on to an already-tweaked Instagram IPA.

Keeps every existing file, including RyukGram.dylib and RyukGram.bundle.
Adds the add-on dylib, one weak load command on the main executable, the
app icon, and the display name. Xray, when passed, is copied with no load
command so dyld does not map it at launch.
"""

from __future__ import annotations

import plistlib
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ipa_macho import (  # noqa: E402
    LC_LOAD_WEAK_DYLIB,
    MachOError,
    header,
    iter_commands,
    iter_slices,
)

ROOT = Path(__file__).resolve().parents[1]
ICONS = ROOT / "resources" / "AppIcon"
ADDON_LOAD = "@rpath/InstagramXAddon.dylib"


def _first_text_section(data: bytes, start: int) -> int:
    ncmds, sizeofcmds, cmds_off = header(data, start)
    pos = 0
    first = None
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, cmds_off + pos)
        if cmd == 0x19:  # LC_SEGMENT_64
            seg = data[cmds_off + pos + 8 : cmds_off + pos + 24].split(b"\x00", 1)[0]
            nsects = struct.unpack_from("<I", data, cmds_off + pos + 64)[0]
            base = cmds_off + pos + 72
            if seg == b"__TEXT":
                for index in range(nsects):
                    sec = data[base + index * 80 : base + (index + 1) * 80]
                    offset = struct.unpack_from("<I", sec, 48)[0]
                    if offset and (first is None or offset < first):
                        first = offset
        pos += cmdsize
        if pos > sizeofcmds:
            break
    if not first:
        raise MachOError("no __TEXT section offset")
    return first


def add_weak_load(path: Path, install_name: str) -> bool:
    """Insert LC_LOAD_WEAK_DYLIB into header slack. Returns True if added."""
    data = bytearray(path.read_bytes())
    added = False
    for start, _size in iter_slices(data):
        if struct.unpack_from("<I", data, start)[0] != 0xFEEDFACF:
            continue
        for _i, cmd, blob in iter_commands(data, start):
            if install_name.encode() in blob and cmd in (LC_LOAD_WEAK_DYLIB, 0xC, 0x18):
                print(f"[*] {install_name} is already loaded")
                return False
        ncmds, sizeofcmds, cmds_off = header(data, start)
        name = install_name.encode("utf-8") + b"\x00"
        cmdsize = (24 + len(name) + 7) & ~7
        slack_end = start + _first_text_section(data, start)
        write_at = cmds_off + sizeofcmds
        if write_at + cmdsize > slack_end:
            raise MachOError(
                f"no room for a load command ({write_at + cmdsize:#x} > {slack_end:#x})"
            )
        blob = struct.pack("<IIIIII", LC_LOAD_WEAK_DYLIB, cmdsize, 24, 0, 0x00010000, 0x00010000)
        blob += name
        blob = blob.ljust(cmdsize, b"\x00")
        data[write_at : write_at + cmdsize] = blob
        struct.pack_into("<II", data, start + 16, ncmds + 1, sizeofcmds + cmdsize)
        added = True
    if not added:
        raise MachOError("no 64-bit slice to patch")
    path.write_bytes(data)
    # The walk must still parse, or the header is corrupt.
    for start, _size in iter_slices(data):
        if struct.unpack_from("<I", data, start)[0] == 0xFEEDFACF:
            list(iter_commands(data, start))
    return True


def _zip_crc(ipa: Path, suffix: str) -> int | None:
    with zipfile.ZipFile(ipa) as archive:
        for info in archive.infolist():
            if info.filename.endswith(suffix):
                return info.CRC
    return None


def _run(cmd: list[str], cwd: Path | None = None) -> None:
    subprocess.run(cmd, cwd=cwd, check=True)


def _parse_args(argv: list[str]) -> tuple[Path, Path, Path | None, str]:
    display = "Instagram X"
    positionals: list[str] = []
    index = 0
    while index < len(argv):
        if argv[index] == "--display":
            if index + 1 >= len(argv):
                raise SystemExit("usage: inject_addon.py <ipa> <InstagramXAddon.dylib> [IXRayCore.dylib] [--display NAME]")
            display = argv[index + 1]
            index += 2
            continue
        positionals.append(argv[index])
        index += 1
    if len(positionals) < 2:
        raise SystemExit("usage: inject_addon.py <ipa> <InstagramXAddon.dylib> [IXRayCore.dylib] [--display NAME]")
    xray = Path(positionals[2]).resolve() if len(positionals) > 2 else None
    return Path(positionals[0]).resolve(), Path(positionals[1]).resolve(), xray, display


def main() -> int:
    try:
        ipa, dylib, xray, display = _parse_args(sys.argv[1:])
    except SystemExit as exc:
        print(exc, file=sys.stderr)
        return 2
    if not ipa.is_file() or not dylib.is_file():
        print("IPA or add-on dylib is missing", file=sys.stderr)
        return 1

    ryuk_crc = _zip_crc(ipa, "/Frameworks/RyukGram.dylib")
    if ryuk_crc is None:
        print("RyukGram.dylib is not in the base IPA", file=sys.stderr)
        return 1

    with tempfile.TemporaryDirectory(prefix="ix-addon-") as tmp:
        work = Path(tmp)
        print(f"[*] extracting {ipa.name}")
        _run(["unzip", "-q", str(ipa), "-d", str(work)])
        apps = list((work / "Payload").glob("*.app"))
        if len(apps) != 1:
            print(f"expected one .app, found {apps}", file=sys.stderr)
            return 1
        app = apps[0]
        bundle = app / "RyukGram.bundle"
        ryuk = app / "Frameworks" / "RyukGram.dylib"
        if not ryuk.is_file() or not bundle.is_dir():
            print("refusing to continue: RyukGram.dylib or RyukGram.bundle is missing", file=sys.stderr)
            return 1

        exe = app / "Instagram"
        if not exe.is_file():
            info = plistlib.loads((app / "Info.plist").read_bytes())
            exe = app / info.get("CFBundleExecutable", "Instagram")
        print(f"[*] adding {ADDON_LOAD}")
        add_weak_load(exe, ADDON_LOAD)
        exe.chmod(exe.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

        dest = app / "Frameworks" / "InstagramXAddon.dylib"
        shutil.copy2(dylib, dest)
        dest.chmod(0o755)
        if xray and xray.is_file():
            xdest = app / "Frameworks" / "IXRayCore.dylib"
            shutil.copy2(xray, xdest)
            xdest.chmod(0o755)
            print(f"[*] embedded {xdest.name} with no load command")

        info_path = app / "Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info["CFBundleDisplayName"] = display
        info["CFBundleName"] = display
        icons = info.get("CFBundleIcons") or {}
        primary = icons.get("CFBundlePrimaryIcon") or {}
        primary.pop("CFBundleIconName", None)
        primary["CFBundleIconFiles"] = ["IXAppIcon60x60"]
        icons["CFBundlePrimaryIcon"] = primary
        info["CFBundleIcons"] = icons
        info_path.write_bytes(plistlib.dumps(info))
        for icon in ICONS.glob("IXAppIcon*.png"):
            shutil.copy2(icon, app / icon.name)

        if not shutil.which("ldid"):
            print("ldid is required so Sideloadly receives an ad-hoc signature", file=sys.stderr)
            return 1
        print("[*] ad-hoc signing the changed binaries with ldid -S")
        _run(["ldid", "-S", str(exe)])
        _run(["ldid", "-S", str(dest)])
        if xray and xray.is_file():
            _run(["ldid", "-S", str(app / "Frameworks" / "IXRayCore.dylib")])

        rels = [
            exe.relative_to(work).as_posix(),
            info_path.relative_to(work).as_posix(),
            dest.relative_to(work).as_posix(),
        ]
        if xray and xray.is_file():
            rels.append((app / "Frameworks" / "IXRayCore.dylib").relative_to(work).as_posix())
        for icon in ICONS.glob("IXAppIcon*.png"):
            rels.append((app / icon.name).relative_to(work).as_posix())
        print(f"[*] updating {len(rels)} zip entries")
        _run(["zip", "-q", str(ipa), *rels], cwd=work)

    if _zip_crc(ipa, "/Frameworks/RyukGram.dylib") != ryuk_crc:
        print("RyukGram.dylib bytes changed", file=sys.stderr)
        return 1
    print(f"[*] RyukGram.dylib unchanged (crc {ryuk_crc:#x})")
    print(f"[*] add-on injected into {ipa}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

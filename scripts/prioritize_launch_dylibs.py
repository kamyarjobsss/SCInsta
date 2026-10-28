#!/usr/bin/env python3
"""Initialize zxPluginsInject and SCInsta before FBSharedFramework.

The sideload has no app-group entitlement. Session suites and the group
cookie jar have to be redirected from the tweak constructor, which only
runs first when those dylibs precede FBSharedFramework in the main binary.
"""

from __future__ import annotations

import plistlib
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

from ipa_macho import MachOError, prioritize_dylibs

FIRST = ["zxPluginsInject.dylib", "SCInsta.dylib"]


def _executable(archive: zipfile.ZipFile) -> str:
    infos = [
        name
        for name in archive.namelist()
        if name.startswith("Payload/") and name.endswith(".app/Info.plist") and name.count("/") == 2
    ]
    if len(infos) != 1:
        raise MachOError(f"expected one app Info.plist, found {infos}")
    info = plistlib.loads(archive.read(infos[0]))
    exe = info.get("CFBundleExecutable")
    if not isinstance(exe, str) or not exe:
        raise MachOError("CFBundleExecutable is missing")
    member = infos[0].rsplit("/", 1)[0] + "/" + exe
    if member not in archive.namelist():
        raise MachOError(f"executable {member} is not in the IPA")
    return member


def _resign(binary: Path) -> None:
    ldid = shutil.which("ldid")
    if not ldid:
        print("ldid not found; the next sideload resign will cover the reordered header")
        return
    dumped = subprocess.run([ldid, "-e", str(binary)], capture_output=True)
    entitlements = dumped.stdout or b""
    if b"<plist" in entitlements[:800] or b"<dict>" in entitlements[:800]:
        ent = binary.with_suffix(".entitlements")
        ent.write_bytes(entitlements)
        result = subprocess.run([ldid, f"-S{ent}", str(binary)], capture_output=True)
        ent.unlink(missing_ok=True)
    else:
        result = subprocess.run([ldid, "-S", str(binary)], capture_output=True)
    if result.returncode != 0:
        sys.stderr.write((result.stderr or b"").decode("utf-8", "replace"))
        raise MachOError(f"ldid failed with status {result.returncode}")


def prioritize_ipa(ipa: Path, first: list[str] | None = None) -> list[str]:
    names = first or FIRST
    with zipfile.ZipFile(ipa) as archive:
        member = _executable(archive)
        payload = archive.read(member)
        entries = archive.infolist()
    binary = ipa.with_suffix(".launch-dylib")
    binary.write_bytes(payload)
    try:
        order = prioritize_dylibs(binary, names)
        _resign(binary)
        rewritten = binary.read_bytes()
    finally:
        binary.unlink(missing_ok=True)
    tmp = ipa.with_suffix(".reordered.ipa")
    with zipfile.ZipFile(ipa) as src, zipfile.ZipFile(tmp, "w", allowZip64=True) as dst:
        for info in entries:
            data = rewritten if info.filename == member else src.read(info.filename)
            fresh = zipfile.ZipInfo(filename=info.filename, date_time=info.date_time)
            fresh.compress_type = info.compress_type
            fresh.external_attr = info.external_attr
            fresh.create_system = info.create_system
            fresh.flag_bits = info.flag_bits
            dst.writestr(fresh, data)
    tmp.replace(ipa)
    print(f"launch dylibs ordered before FBSharedFramework in {member}")
    interesting = [name for name in order if name in names or name == "FBSharedFramework"]
    print(" ".join(interesting))
    return order


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: prioritize_launch_dylibs.py <ipa> <dylib> [dylib...]", file=sys.stderr)
        return 2
    ipa = Path(sys.argv[1])
    if not ipa.is_file():
        print(f"IPA not found: {ipa}", file=sys.stderr)
        return 1
    try:
        prioritize_ipa(ipa, sys.argv[2:])
    except (MachOError, OSError, zipfile.BadZipFile) as exc:
        print(f"could not prioritize launch dylibs: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

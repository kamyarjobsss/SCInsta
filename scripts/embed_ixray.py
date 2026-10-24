#!/usr/bin/env python3
"""Copy IXRayCore.dylib into Payload/*.app/Frameworks without a load command.

dyld must not map the Go runtime at launch. The tweak dlopens this file
only after the user turns the VPN on.
"""

from __future__ import annotations

import sys
import zipfile
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: embed_ixray.py <ipa> <IXRayCore.dylib>", file=sys.stderr)
        return 2
    ipa = Path(sys.argv[1])
    dylib = Path(sys.argv[2])
    if not ipa.is_file():
        print(f"IPA not found: {ipa}", file=sys.stderr)
        return 1
    if not dylib.is_file() or dylib.stat().st_size < 1_000_000:
        print(f"Xray dylib missing or too small: {dylib}", file=sys.stderr)
        return 1

    with zipfile.ZipFile(ipa) as archive:
        apps = sorted({name.split("/")[1] for name in archive.namelist() if name.startswith("Payload/") and name.split("/")[1].endswith(".app")})
    if len(apps) != 1:
        print(f"expected one .app, found {apps}", file=sys.stderr)
        return 1
    dest = f"Payload/{apps[0]}/Frameworks/{dylib.name}"

    with zipfile.ZipFile(ipa, "a") as archive:
        if dest in archive.namelist():
            print(f"already present: {dest}", file=sys.stderr)
            return 1
        info = zipfile.ZipInfo(dest)
        info.compress_type = zipfile.ZIP_DEFLATED
        info.create_system = 3
        info.external_attr = 0x81ED0000
        archive.writestr(info, dylib.read_bytes())
    print(f"embedded {dest} ({dylib.stat().st_size} bytes) with no load command")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

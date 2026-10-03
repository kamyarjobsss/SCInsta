#!/usr/bin/env python3
"""Set the sideloaded IPA's display name, icon, and optional bundle id.

Run after cyan injects the tweak and before ipapatch resigns the archive.
"""

import os
import plistlib
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ICONS = ROOT / "resources" / "AppIcon"


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: brand_ipa.py <ipa> [display name]", file=sys.stderr)
        return 2
    ipa = Path(sys.argv[1])
    display = sys.argv[2] if len(sys.argv) > 2 else os.environ.get("IX_DISPLAY_NAME", "Instagram X")
    bundle_id = os.environ.get("IX_BUNDLE_ID", "").strip()
    if not ipa.is_file():
        print(f"IPA not found: {ipa}", file=sys.stderr)
        return 1

    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        with zipfile.ZipFile(ipa) as archive:
            archive.extractall(work)
        apps = list((work / "Payload").glob("*.app"))
        if len(apps) != 1:
            print(f"Expected one .app in Payload, found {apps}", file=sys.stderr)
            return 1
        app = apps[0]
        info_path = app / "Info.plist"
        with info_path.open("rb") as handle:
            info = plistlib.load(handle)
        old_id = info.get("CFBundleIdentifier", "")

        info["CFBundleDisplayName"] = display
        info["CFBundleName"] = display
        icons = info.get("CFBundleIcons") or {}
        primary = icons.get("CFBundlePrimaryIcon") or {}
        primary.pop("CFBundleIconName", None)
        primary["CFBundleIconFiles"] = ["IXAppIcon60x60"]
        icons["CFBundlePrimaryIcon"] = primary
        info["CFBundleIcons"] = icons
        ipad = info.get("CFBundleIcons~ipad")
        if isinstance(ipad, dict):
            ipad_primary = ipad.get("CFBundlePrimaryIcon") or {}
            ipad_primary.pop("CFBundleIconName", None)
            ipad_primary["CFBundleIconFiles"] = ["IXAppIcon60x60"]
            ipad["CFBundlePrimaryIcon"] = ipad_primary
            info["CFBundleIcons~ipad"] = ipad

        if bundle_id and old_id and bundle_id != old_id:
            info["CFBundleIdentifier"] = bundle_id
            _retarget_extensions(app, old_id, bundle_id)

        with info_path.open("wb") as handle:
            plistlib.dump(info, handle)

        for icon in ICONS.glob("*.png"):
            shutil.copy2(icon, app / icon.name)

        rebuilt = work / "branded.ipa"
        with zipfile.ZipFile(rebuilt, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for path in work.rglob("*"):
                if path == rebuilt or not path.is_file():
                    continue
                archive.write(path, path.relative_to(work).as_posix())
        shutil.copy2(rebuilt, ipa)

    print(f"Branded {ipa.name} as {display}" + (f" ({bundle_id})" if bundle_id else ""))
    return 0


def _retarget_extensions(app: Path, old_id: str, new_id: str) -> None:
    for plist_path in app.rglob("Info.plist"):
        try:
            with plist_path.open("rb") as handle:
                data = plistlib.load(handle)
        except Exception:
            continue
        changed = False
        ident = data.get("CFBundleIdentifier")
        if isinstance(ident, str) and (ident == old_id or ident.startswith(old_id + ".")):
            data["CFBundleIdentifier"] = new_id + ident[len(old_id):]
            changed = True
        if changed:
            with plist_path.open("wb") as handle:
                plistlib.dump(data, handle)


if __name__ == "__main__":
    raise SystemExit(main())

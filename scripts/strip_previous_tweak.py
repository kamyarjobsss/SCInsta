#!/usr/bin/env python3
"""Remove a previous SCInsta/FLEX injection from an IPA before cyan runs again.

cyan adds a new LC_LOAD_WEAK_DYLIB every time and does not delete the old one.
Feeding it an IPA that already contains SCInsta v1.1.1 would load the tweak
twice. This strips those load commands and deletes the old files, then updates
only those entries in the zip so the rest of the archive is left alone.

Kept on purpose:
  CydiaSubstrate.framework  — the hooking runtime the tweak links. cyan replaces
                              the existing copy instead of adding a second one.
  Instagram's own frameworks (FBSharedFramework, Spotify, ffmpeg, GoogleCast)

zxPluginsInject.dylib is removed, including from app extensions. ipapatch
refuses to run when that load command is already present, and it installs a
fresh copy itself.
"""

from __future__ import annotations

import plistlib
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ipa_macho import MachOError, strip_dylibs  # noqa: E402

# Re-injected by ./build.sh sideload via cyan. Anything else stays.
STRIP_FILES = {
    "SCInsta.dylib",
    "InstagramX.dylib",
    "RyukGram.dylib",
    "FLEXing.dylib",
    "libflex.dylib",
    "zxPluginsInject.dylib",
}

# Closed-source bundle shipped inside the 436 base IPA. libswiftIU.dylib and
# libmobile_first_frame_pipeline.framework are not in this set and stay.
STRIP_DIRS = {"RyukGram.bundle"}

SKIP_SUFFIXES = {
    ".png", ".jpg", ".jpeg", ".car", ".json", ".ttf", ".otf", ".metallib",
    ".strings", ".plist", ".mp4", ".m4a", ".aac", ".mp3", ".svg", ".bin",
    ".hbc", ".js", ".txt", ".html", ".css", ".wav", ".caf", ".ahap",
}


def _is_macho(path: Path) -> bool:
    try:
        with path.open("rb") as handle:
            magic = handle.read(4)
    except OSError:
        return False
    return magic in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xfe\xed\xfa\xcf")


def _run(cmd: list[str], cwd: Path | None = None) -> None:
    subprocess.run(cmd, cwd=cwd, check=True)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: strip_previous_tweak.py <ipa>", file=sys.stderr)
        return 2
    ipa = Path(sys.argv[1]).resolve()
    if not ipa.is_file():
        print(f"IPA not found: {ipa}", file=sys.stderr)
        return 1

    with tempfile.TemporaryDirectory(prefix="ix-strip-") as tmp:
        work = Path(tmp)
        print(f"[*] extracting {ipa.name}")
        _run(["unzip", "-q", str(ipa), "-d", str(work)])
        apps = list((work / "Payload").glob("*.app"))
        if len(apps) != 1:
            print(f"Expected one .app, found {apps}", file=sys.stderr)
            return 1
        app = apps[0]
        info = plistlib.loads((app / "Info.plist").read_bytes())
        print(
            f"[*] {info.get('CFBundleDisplayName') or info.get('CFBundleName')} "
            f"{info.get('CFBundleShortVersionString')} ({info.get('CFBundleIdentifier')})"
        )

        removed_loads: list[str] = []
        changed: list[Path] = []
        for path in app.rglob("*"):
            if not path.is_file() or path.name in STRIP_FILES or path.suffix.lower() in SKIP_SUFFIXES:
                continue
            if not _is_macho(path):
                continue
            try:
                removed = strip_dylibs(path, STRIP_FILES)
            except MachOError as exc:
                print(f"[!] {path.relative_to(app)}: {exc}", file=sys.stderr)
                return 1
            if not removed:
                continue
            path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
            changed.append(path)
            for item in removed:
                removed_loads.append(f"{path.relative_to(app)} <- {item}")

        removed_files: list[Path] = []
        for name in sorted(STRIP_FILES):
            for path in app.rglob(name):
                if path.is_file() or path.is_symlink():
                    removed_files.append(path)
        for path in list(app.rglob("*")):
            if path.is_dir() and path.name in STRIP_DIRS:
                for child in path.rglob("*"):
                    if child.is_file() or child.is_symlink():
                        removed_files.append(child)

        if not removed_loads and not removed_files:
            print("[*] no previous SCInsta/FLEX injection found")
            return 0

        print("[*] removed load commands:")
        for item in removed_loads:
            print(f"    {item}")
        print("[*] removed files:")
        for path in removed_files:
            print(f"    {path.relative_to(app)}")

        kept = []
        frameworks = app / "Frameworks"
        if frameworks.is_dir():
            for child in sorted(frameworks.iterdir()):
                if child.name not in STRIP_FILES:
                    kept.append(child.name)
        print("[*] frameworks kept: " + ", ".join(kept))

        for path in changed:
            rel = path.relative_to(work).as_posix()
            print(f"[*] updating {rel}")
            _run(["zip", "-q", str(ipa), rel], cwd=work)
        pending: list[str] = []

        def flush_deletes() -> None:
            if not pending:
                return
            print(f"[*] deleting {len(pending)} zip entries")
            _run(["zip", "-q", "-d", str(ipa), *pending])
            pending.clear()

        for path in removed_files:
            pending.append(path.relative_to(work).as_posix())
            if len(pending) >= 40:
                flush_deletes()
        flush_deletes()

    print(f"[*] stripped IPA written to {ipa}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

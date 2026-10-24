#!/usr/bin/env python3
"""Load-command order: session hooks must initialize before FBSharedFramework."""

import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from ipa_macho import LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, reorder_load_commands


def fake_dylib(cmd: int, path: str) -> tuple[int, bytes]:
    name = path.encode() + b"\x00"
    size = 24 + len(name)
    if size % 8:
        name += b"\x00" * (8 - (size % 8))
        size = 24 + len(name)
    blob = struct.pack("<IIIIII", cmd, size, 24, 2, 0x10000, 0x10000) + name
    return cmd, blob


def bases(commands):
    out = []
    for cmd, blob in commands:
        end = blob.find(b"\x00", 24)
        if cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB):
            out.append(blob[24:end].decode().rsplit("/", 1)[-1])
    return out


def main() -> int:
    segment = (0x19, struct.pack("<II", 0x19, 8))
    commands = [
        segment,
        fake_dylib(LC_LOAD_DYLIB, "/usr/lib/libSystem.B.dylib"),
        fake_dylib(LC_LOAD_DYLIB, "@rpath/FBSharedFramework.framework/FBSharedFramework"),
        fake_dylib(LC_LOAD_WEAK_DYLIB, "@rpath/SCInsta.dylib"),
        fake_dylib(LC_LOAD_WEAK_DYLIB, "@rpath/zxPluginsInject.dylib"),
        fake_dylib(LC_LOAD_DYLIB, "@rpath/FLEXing.dylib"),
    ]
    ordered = reorder_load_commands(commands, ["zxPluginsInject.dylib", "SCInsta.dylib"])
    got = bases(ordered)
    want = ["libSystem.B.dylib", "zxPluginsInject.dylib", "SCInsta.dylib", "FBSharedFramework", "FLEXing.dylib"]
    if got != want:
        print(f"FAIL order got {got} want {want}")
        return 1
    if sum(len(blob) for _cmd, blob in ordered) != sum(len(blob) for _cmd, blob in commands):
        print("FAIL reordered commands changed size")
        return 1
    again = reorder_load_commands(ordered, ["zxPluginsInject.dylib", "SCInsta.dylib"])
    if bases(again) != want:
        print("FAIL second reorder moved commands")
        return 1
    print("ok dylib order")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""A new load command must be appended. Inserting one shifts bind ordinals."""

import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from ipa_macho import bind_ordinal_errors


def _dylib(path: str) -> bytes:
    text = path.encode() + b"\x00"
    size = (24 + len(text) + 7) & ~7
    blob = struct.pack("<IIIIII", 0xC, size, 24, 0, 0x10000, 0x10000) + text
    return blob + b"\x00" * (size - len(blob))


def _image(libraries: list[str], ordinal: int) -> bytes:
    commands = b"".join(_dylib(path) for path in libraries)
    symbol = b"_swift_bridgeObjectRelease\x00"
    chained = struct.pack("<7I", 0, 0, 28, 32, 1, 1, 0)
    chained += struct.pack("<I", ordinal & 0xFF)
    chained += symbol
    sizeofcmds = len(commands) + 16
    header = struct.pack("<8I", 0xFEEDFACF, 0x0100000C, 0, 2, len(libraries) + 1, sizeofcmds, 0, 0)
    fixups = struct.pack("<IIII", 0x80000034, 16, 32 + sizeofcmds, len(chained))
    return header + commands + fixups + chained


def main() -> int:
    callkit = "/usr/lib/swift/libswiftCallKit.dylib"
    framework = "@rpath/FBSharedFramework.framework/FBSharedFramework"
    guard = "@rpath/IXInstallGuard.dylib"
    original = _image([callkit, framework], 1)
    appended = _image([callkit, framework, guard], 1)
    inserted = _image([guard, callkit, framework], 1)
    if bind_ordinal_errors(original, appended):
        print("FAIL appending a dylib must keep _swift_bridgeObjectRelease on libswiftCallKit")
        return 1
    shifted = bind_ordinal_errors(original, inserted)
    if not shifted:
        print("FAIL inserting a dylib mid-list must be rejected")
        return 1
    if not any("_swift_bridgeObjectRelease" in item for item in shifted):
        print("FAIL the shifted symbol should be named")
        print(shifted)
        return 1
    print("ok bind ordinals")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

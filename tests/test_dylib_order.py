#!/usr/bin/env python3
"""Constructors must follow FBSharedFramework. The 2.4.9 order crashed."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from ipa_macho import constructors_follow_framework


def main() -> int:
    launched = [
        "/usr/lib/libSystem.B.dylib",
        "@rpath/FBSharedFramework.framework/FBSharedFramework",
        "@rpath/SCInsta.dylib",
        "@rpath/FLEXing.dylib",
        "@rpath/libflex.dylib",
        "@rpath/zxPluginsInject.dylib",
    ]
    crashed = [
        "/usr/lib/libSystem.B.dylib",
        "@rpath/zxPluginsInject.dylib",
        "@rpath/SCInsta.dylib",
        "@rpath/FBSharedFramework.framework/FBSharedFramework",
        "@rpath/FLEXing.dylib",
    ]
    if not constructors_follow_framework(launched):
        print("FAIL 2.4.8 order should launch")
        return 1
    if constructors_follow_framework(crashed):
        print("FAIL 2.4.9 order crashed and must stay rejected")
        return 1
    if constructors_follow_framework(["SCInsta.dylib", "FBSharedFramework"]):
        print("FAIL missing injector")
        return 1
    print("ok dylib order")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

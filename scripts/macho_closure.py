"""Resolve Mach-O load paths and undefined symbols against an iOS SDK."""

from __future__ import annotations

import re
import struct
import subprocess
from pathlib import Path

from ipa_macho import MachOError, iter_commands

LC_SEGMENT_64 = 0x19
LC_CODE_SIGNATURE = 0x1D


def structure_errors(data: bytes) -> list[str]:
    """Load-command and code-signature layout a signer can rewrite."""

    errors: list[str] = []
    if len(data) < 32:
        return ["file is too small to be a Mach-O"]
    magic = struct.unpack_from("<I", data, 0)[0]
    if magic != 0xFEEDFACF:
        return []
    try:
        ncmds, sizeofcmds, cmds_off = (
            struct.unpack_from("<II", data, 16)[0],
            struct.unpack_from("<I", data, 20)[0],
            32,
        )
    except struct.error:
        return ["truncated Mach-O header"]
    if cmds_off + sizeofcmds > len(data):
        return ["load commands extend past the file"]
    off = 0
    seen = 0
    signature_at = None
    segments: list[tuple[str, int, int]] = []
    while off + 8 <= sizeofcmds and seen < ncmds:
        cmd, cmdsize = struct.unpack_from("<II", data, cmds_off + off)
        if cmdsize < 8 or off + cmdsize > sizeofcmds:
            errors.append(f"load command {seen} has invalid cmdsize {cmdsize}")
            break
        if cmd == LC_CODE_SIGNATURE and cmdsize >= 16:
            signature_at = seen
            dataoff, datasize = struct.unpack_from("<II", data, cmds_off + off + 8)
            if dataoff + datasize > len(data):
                errors.append("LC_CODE_SIGNATURE points past the end of the file")
        if cmd == LC_SEGMENT_64 and cmdsize >= 72:
            name = data[cmds_off + off + 8 : cmds_off + off + 24].split(b"\x00", 1)[0].decode()
            fileoff, filesize = struct.unpack_from("<QQ", data, cmds_off + off + 40)
            if filesize and fileoff + filesize > len(data):
                errors.append(f"segment {name} extends past the file")
            segments.append((name, fileoff, filesize))
        off += cmdsize
        seen += 1
    if seen != ncmds:
        errors.append(f"walked {seen} load commands, header says {ncmds}")
    if signature_at is not None and signature_at != ncmds - 1:
        errors.append("LC_CODE_SIGNATURE is not the last load command")
    for i, (name, off_i, size_i) in enumerate(segments):
        if not size_i:
            continue
        end_i = off_i + size_i
        for other, off_j, size_j in segments[i + 1 :]:
            if not size_j or name == other:
                continue
            end_j = off_j + size_j
            if off_i < end_j and off_j < end_i:
                errors.append(f"segments {name} and {other} overlap")
    return errors


def _rpaths(data: bytes) -> list[str]:
    paths: list[str] = []
    try:
        for _i, cmd, blob in iter_commands(data, 0):
            if cmd != (0x1C | 0x80000000) or len(blob) < 12:
                continue
            stroff = struct.unpack_from("<I", blob, 8)[0]
            if stroff < len(blob):
                end = blob.find(b"\x00", stroff)
                paths.append(blob[stroff:end].decode("utf-8", "replace"))
    except MachOError:
        return paths
    return paths


def resolve_load_paths(load: str, image_name: str, app_dir: str, rpaths: list[str]) -> list[str]:
    """Zip members that could satisfy an @rpath / @executable_path / @loader_path dependency."""

    loader_dir = image_name.rsplit("/", 1)[0]

    def expand(token: str, base: str) -> str:
        rest = token.split("/", 1)[1] if "/" in token else ""
        return f"{base}/{rest}" if rest else base

    if load.startswith("@executable_path"):
        return [expand(load, app_dir)]
    if load.startswith("@loader_path"):
        return [expand(load, loader_dir)]
    if load.startswith("@rpath/"):
        tail = load[len("@rpath/") :]
        bases = rpaths or ["@executable_path/Frameworks"]
        found: list[str] = []
        for rpath in bases:
            if rpath.startswith("@executable_path"):
                root = expand(rpath, app_dir)
            elif rpath.startswith("@loader_path"):
                root = expand(rpath, loader_dir)
            else:
                root = rpath
            if root:
                found.append(f"{root}/{tail}")
        return found
    return []


def missing_loads(
    names: set[str],
    loads: list[tuple[str, str]],
    data: bytes,
    image_name: str,
    app_dir: str,
    sdk: Path | None = None,
) -> list[str]:
    missing: list[str] = []
    rpaths = _rpaths(data)
    swift = sdk / "usr/lib/swift" if sdk else None
    for _kind, path in loads:
        if path.startswith(("/usr/", "/System/", "/Library/")):
            continue
        base = path.rsplit("/", 1)[-1]
        stem = base[:-6] if base.endswith(".dylib") else base
        # SDK text stubs are libswiftCore.tbd, while the load command names libswiftCore.dylib.
        if swift is not None and stem.startswith("libswift") and (swift / f"{stem}.tbd").is_file():
            continue
        candidates = resolve_load_paths(path, image_name, app_dir, rpaths)
        if not candidates or not any(candidate in names for candidate in candidates):
            missing.append(path)
    return missing


_tbd_cache: dict[str, tuple[set[str], set[str]]] = {}


def _tbd_file(sdk: Path, install: str) -> Path | None:
    rel = install[1:] if install.startswith("/") else install
    candidates = [
        sdk / f"{rel}.tbd",
        sdk / rel.replace(".dylib", ".tbd"),
    ]
    framework = Path(rel)
    candidates.append(sdk / framework.parent / f"{framework.name}.tbd")
    for path in candidates:
        if path.is_file():
            return path
    return None


def _parse_tbd(path: Path) -> tuple[set[str], set[str]]:
    key = str(path)
    cached = _tbd_cache.get(key)
    if cached:
        return cached
    text = path.read_text(errors="replace")
    symbols = set(re.findall(r"'(_[^']*)'", text))
    symbols.update(re.findall(r"(?<![A-Za-z0-9_])(_[A-Za-z0-9_$.]+)", text))
    kind = ""
    for line in text.splitlines():
        if "objc-eh-types:" in line:
            kind = "eh"
        elif "objc-classes:" in line:
            kind = "class"
        elif kind and line and not line.startswith(" ") and not line.startswith("\t"):
            kind = ""
        if not kind:
            continue
        for name in re.findall(r"(?<![A-Za-z0-9_$])([A-Za-z_][A-Za-z0-9_$]*)", line):
            if name in ("objc", "classes", "eh", "types"):
                continue
            if kind == "eh":
                symbols.add(f"_OBJC_EHTYPE_$_{name}")
            else:
                symbols.add(f"_OBJC_CLASS_$_{name}")
                symbols.add(f"_OBJC_METACLASS_$_{name}")
        if "]" in line:
            kind = ""
    reexports: set[str] = set()
    mode = ""
    for line in text.splitlines():
        if line.startswith("reexported-libraries:") or line.startswith("re-exports:"):
            mode = "re"
            continue
        if line.startswith("exports:") or line.startswith("install-name:"):
            mode = ""
        if mode == "re":
            reexports.update(re.findall(r"'(/[^']+)'", line))
    _tbd_cache[key] = (symbols, reexports)
    return symbols, reexports


def tbd_has_symbol(sdk: Path, install: str, symbol: str, seen: set[str] | None = None) -> bool:
    if seen is None:
        seen = set()
    if install in seen:
        return False
    seen.add(install)
    path = _tbd_file(sdk, install)
    if path is None:
        return False
    symbols, reexports = _parse_tbd(path)
    if symbol in symbols:
        return True
    for library in reexports:
        if tbd_has_symbol(sdk, library, symbol, seen):
            return True
    return False


def _load_stem(path: str) -> str:
    base = path.rsplit("/", 1)[-1]
    return base[:-6] if base.endswith(".dylib") else base


def dep_for_from(short: str, loads: list[str]) -> str | None:
    """Match nm's 'from libfoo' to a load path. Exact stem wins over a prefix."""

    exact: str | None = None
    prefix: str | None = None
    for path in loads:
        stem = _load_stem(path)
        if short == path.rsplit("/", 1)[-1] or short == stem:
            exact = exact or path
        elif stem.startswith(short + ".") or stem.startswith(short):
            prefix = prefix or path
        elif f"/{short}.framework/" in path or path.endswith(f"/{short}"):
            exact = exact or path
    return exact or prefix


def sdk_install_for_load(path: str, sdk: Path) -> str | None:
    """Absolute install name whose SDK .tbd satisfies this load command."""

    if path.startswith(("/usr/", "/System/", "/Library/")):
        return path
    stem = _load_stem(path)
    if stem.startswith("libswift") and (sdk / "usr/lib/swift" / f"{stem}.tbd").is_file():
        return f"/usr/lib/swift/{stem}.dylib"
    return None


def undefined_from_nm(nm: str, binary: Path) -> list[tuple[str, str, bool]]:
    """(symbol, library-short-name, weak) from llvm-nm -m -u."""

    result = subprocess.run([nm, "-m", "-u", str(binary)], capture_output=True, text=True)
    if result.returncode != 0:
        raise MachOError(result.stderr.strip() or f"nm failed on {binary.name}")
    found: list[tuple[str, str, bool]] = []
    for line in result.stdout.splitlines():
        match = re.search(r"\((undefined)\) (weak )?external (\S+)(?: \(from ([^)]+)\))?", line)
        if not match:
            continue
        found.append((match.group(3), match.group(4) or "", bool(match.group(2))))
    return found


def unresolved_symbols(
    symbols: list[tuple[str, str, bool]],
    loads: list[str],
    sdk: Path,
    macho_exports: dict[str, set[str]],
) -> list[str]:
    missing: list[str] = []
    for symbol, short, weak in symbols:
        if symbol == "dyld_stub_binder" or symbol.startswith("__mh_") or symbol.startswith("_OBJC_IVAR_$_"):
            continue
        dep = dep_for_from(short, loads) if short else None
        deps = [dep] if dep else loads
        ok = False
        for path in deps:
            if path is None:
                continue
            if path in macho_exports and symbol in macho_exports[path]:
                ok = True
                break
            install = sdk_install_for_load(path, sdk)
            if install and tbd_has_symbol(sdk, install, symbol):
                ok = True
                break
        if not ok:
            missing.append(f"{symbol} from {short or 'flat'}")
            if len(missing) >= 12:
                break
    return missing

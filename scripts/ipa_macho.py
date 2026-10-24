"""Small Mach-O helpers for inspecting and editing dylib load commands.

Used by the sideload prep and the IPA sanity check. Handles thin 64-bit
binaries and fat containers. Does not move segment data: removed load
commands are compacted inside the existing command region and the tail is
zeroed, so file offsets in the rest of the binary stay valid.
"""

from __future__ import annotations

import struct
from pathlib import Path

MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
FAT_CIGAM = 0xBEBAFECA

LC_LOAD_DYLIB = 0xC
LC_ID_DYLIB = 0xD
LC_LOAD_WEAK_DYLIB = 0x18 | 0x80000000
LC_REEXPORT_DYLIB = 0x1F
LC_LOAD_UPWARD_DYLIB = 0x23 | 0x80000000
LC_RPATH = 0x1C | 0x80000000
LC_LOAD_DYLINKER = 0xE

DYLIB_CMDS = {
    LC_LOAD_DYLIB,
    LC_ID_DYLIB,
    LC_LOAD_WEAK_DYLIB,
    LC_REEXPORT_DYLIB,
    LC_LOAD_UPWARD_DYLIB,
    0x18,  # LC_LOAD_WEAK_DYLIB without the req bit, just in case
}

CMD_NAMES = {
    LC_LOAD_DYLIB: "LC_LOAD_DYLIB",
    LC_ID_DYLIB: "LC_ID_DYLIB",
    LC_LOAD_WEAK_DYLIB: "LC_LOAD_WEAK_DYLIB",
    LC_REEXPORT_DYLIB: "LC_REEXPORT_DYLIB",
    LC_LOAD_UPWARD_DYLIB: "LC_LOAD_UPWARD_DYLIB",
    0x18: "LC_LOAD_WEAK_DYLIB",
    LC_RPATH: "LC_RPATH",
    LC_LOAD_DYLINKER: "LC_LOAD_DYLINKER",
}


class MachOError(Exception):
    pass


def _cstring(blob: bytes, start: int) -> str:
    end = blob.find(b"\x00", start)
    if end < 0:
        end = len(blob)
    return blob[start:end].decode("utf-8", "replace")


def _load_path(cmd: int, blob: bytes) -> str | None:
    if cmd not in DYLIB_CMDS and cmd not in (LC_RPATH, LC_LOAD_DYLINKER):
        return None
    if len(blob) < 12:
        return None
    stroff = struct.unpack_from("<I", blob, 8)[0]
    if stroff >= len(blob):
        return None
    return _cstring(blob, stroff)


def iter_slices(data: bytearray | bytes):
    """Yield (slice_offset, slice_length) for each Mach-O slice."""
    if len(data) < 8:
        raise MachOError("file is too small to be a Mach-O")
    magic = struct.unpack_from("<I", data, 0)[0]
    if magic == MH_MAGIC_64:
        yield 0, len(data)
        return
    magic_be = struct.unpack_from(">I", data, 0)[0]
    if magic_be not in (FAT_MAGIC, FAT_CIGAM):
        raise MachOError(f"unsupported Mach-O magic {magic:#x}")
    nfat = struct.unpack_from(">I", data, 4)[0]
    if nfat > 8:
        raise MachOError(f"unexpected fat arch count {nfat}")
    for i in range(nfat):
        cputype, _cpusub, offset, size, _align = struct.unpack_from(">5I", data, 8 + i * 20)
        if offset + size > len(data):
            raise MachOError(f"fat slice {i} (cpu {cputype:#x}) extends past the file")
        yield offset, size


def header(data: bytes, start: int) -> tuple[int, int, int]:
    magic, _cputype, _cpusub, _filetype, ncmds, sizeofcmds, _flags, _reserved = struct.unpack_from(
        "<8I", data, start
    )
    if magic != MH_MAGIC_64:
        raise MachOError(f"slice at {start:#x} is not a 64-bit Mach-O ({magic:#x})")
    if start + 32 + sizeofcmds > len(data):
        raise MachOError("load commands extend past the file")
    return ncmds, sizeofcmds, start + 32


def iter_commands(data: bytes, start: int):
    ncmds, sizeofcmds, cmds_off = header(data, start)
    off = 0
    seen = 0
    while off < sizeofcmds and seen < ncmds:
        if off + 8 > sizeofcmds:
            raise MachOError("truncated load command")
        cmd, cmdsize = struct.unpack_from("<II", data, cmds_off + off)
        if cmdsize < 8 or off + cmdsize > sizeofcmds:
            raise MachOError(f"bad cmdsize {cmdsize} for command {cmd:#x}")
        blob = data[cmds_off + off : cmds_off + off + cmdsize]
        yield seen, cmd, blob
        off += cmdsize
        seen += 1
    if seen != ncmds or off != sizeofcmds:
        raise MachOError(f"load-command table inconsistent (walked {seen}/{ncmds}, {off}/{sizeofcmds})")


def _dylib_base(cmd: int, blob: bytes) -> str | None:
    if cmd not in DYLIB_CMDS or cmd == LC_ID_DYLIB:
        return None
    text = _load_path(cmd, blob)
    if not text:
        return None
    return text.rsplit("/", 1)[-1]


def reorder_load_commands(commands: list[tuple[int, bytes]], first: list[str]) -> list[tuple[int, bytes]]:
    """Place named dylibs immediately before FBSharedFramework, in `first` order.

    dyld initializes direct dependencies in load-command order. The session
    suites have to be redirected before FBSharedFramework's initializers read
    them. libSystem stays where it is; only the named dylibs move.
    """
    priority = {name: index for index, name in enumerate(first)}
    anchor = None
    first_dylib = None
    for index, (cmd, blob) in enumerate(commands):
        base = _dylib_base(cmd, blob)
        if base is None:
            continue
        if first_dylib is None:
            first_dylib = index
        if base == "FBSharedFramework":
            anchor = index
            break
    if anchor is None:
        anchor = first_dylib
    if anchor is None:
        return list(commands)
    prefix: list[tuple[int, bytes]] = []
    picked: list[tuple[int, bytes]] = []
    rest: list[tuple[int, bytes]] = []
    for index, item in enumerate(commands):
        base = _dylib_base(item[0], item[1])
        if base in priority:
            picked.append(item)
        elif index < anchor:
            prefix.append(item)
        else:
            rest.append(item)
    picked.sort(key=lambda item: priority[_dylib_base(item[0], item[1]) or ""])
    return prefix + picked + rest


def prioritize_dylibs(path: Path, first: list[str]) -> list[str]:
    """Reorder dylib load commands in every thin slice. Returns the first slice's dylib basenames."""
    data = bytearray(path.read_bytes())
    edited = False
    report: list[str] = []
    for start, _size in list(iter_slices(data)):
        if struct.unpack_from("<I", data, start)[0] != MH_MAGIC_64:
            continue
        ncmds, sizeofcmds, cmds_off = header(data, start)
        commands = [(cmd, blob) for _i, cmd, blob in iter_commands(data, start)]
        ordered = reorder_load_commands(commands, first)
        if [blob for _cmd, blob in ordered] == [blob for _cmd, blob in commands]:
            if not report:
                report = [_dylib_base(cmd, blob) or "" for cmd, blob in commands if _dylib_base(cmd, blob)]
            continue
        packed = b"".join(blob for _cmd, blob in ordered)
        if len(packed) != sizeofcmds or len(ordered) != ncmds:
            raise MachOError("reordered load commands changed size; refusing to rewrite the header")
        data[cmds_off : cmds_off + sizeofcmds] = packed
        iter_commands(data, start)
        edited = True
        if not report:
            report = [_dylib_base(cmd, blob) or "" for cmd, blob in ordered if _dylib_base(cmd, blob)]
    if edited:
        path.write_bytes(data)
    return report


def dylib_loads(path: Path) -> list[tuple[str, str]]:
    data = path.read_bytes()
    loads: list[tuple[str, str]] = []
    for start, _size in iter_slices(data):
        if struct.unpack_from("<I", data, start)[0] != MH_MAGIC_64:
            continue
        for _i, cmd, blob in iter_commands(data, start):
            text = _load_path(cmd, blob)
            if text and cmd in DYLIB_CMDS and cmd != LC_ID_DYLIB:
                loads.append((CMD_NAMES.get(cmd, hex(cmd)), text))
    return loads


def constructors_follow_framework(paths: list[str]) -> bool:
    """True when both tweak constructors run after FBSharedFramework.

    dyld runs initializers in load-command order. 2.4.9 moved
    zxPluginsInject and SCInsta ahead of FBSharedFramework, so those
    constructors walked classes and redirected suites before the image
    existed and the process crashed on launch. 2.4.8 loaded the framework
    first and launched.
    """

    names = [path.rsplit("/", 1)[-1] for path in paths]
    try:
        framework = names.index("FBSharedFramework")
        tweak = names.index("SCInsta.dylib")
        injector = names.index("zxPluginsInject.dylib")
    except ValueError:
        return False
    return framework < tweak and framework < injector


def strip_dylibs(path: Path, basenames: set[str]) -> list[str]:
    """Remove load commands whose dylib path ends with one of `basenames`.

    Returns the removed paths. The file is rewritten in place.
    """
    data = bytearray(path.read_bytes())
    removed: list[str] = []
    edited = False
    for start, _size in list(iter_slices(data)):
        if struct.unpack_from("<I", data, start)[0] != MH_MAGIC_64:
            continue
        ncmds, sizeofcmds, cmds_off = header(data, start)
        kept = bytearray()
        new_ncmds = 0
        off = 0
        seen = 0
        while off < sizeofcmds and seen < ncmds:
            cmd, cmdsize = struct.unpack_from("<II", data, cmds_off + off)
            if cmdsize < 8 or off + cmdsize > sizeofcmds:
                raise MachOError(f"bad cmdsize while stripping {path}")
            blob = bytes(data[cmds_off + off : cmds_off + off + cmdsize])
            text = _load_path(cmd, blob)
            base = text.rsplit("/", 1)[-1] if text else ""
            if text and cmd in DYLIB_CMDS and cmd != LC_ID_DYLIB and base in basenames:
                removed.append(text)
            else:
                kept += blob
                new_ncmds += 1
            off += cmdsize
            seen += 1
        if len(kept) > sizeofcmds:
            raise MachOError("compacted load commands grew, which this editor refuses")
        if len(kept) == sizeofcmds and new_ncmds == ncmds:
            continue
        data[cmds_off : cmds_off + sizeofcmds] = kept + b"\x00" * (sizeofcmds - len(kept))
        struct.pack_into("<II", data, start + 16, new_ncmds, len(kept))
        iter_commands(data, start)
        edited = True
    if edited:
        path.write_bytes(data)
    return removed

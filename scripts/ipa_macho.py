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

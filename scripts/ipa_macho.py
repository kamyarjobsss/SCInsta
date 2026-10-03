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
LC_CODE_SIGNATURE = 0x1D
LC_ENCRYPTION_INFO = 0x21
LC_ENCRYPTION_INFO_64 = 0x2C

MH_MAGIC = 0xFEEDFACE
CS_LINKER_SIGNED = 0x20000
CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSMAGIC_CODEDIRECTORY = 0xFADE0C02

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


def _slice_starts(data: bytes) -> list[int]:
    if len(data) < 8:
        raise MachOError("file is too small to be a Mach-O")
    magic_le = struct.unpack_from("<I", data, 0)[0]
    if magic_le in (MH_MAGIC_64, MH_MAGIC):
        return [0]
    magic_be = struct.unpack_from(">I", data, 0)[0]
    if magic_be in (FAT_MAGIC, FAT_CIGAM):
        return [offset for offset, _size in iter_slices(data)]
    raise MachOError(f"unsupported Mach-O magic {magic_le:#x}")


def _walk_commands(data: bytes, start: int):
    magic = struct.unpack_from("<I", data, start)[0]
    if magic == MH_MAGIC_64:
        ncmds, sizeofcmds, cmds_off = header(data, start)
    elif magic == MH_MAGIC:
        _magic, _cpu, _sub, _filetype, ncmds, sizeofcmds, _flags = struct.unpack_from("<7I", data, start)
        cmds_off = start + 28
        if sizeofcmds < 8 or cmds_off + sizeofcmds > len(data):
            raise MachOError("32-bit load commands extend past the file")
    else:
        raise MachOError(f"slice at {start:#x} is not a little-endian Mach-O ({magic:#x})")
    off = 0
    seen = 0
    while off < sizeofcmds and seen < ncmds:
        cmd, cmdsize = struct.unpack_from("<II", data, cmds_off + off)
        if cmdsize < 8 or off + cmdsize > sizeofcmds:
            raise MachOError(f"bad cmdsize {cmdsize} for command {cmd:#x}")
        yield cmd, data[cmds_off + off : cmds_off + off + cmdsize]
        off += cmdsize
        seen += 1


def is_macho(data: bytes) -> bool:
    if len(data) < 4:
        return False
    prefix = data[:4]
    return prefix in (
        b"\xcf\xfa\xed\xfe",
        b"\xce\xfa\xed\xfe",
        b"\xca\xfe\xba\xbe",
        b"\xbe\xba\xfe\xca",
        b"\xfe\xed\xfa\xcf",
        b"\xfe\xed\xfa\xce",
    )


def cryptids(data: bytes) -> list[int]:
    """Every FairPlay cryptid in the file. Missing encryption commands mean 0."""
    found: list[int] = []
    for start in _slice_starts(data):
        for cmd, blob in _walk_commands(data, start):
            if cmd in (LC_ENCRYPTION_INFO, LC_ENCRYPTION_INFO_64) and len(blob) >= 20:
                found.append(struct.unpack_from("<I", blob, 16)[0])
    return found


def _blob_signature_status(blob: bytes) -> str:
    if len(blob) < 12:
        return "unrecognized code signature"
    magic, length, count = struct.unpack_from(">III", blob, 0)
    if magic != CSMAGIC_EMBEDDED_SIGNATURE or length > len(blob) or 12 + count * 8 > len(blob):
        return "unrecognized code signature"
    saw_directory = False
    for index in range(count):
        slot, offset = struct.unpack_from(">II", blob, 12 + index * 8)
        if slot != 0 or offset + 40 > len(blob):
            continue
        cd_magic, _cd_len, version, flags = struct.unpack_from(">IIII", blob, offset)
        if cd_magic != CSMAGIC_CODEDIRECTORY:
            continue
        saw_directory = True
        if flags & CS_LINKER_SIGNED:
            return "linker-signed"
        if version >= 0x20200:
            if offset + 52 > len(blob):
                return "truncated code directory"
            team_off = struct.unpack_from(">I", blob, offset + 48)[0]
            if team_off:
                team_at = offset + team_off
                if team_at >= len(blob):
                    return "truncated code directory"
                team = _cstring(blob, team_at)
                if team:
                    return f"team {team}"
    if not saw_directory:
        return "unrecognized code signature"
    return "adhoc"


def signature_status(data: bytes) -> str:
    """`unsigned` or `adhoc` when Sideloadly can re-sign the binary.

    A developer team id or a linker signature is returned as a short reason.
    """
    status = "unsigned"
    for start in _slice_starts(data):
        for cmd, blob in _walk_commands(data, start):
            if cmd != LC_CODE_SIGNATURE or len(blob) < 16:
                continue
            dataoff, datasize = struct.unpack_from("<II", blob, 8)
            begin = start + dataoff
            end = begin + datasize
            if dataoff == 0 or datasize < 12 or end > len(data):
                return "code signature is out of range"
            kind = _blob_signature_status(data[begin:end])
            if kind != "adhoc":
                return kind
            status = "adhoc"
    return status

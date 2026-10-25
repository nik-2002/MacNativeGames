#!/usr/bin/env python3
"""Extract every NVN shader stored in data.arc into a shader pack, so the runtime can translate them before play.

Smash hands the graphics layer a shader (nvnProgramSetShaders) when it loads the file that holds it: model shaders in
the .nushdb files, each fighter's and stage's effect shaders in its .eff file. A fighter or stage met for the first time
used to translate its shaders while the match started (1.5-3 s hitches, 2026-10-25). A shader is its NVN control
section (magic 0x98761234, its length at +0x20, the code length at +0x704, the stage at +0x714) and its code area,
exactly the bytes the game uploads; the runtime keys it by SHA-256(control[:length] + code), so the pack holds those
bytes (the control padded to the 0x880 the runtime reads).
- .nushdb: each control section is followed directly by its code.
- .eff: a VFXB effect binary with NintendoWare BNSH shader containers. Controls and codes lie in separate regions; a
  24-byte record per shader stage holds {u64 control offset, u64 code offset, u32 code size, u32 control size}, the
  offsets from the start of the BNSH file. (Pairing controls with the code that follows them was wrong there: 0 of the
  6,210 effect shaders a session had used came out right; with the records they do.)
(The 31 shaders built into main are handed over at start and need no pack.)

Pack format: "SSBUSHP1", u32 count, then per shader: u32 stage, u32 code length, control (0x880 bytes), code.

    python3 scripts/extract_shaders.py SSBU_build/extracted/v1304/romfs/romfs.bin --output SSBU_build/shader-pack.bin
"""
import argparse
import compression.zstd as zstd
import hashlib
import json
import struct
import sys
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import extract_nros

CONTROL = 0x880
MAGIC = b'\x34\x12\x76\x98'
EXTENSIONS = ('nushdb', 'eff')


def h40(name):
    return zlib.crc32(name.encode()) | (len(name) << 32)


def arc_reader(romfs):
    """read(offset, size) inside data.arc, from the merged RomFS image (romfs.bin + index.json) or a plain data.arc."""
    index = romfs.parent / 'index.json'
    base = 0
    if romfs.name != 'data.arc':
        files = {f['path']: f for f in json.loads(index.read_text())['files']}
        base = files['data.arc']['offset']
    f = romfs.open('rb')

    def read(off, size):
        f.seek(base + off)
        return f.read(size)
    return read


def arc_files(read):
    """{extension hash: [read the file -> bytes, ...]} for the data.arc file table (extract_nros's layout for 13.0.4)."""
    magic, _, file_data_off, _, fs_off, _ = struct.unpack('<QQQQQQ', read(0, 48))
    if magic != extract_nros.ARC_MAGIC:
        raise SystemExit('not a data.arc')
    _, decomp_sz, comp_sz, _ = struct.unpack('<IIII', read(fs_off, 16))
    dec = zstd.decompress(read(fs_off + 16, comp_sz))
    (count, paths, info_idx, folders, infos, to_datas, datas) = extract_nros.find_arc_table_offsets(dec)
    out = {}
    for i in range(count):
        p_hti, e_hti, _, _ = struct.unpack_from('<QQQQ', dec, paths + i * 32)
        idx = p_hti >> 40
        _, fi = struct.unpack_from('<II', dec, info_idx + idx * 8)
        _, _, itd, _ = struct.unpack_from('<IIII', dec, infos + fi * 16)
        foi, fdi, _ = struct.unpack_from('<III', dec, to_datas + itd * 12)
        f_offset = struct.unpack_from('<Q', dec, folders + foi * 28)[0]
        oif, cs, ds, _ = struct.unpack_from('<IIII', dec, datas + fdi * 16)
        at = file_data_off + f_offset + (oif << 2)

        def load(at=at, cs=cs, ds=ds):
            raw = read(at, cs)
            return zstd.decompress(raw) if cs != ds else raw
        out.setdefault(e_hti & 0xffffffffff, []).append(load)
    return out


def bnsh_shaders(data):
    """(stage, control, code) from the shader records of every BNSH container in a file."""
    base = data.find(b'BNSH')
    while base >= 0:
        size, = struct.unpack_from('<I', data, base + 0x1c) if base + 0x20 <= len(data) else (0,)
        end = min(len(data), base + size) if size else len(data)
        for at in range(base, end - 24, 8):
            ctl_off, code_off, code_size, ctl_size = struct.unpack_from('<QQII', data, at)
            if not (0x7cc <= ctl_size <= CONTROL and 0 < code_size <= 16 << 20 and ctl_off < end - base and code_off < end - base):
                continue
            c = base + ctl_off
            if data[c:c + 4] != MAGIC or struct.unpack_from('<I', data, c + 0x20)[0] != ctl_size:
                continue
            length, = struct.unpack_from('<I', data, c + 0x704)
            stage, = struct.unpack_from('<I', data, c + 0x714)
            if stage in (0, 1, 5) and length == code_size and base + code_off + length <= end:
                yield stage, data[c:c + ctl_size] + bytes(CONTROL - ctl_size), data[base + code_off:base + code_off + length]
        base = data.find(b'BNSH', base + 4)


def shaders_in(data):
    """(stage, control, code) for every control section in a .nushdb file (the code follows its control)."""
    at = data.find(MAGIC)
    while at >= 0:
        if at + CONTROL <= len(data):
            klen, = struct.unpack_from('<I', data, at + 0x20)
            length, = struct.unpack_from('<I', data, at + 0x704)
            stage, = struct.unpack_from('<I', data, at + 0x714)
            if 0x7cc <= klen <= CONTROL and stage in (0, 1, 5) and 0x30 < length <= 16 << 20 and at + klen + length <= len(data):
                control = data[at:at + klen] + bytes(CONTROL - klen)
                yield stage, control, data[at + klen:at + klen + length]
        at = data.find(MAGIC, at + 4)


def key(control, code):
    klen, = struct.unpack_from('<I', control, 0x20)
    return hashlib.sha256(control[:klen] + code).hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('romfs', type=Path, help='SSBU_build/extracted/v1304/romfs/romfs.bin (or an extracted data.arc)')
    p.add_argument('--output', type=Path, default=Path('SSBU_build/shader-pack.bin'))
    p.add_argument('--check', type=Path, help='a folder of <key>.ctl / <key>.code the runtime dumped (SSBU_SHADER_DUMP): '
                                             'each one found must rebuild to its key')
    args = p.parse_args()
    by_ext = arc_files(arc_reader(args.romfs))
    seen, records, counts = set(), [], {}
    for ext in EXTENSIONS:
        loads = by_ext.get(h40(ext), [])
        n = 0
        for load in loads:
            data = load()
            for stage, control, code in (bnsh_shaders(data) if ext == 'eff' else shaders_in(data)):
                k = key(control, code)
                if k in seen:
                    continue
                seen.add(k)
                records.append((stage, control, code))
                n += 1
        counts[ext] = (len(loads), n)
        print(f'{ext}: {len(loads)} files, {n} new shaders', flush=True)
    if args.check:
        dumped = {c.stem for c in args.check.glob('*.ctl')}
        rebuilt = dumped & seen
        for name in rebuilt:   # the pack's bytes are the game's bytes
            ctl, code = (args.check / f'{name}.ctl').read_bytes(), (args.check / f'{name}.code').read_bytes()
            if key(ctl, code) != name:
                raise SystemExit(f'dumped shader {name} does not hash to its own name')
        print(f'check: {len(rebuilt)} of {len(dumped)} dumped shaders are in the pack with the same key '
              '(the rest are built into main)')
    with args.output.open('wb') as out:
        out.write(b'SSBUSHP1' + struct.pack('<I', len(records)))
        for stage, control, code in records:
            out.write(struct.pack('<II', stage, len(code)) + control + code)
    stages = {s: sum(1 for r in records if r[0] == s) for s in (0, 1, 5)}
    print(f'{len(records)} shaders (vertex {stages[0]}, pixel {stages[1]}, compute {stages[5]}) -> {args.output}')


if __name__ == '__main__':
    main()

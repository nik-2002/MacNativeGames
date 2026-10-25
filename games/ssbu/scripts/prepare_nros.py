#!/usr/bin/env python3
"""Wrap extracted SSBU NRO0 modules in uncompressed NSO0 carriers, rewrite them for native execution,
and generate the C catalog (`nro_catalog.c` / `nro_catalog.json`) for `runtime/nro_loader.c`.

Adapted from the MIT `NicholasDominici/super-smash-bros-ultimate-ios` NRO pipeline (`tools/smash_nro.py`).
Only NRO images whose SHA-256 digests appear in the game's `.nrr` registrations are admitted.
"""
import argparse
import concurrent.futures
import hashlib
import json
import os
import re
import struct
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PATCH_NSO = ROOT / 'third_party/d2r/patch_nso.py'
MAX_IMAGE = 256 * 1024 * 1024
MAX_MODULES = 512
CATALOG_FORMAT = 2
TITLE_ID = 0x01006A800016E000


def u32(data: bytes, offset: int) -> int:
    return struct.unpack_from('<I', data, offset)[0]


def parse_nro(data: bytes) -> dict:
    """Validate a complete NRO0 image and return its segment layout and exported symbols."""
    if len(data) < 0x80 or data[0x10:0x14] != b'NRO0':
        raise ValueError('Not an NRO0 image')
    size, bss = u32(data, 0x18), u32(data, 0x38)
    if size != len(data) or not 0x80 <= size <= MAX_IMAGE or bss > MAX_IMAGE:
        raise ValueError('NRO image/BSS length is unsupported or does not match the file')
    segments = [struct.unpack_from('<II', data, off) for off in (0x20, 0x28, 0x30)]
    if segments[0][0] != 0 or segments[0][1] < 0x80:
        raise ValueError('NRO text must start at zero and contain its header')
    end = 0
    for offset, length in segments:
        if offset < end or length == 0 or offset + length > size or offset % 0x1000:
            raise ValueError('NRO segments overlap, exceed the image, or are not page aligned')
        end = offset + length
    mod0 = u32(data, 4)
    if mod0 + 0x1c > size or data[mod0:mod0 + 4] != b'MOD0':
        raise ValueError('NRO has no valid MOD0 header')
    object_offset = mod0 + struct.unpack_from('<i', data, mod0 + 0x18)[0]
    if object_offset < segments[2][0] or object_offset + 0xd0 > size + bss:
        raise ValueError('NRO SDK module object lies outside writable image/BSS')
    dynamic = mod0 + struct.unpack_from('<i', data, mod0 + 4)[0]
    if dynamic < 0 or dynamic + 16 > size:
        raise ValueError('NRO dynamic table is out of range')
    tags = {}
    for off in range(dynamic, min(size - 15, dynamic + 65536), 16):
        tag, value = struct.unpack_from('<qQ', data, off)
        if tag == 0:
            break
        tags[tag] = value
    else:
        raise ValueError('NRO dynamic table is not terminated')
    if any(tag in tags for tag in (17, 18, 19, 35, 36, 0x6ffffef6)):
        raise ValueError('NRO requires an unsupported REL/RELR/GNU-hash dynamic format')
    for start_tag, size_tag in ((7, 8), (23, 2)):
        start, length = tags.get(start_tag, 0), tags.get(size_tag, 0)
        if length % 24 or start > size or length > size - start:
            raise ValueError('NRO relocation table is out of range')
        for off in range(start, start + length, 24):
            target, info, _ = struct.unpack_from('<QQq', data, off)
            if info & 0xffffffff not in (0, 257, 1025, 1026, 1027):
                raise ValueError('NRO uses an unsupported relocation type')
            if not (info & 0xffffffff):
                continue
            if target < ((segments[0][1] + 0x3fff) & ~0x3fff) or target + 8 > size + bss:
                raise ValueError('NRO relocation targets signed code or lies outside data/BSS')
    symbol_start, string_start = tags.get(6, 0), tags.get(5, 0)
    if not 0 < symbol_start < string_start <= size or (string_start - symbol_start) % 24:
        raise ValueError('NRO dynamic symbol/string table layout is unsupported')
    if any((data[off + 4] & 15) == 6 for off in range(symbol_start, string_start, 24)):
        raise ValueError('NRO module TLS is not supported by this native loader')
    exports = []
    string_end = string_start + tags.get(10, size - string_start)
    if string_end > size:
        raise ValueError('NRO string table exceeds the original image')
    for off in range(symbol_start, string_start, 24):
        name, info, other, section, value, _ = struct.unpack_from('<IBBHQQ', data, off)
        if not section or info >> 4 == 0 or other & 3 not in (0, 3):
            continue
        start = string_start + name
        end_pos = data.find(b'\0', start, string_end)
        if start >= string_end or end_pos < 0 or not start < end_pos:
            raise ValueError('NRO exported symbol has an invalid string-table name')
        if info & 15 == 2 and value >= segments[0][1]:
            raise ValueError('NRO function export lies outside executable text')
        exports.append({'name': data[start:end_pos].decode('ascii'), 'type': info & 15, 'offset': value})
    return {
        'image_size': size,
        'bss_size': bss,
        'segments': segments,
        'build_id': data[0x40:0x60].hex(),
        'sha256': hashlib.sha256(data).hexdigest(),
        'exports': exports,
    }


def nso_carrier(data: bytes, info: dict) -> bytes:
    """Wrap an NRO0 image in an uncompressed NSO0 container without modifying any NRO byte."""
    header = bytearray(0x100)
    header[:4] = b'NSO0'
    header[0x40:0x60] = bytes.fromhex(info['build_id'])
    body = bytearray()
    for i, (offset, size) in enumerate(info['segments']):
        struct.pack_into('<III', header, 0x10 + i * 0x10, 0x100 + len(body), offset, size)
        struct.pack_into('<I', header, 0x60 + i * 4, size)
        body.extend(data[offset:offset + size])
    struct.pack_into('<I', header, 0x3c, info['bss_size'])
    return bytes(header + body)


def parse_nrr(data: bytes) -> set[str]:
    if len(data) < 0x350 or data[:4] != b'NRR0' or u32(data, 0x338) != len(data):
        raise ValueError('Invalid NRR0 header or length')
    program = struct.unpack_from('<Q', data, 0x330)[0]
    offset, count = u32(data, 0x340), u32(data, 0x344)
    if program != TITLE_ID or offset < 0x350 or offset % 16 or count > 65536 or offset + count * 32 > len(data):
        raise ValueError('NRR program ID or hash-list bounds do not match Smash Ultimate')
    return {data[i:i + 32].hex() for i in range(offset, offset + count * 32, 32)}


def rewrite_one(args_tuple):
    nso_path, out_dir, name = args_tuple
    subprocess.run([sys.executable, str(PATCH_NSO), str(nso_path), str(out_dir), name],
                   check=True, stdout=subprocess.DEVNULL)
    return name


def catalog_source(catalog: dict) -> str:
    modules, nrrs = catalog['modules'], catalog['registrations']
    exports = {}
    for index, module in enumerate(modules):
        for entry in module['exports']:
            name, kind, offset = entry['name'], entry['type'], entry['offset']
            if name in exports:
                raise ValueError(f'Ambiguous NRO export provider: {name}')
            exports[name] = (index, kind, offset)

    def digest_array(h: str) -> str:
        return '{' + ','.join('0x' + h[i:i + 2] for i in range(0, 64, 2)) + '}'

    c = [
        '// Generated NRO identity & deferred export catalog. No executable bytes.',
        '#include <stdint.h>',
        '#include "runtime/nro_loader.h"',
        '',
        'const ssbu_nro_catalog_entry g_ssbu_nro_catalog[] = {',
    ]
    for m in modules:
        c.append(f'    {{"{m["name"]}", {json.dumps(m["source_name"])}, {m["image_size"]}u, {m["bss_size"]}u, {digest_array(m["sha256"])}}},')
    c += [
        '};',
        f'const unsigned g_ssbu_nro_catalog_count = {len(modules)}u;',
        '',
        'const ssbu_nrr_catalog_entry g_ssbu_nrr_catalog[] = {',
    ]
    for n in nrrs:
        c.append(f'    {{{n["size"]}u, {digest_array(n["sha256"])}}},')
    c += [
        '};',
        f'const unsigned g_ssbu_nrr_catalog_count = {len(nrrs)}u;',
        '',
        'const ssbu_nro_export_entry g_ssbu_nro_exports[] = {',
    ]
    for name, (index, kind, offset) in sorted(exports.items()):
        c.append(f'    {{{json.dumps(name)}, {index}u, {kind}u, {offset}ull}},')
    c += [
        '};',
        f'const unsigned g_ssbu_nro_export_count = {len(exports)}u;',
        '',
    ]
    return '\n'.join(c)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=Path('SSBU_build/extracted/v1304/nros'))
    parser.add_argument('--nrr-dir', type=Path, default=Path('SSBU_build/extracted/v1304/nrrs'))
    parser.add_argument('--output', type=Path, default=Path('SSBU_build/rewritten/v1304'))
    parser.add_argument('--jobs', type=int, default=max(1, os.cpu_count() or 4))
    parser.add_argument('--skip-rewrite', action='store_true', help='reuse existing rewritten NROs if present')
    args = parser.parse_args()

    source = args.source.resolve()
    nrr_dir = args.nrr_dir.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)

    nrrs, allowed = [], set()
    for p in sorted(nrr_dir.glob('*.nrr')):
        raw = p.read_bytes()
        allowed.update(parse_nrr(raw))
        nrrs.append({'name': p.name, 'sha256': hashlib.sha256(raw).hexdigest(), 'size': len(raw)})
    if not nrrs or not allowed:
        raise SystemExit(f'No valid NRR files found in {nrr_dir}')

    files = sorted(source.glob('*.nro'))
    if not files:
        raise SystemExit(f'No .nro files found in {source}')

    modules, seen, names, tasks = [], set(), set(), []
    for path in files:
        raw = path.read_bytes()
        info = parse_nro(raw)
        digest = info['sha256']
        if digest not in allowed:
            raise ValueError(f'NRO {path.name} ({digest}) is not in any NRR registration')
        if digest in seen:
            continue
        name = 'n' + digest[:7]
        if name in names:
            raise ValueError(f'NRO short-name collision: {name}')
        seen.add(digest)
        names.add(name)
        info['name'] = name
        info['source_name'] = path.name
        nso_path = output / f'{name}.nso'
        nso_path.write_bytes(nso_carrier(raw, info))
        if not (args.skip_rewrite and (output / f'{name}.patched.bin').is_file()):
            tasks.append((nso_path, output, name))
        modules.append(info)

    if tasks:
        print(f'Rewriting {len(tasks)} NRO modules across {args.jobs} workers...', flush=True)
        done = 0
        with concurrent.futures.ProcessPoolExecutor(max_workers=args.jobs) as pool:
            for _ in pool.map(rewrite_one, tasks):
                done += 1
                if done % 10 == 0 or done == len(tasks):
                    print(f'  [{done}/{len(tasks)}] NROs rewritten', flush=True)

    catalog = {
        'format': CATALOG_FORMAT,
        'title_id': f'{TITLE_ID:016X}',
        'rewritten': True,
        'modules': modules,
        'registrations': nrrs,
    }
    (output / 'nro_catalog.c').write_text(catalog_source(catalog))
    (output / 'nro_catalog.json').write_text(json.dumps(catalog, indent=2) + '\n')
    print(f'Generated {output / "nro_catalog.c"} ({len(modules)} modules, {sum(len(m["exports"]) for m in modules)} exports)')


if __name__ == '__main__':
    main()

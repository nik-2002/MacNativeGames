#!/usr/bin/env python3
"""Extract the RomFS of each add-on content (DLC) NSP into the work folder, verifying all six IVFC levels.

Smash's add-ons are small (2026-10-25, 99 NSPs of 153,536 bytes each): one PublicData NCA (content type 5) whose RomFS
the game mounts through nn::aoc, and a meta NCA. The fighters, stages and music themselves ship in the game's own
data.arc. Each add-on lands in <output>/<title id>/romfs.bin with an index.json, and <output>/manifest.json lists them
for the runtime (runtime/services.c: nn::aoc counts, lists and mounts them).

    python3 scripts/extract_dlc.py --keys ~/.switch/prod.keys --input <folder of DLC NSPs> --output SSBU_build/dlc
"""
import argparse
import hashlib
import json
import struct
from pathlib import Path
from cryptography.hazmat.primitives.ciphers import modes
from extract_exefs import decrypt, read_at, require, load_keys, container_entries, common_tickets, nca_inventory, nca_ctr_key
from extract_romfs import index_romfs

BASE_TITLE = 0x01006A800016E000          # Super Smash Bros. Ultimate
AOC_BASE = BASE_TITLE + 0x1000           # add-on index = title id - AOC_BASE


def extract_romfs(f, record, hdr, key, output):
    """The first RomFS section of the NCA, IVFC-verified, as output/romfs.bin; returns its SHA-256."""
    for i in range(4):
        start, end = struct.unpack_from('<II', hdr, 0x240 + i * 16)
        if not start:
            continue
        fs = hdr[0x400 + 512 * i:0x600 + 512 * i]
        require(hashlib.sha256(fs).digest() == hdr[0x280 + 32 * i:0x2a0 + 32 * i], 'FS header hash')
        if fs[2:5] != bytes([0, 3, 3]):
            continue
        require(fs[8:12] == b'IVFC' and struct.unpack_from('<III', fs, 12) == (0x20000, 32, 7), 'Unsupported IVFC layout')
        levels = [struct.unpack_from('<QQII', fs, 0x18 + j * 24) for j in range(6)]

        def read(relative, size):
            require(0 <= relative <= relative + size <= (end - start) * 512, 'Section bounds')
            absolute = start * 512 + relative
            aligned = absolute & ~15
            skip = absolute - aligned
            iv = fs[0x140:0x148][::-1] + (aligned // 16).to_bytes(8, 'big')
            return decrypt(key, modes.CTR(iv), read_at(f, record['nca_offset'] + aligned, size + skip))[skip:]

        parent = fs[0xc8:0xe8]
        for level, (offset, size, power, reserved) in enumerate(levels):
            require(12 <= power <= 24 and reserved == 0, 'IVFC block size')
            block = 1 << power
            data = read(offset, size)
            require(len(parent) >= (size + block - 1) // block * 32, 'IVFC parent size')
            for index, j in enumerate(range(0, len(data), block)):
                payload = data[j:j + block]
                require(hashlib.sha256(payload + bytes(block - len(payload))).digest() == parent[index * 32:index * 32 + 32],
                        f'IVFC level {level} block {index} failed')
            parent = data
        (output / 'romfs.bin').write_bytes(parent)
        return hashlib.sha256(parent).hexdigest()
    raise ValueError('No RomFS in the add-on NCA')


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--keys', type=Path, required=True)
    p.add_argument('--input', type=Path, required=True, help='a folder of add-on NSPs (on the internal disk)')
    p.add_argument('--output', type=Path, default=Path('SSBU_build/dlc'))
    args = p.parse_args()
    keys = load_keys(args.keys)
    args.output.mkdir(parents=True, exist_ok=True)
    titles = []
    for nsp in sorted(args.input.glob('*.nsp')):
        with nsp.open('rb') as f:
            _, entries = container_entries(f, nsp.stat().st_size)
            records = nca_inventory(f, entries, keys)
            data = [(r, h) for r, h in records if r['content_type'] in (4, 5)]   # Data / PublicData
            require(len(data) == 1, f'{nsp.name}: expected one add-on data NCA')
            record, hdr = data[0]
            title = int(record['title_id'], 16)
            require(AOC_BASE < title < AOC_BASE + 0x1000, f'{nsp.name}: not an add-on of this game ({record["title_id"]})')
            out = args.output / record['title_id']
            out.mkdir(exist_ok=True)
            digest = extract_romfs(f, record, hdr, nca_ctr_key(hdr, keys, common_tickets(f, entries)), out)
            files = index_romfs(out / 'romfs.bin')
            (out / 'index.json').write_text(json.dumps(dict(source=nsp.name, romfs_sha256=digest, files=files), indent=2) + '\n')
            titles.append(dict(title_id=record['title_id'], index=title - AOC_BASE, files=len(files), name=nsp.name))
            print(f'{record["title_id"]} index {title - AOC_BASE:3d}: {len(files)} files  {nsp.name[:80]}', flush=True)
    require(titles, 'No NSPs in the input folder')
    require(len({t['index'] for t in titles}) == len(titles), 'Two NSPs of the same add-on')
    (args.output / 'manifest.json').write_text(json.dumps(dict(base_title=f'{BASE_TITLE:016X}', titles=titles), indent=2) + '\n')
    print(f'{len(titles)} add-ons extracted to {args.output}')


if __name__ == '__main__':
    main()

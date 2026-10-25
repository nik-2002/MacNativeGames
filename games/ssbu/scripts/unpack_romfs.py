#!/usr/bin/env python3
"""Write the files of a verified RomFS image (romfs.bin + index.json, from merge_romfs.py or extract_romfs.py) as a tree.

Used for the offline manual (make manual): the runtime shows its HTML pages from <work>/manual (Y Help), and a web view
needs real files. Paths come from the image's own index, which index_romfs already checked for unsafe names.

    python3 scripts/unpack_romfs.py SSBU_build/manual-image --output SSBU_build/manual
"""
import argparse
import json
from pathlib import Path


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('image', type=Path, help='a folder holding romfs.bin and index.json')
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    files = json.loads((args.image / 'index.json').read_text())['files']
    if args.output.exists():
        raise SystemExit(f'{args.output} already exists; remove it first')
    root = args.output.resolve()
    with (args.image / 'romfs.bin').open('rb') as f:
        for entry in files:
            out = (root / entry['path']).resolve()
            if root not in out.parents:
                raise SystemExit(f'unsafe path in the index: {entry["path"]}')
            out.parent.mkdir(parents=True, exist_ok=True)
            f.seek(entry['offset'])
            out.write_bytes(f.read(entry['size']))
    print(f'{len(files)} files written to {args.output}')


if __name__ == '__main__':
    main()

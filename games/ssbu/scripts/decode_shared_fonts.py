#!/usr/bin/env python3
"""Decode the Switch's shared system fonts (BFTTF, from extract_shared_fonts.py) into plain TrueType files.

The offline manual (Y Help) names the system fonts the Switch's web applet provides: its button guide uses the family
"keyhelpFont" / "KeyHelpFont", declared without a file, for the standard UI font and the Nintendo extension font (the
controller-button glyphs, U+E000-U+E1FF). make manual writes them next to the manual and the runtime's page view points
those families at them (runtime/frontend.m). BFTTF: big-endian word 0 = magic ^ key, word 1 = font size ^ key, then the
TrueType data XORed word by word with the key (the same scheme as runtime/shared_font.c).

    python3 scripts/decode_shared_fonts.py SSBU_build/extracted/firmware/shared-fonts --output <dir>
"""
import argparse
import struct
from pathlib import Path

MAGIC = 0x7f9a0218
FONTS = {'0-standard.bfttf': 'standard.ttf', '5-nintendo-extension.bfttf': 'nintendo-extension.ttf'}


def decode(data):
    key = struct.unpack_from('>I', data, 0)[0] ^ MAGIC
    size = struct.unpack_from('>I', data, 4)[0] ^ key
    if size > len(data) - 8:
        raise ValueError('BFTTF size out of range')
    body = data[8:8 + size] + bytes(-size % 4)
    words = struct.unpack(f'>{len(body) // 4}I', body)
    out = struct.pack(f'>{len(words)}I', *(w ^ key for w in words))[:size]
    if out[:4] not in (b'\x00\x01\x00\x00', b'OTTO', b'true'):
        raise ValueError('decoded data is not a TrueType / OpenType font')
    return out


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('fonts', type=Path, help='the shared-fonts folder (extract_shared_fonts.py)')
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    for source, name in FONTS.items():
        (args.output / name).write_bytes(decode((args.fonts / source).read_bytes()))
        print(f'{source} -> {args.output / name}')


if __name__ == '__main__':
    main()

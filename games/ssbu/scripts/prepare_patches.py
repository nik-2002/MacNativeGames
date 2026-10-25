#!/usr/bin/env python3
"""Turn IPSwitch .pchtxt exefs patches into checked patch tables (generic tool inherited from games/by3).

No SSBU patch set ships with this scaffold. Each patch must name main's build ID and touch only bytes the Apple-silicon
rewrite left as they were (a rewritten word would be a branch into a rewrite block). Offsets are main image offsets
(the files' `@flag offset_shift 0x100` is for the IPS container). Writes <work>/patches/<slug>.tsv ("offset new-bytes
original-bytes" in hex) and <work>/patches/index.tsv; the runtime (runtime/game_patches.c) checks the original bytes
again before writing. No game bytes come from the files beyond the replacement words they already hold.
"""
import argparse
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE / 'third_party/d2r'))   # the inherited by3 copy of the rewriter

DEFAULT_EXPECTED = HERE / 'assets/expected-v13.0.4.json'
EXPECTED = None


def load_expected(path):
    data = json.loads(path.read_text())
    if data.get('status') == 'template':
        raise SystemExit(f'{path} is still a template; run scripts/make_expected.py after your own dump is prepared.')
    return data


def slug(name):
    return re.sub(r'[^a-z0-9]+', '-', name.lower()).strip('-')


def parse(path, build_id):
    text = path.read_text(errors='replace').splitlines()
    ids = [l.split('-', 1)[1].strip().upper() for l in text if l.startswith('@nsobid-')]
    if ids != [build_id]:
        raise ValueError(f'{path}: build ID {ids} is not main 13.0.4 ({build_id})')
    patches, enabled = [], False
    for n, line in enumerate(text, 1):
        line = line.split('//', 1)[0].strip()
        if line.startswith('@enabled'): enabled = True; continue
        if line.startswith('@disabled') or line.startswith('@stop'): enabled = False; continue
        m = re.fullmatch(r'([0-9A-Fa-f]{8})\s+([0-9A-Fa-f]+)', line)
        if not m: continue
        if not enabled: continue
        if len(m.group(2)) % 2: raise ValueError(f'{path}:{n}: odd number of hex digits')
        patches.append((int(m.group(1), 16), bytes.fromhex(m.group(2)), n))
    if not patches: raise ValueError(f'{path}: no enabled patch lines')
    return patches


def main():
    global EXPECTED
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mods', type=Path, nargs='?', default=HERE / 'mods/13.0.4', help='folder of <name>/exefs/*.pchtxt')
    parser.add_argument('--work', type=Path, default=HERE / 'SSBU_build')
    parser.add_argument('--expected', type=Path, default=DEFAULT_EXPECTED,
                        help='verified hash manifest (default: assets/expected-v13.0.4.json)')
    args = parser.parse_args()
    EXPECTED = load_expected(args.expected.resolve())
    # Imported only after the template guard: nsoimg needs lz4, which is optional for this scaffold and should not hide
    # the "generate the manifest first" message on a fresh checkout.
    try:
        import nsoimg
    except ModuleNotFoundError as e:
        raise SystemExit(f'prepare_patches.py needs the Python packages in requirements.txt ({e.name} is missing).') from e
    work = args.work.resolve()
    original = nsoimg.load(work / 'extracted/v1304/exefs/main')
    rewritten = (work / 'rewritten/v1304/main.patched.bin').read_bytes()
    out = work / 'patches'; out.mkdir(exist_ok=True)
    index = []
    for f in sorted(args.mods.glob('*/exefs/*.pchtxt')):
        name = f.parents[1].name
        patches = parse(f, EXPECTED['main_build_id'])
        rows = []
        for off, new, line in patches:
            end = off + len(new)
            if end > len(original) or end > len(rewritten):
                raise ValueError(f'{f}:{line}: {off:#x}+{len(new)} beyond main')
            if rewritten[off:end] != original[off:end]:
                raise ValueError(f'{f}:{line}: {off:#x} lies on bytes the Apple-silicon rewrite changed; refusing')
            rows.append(f'{off:#x}\t{new.hex()}\t{original[off:end].hex()}')
        (out / f'{slug(name)}.tsv').write_text('# ' + name + ' (' + f.name + ')\n' + '\n'.join(rows) + '\n')
        index.append(f'{slug(name)}\t{name}\t{len(rows)}')
        print(f'{slug(name):24} {len(rows):3} patches  ({name})')
    (out / 'index.tsv').write_text('\n'.join(index) + '\n')


if __name__ == '__main__':
    main()

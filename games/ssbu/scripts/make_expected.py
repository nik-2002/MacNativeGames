#!/usr/bin/env python3
"""Write a verified hash manifest for the local SSBU 13.0.4 work folder.

This is the generator behind assets/expected-v13.0.4.json. It reads only files produced by this folder's scripts:

  <work>/extracted/v1304/exefs/{main,main.npdm,rtld,sdk,subsdk0}
  <work>/rewritten/v1304/{main,sdk,subsdk0}.patched.bin
  <work>/extracted/v1304/romfs/index.json and romfs.bin

The output contains title IDs, file names, sizes and SHA-256 hashes, never game bytes or keys. Keep it in the work folder
(the default recommendation) unless you deliberately want to pin your dump in the repository:

  python3 scripts/make_expected.py --work SSBU_build --output SSBU_build/expected-v13.0.4.json
  make prepare EXPECTED=SSBU_build/expected-v13.0.4.json

If you write it to assets/expected-v13.0.4.json, the template is replaced; that is fine for a private checkout but should
not be committed without deciding that the metadata is acceptable.
"""
import argparse
import hashlib
import json
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
VERSION = 'v1304'
MODULES = ('main', 'sdk', 'subsdk0')
EXEFS = ('main', 'main.npdm', 'rtld', 'sdk', 'subsdk0')


def sha256(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(8 << 20), b''):
            h.update(block)
    return h.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work', type=Path, default=HERE / 'SSBU_build')
    parser.add_argument('--output', type=Path, default=HERE / 'assets/expected-v13.0.4.json')
    parser.add_argument('--title', default='01006A800016E000')
    parser.add_argument('--update-title', default='01006A800016E800')
    parser.add_argument('--version', type=lambda s: int(s, 0), default=None,
                        help='numeric title version from the NSP metadata, if known; omitted by default')
    parser.add_argument('--display-version', default='13.0.4')
    parser.add_argument('--main-build-id', default=None,
                        help='override the build ID read from the NSO header at 0x40')
    args = parser.parse_args()

    work = args.work.resolve()
    exefs_dir = work / f'extracted/{VERSION}/exefs'
    rewritten_dir = work / f'rewritten/{VERSION}'
    romfs_dir = work / f'extracted/{VERSION}/romfs'

    missing = [str(exefs_dir / name) for name in EXEFS if not (exefs_dir / name).is_file()]
    missing += [str(rewritten_dir / f'{name}.patched.bin') for name in MODULES
                if not (rewritten_dir / f'{name}.patched.bin').is_file()]
    if missing:
        raise SystemExit('missing prepared files:\n  ' + '\n  '.join(missing) +
                         '\nRun extract_code.py and patch_nso.py first (see README.md).')

    exefs_sha = {name: sha256(exefs_dir / name) for name in EXEFS}
    rewritten_sha = {f'{name}.patched.bin': sha256(rewritten_dir / f'{name}.patched.bin') for name in MODULES}

    main_build_id = args.main_build_id
    if main_build_id is None:
        raw = (exefs_dir / 'main').read_bytes()[:0x60]
        if raw[:4] == b'NSO0' and len(raw) >= 0x60:
            main_build_id = raw[0x40:0x60].hex().upper()
        else:
            raise SystemExit('main is not an NSO0 image; pass --main-build-id explicitly')

    index_path = romfs_dir / 'index.json'
    image = romfs_dir / 'romfs.bin'
    base = {}
    update = {}
    romfs_entry = None
    if index_path.is_file() and image.is_file():
        index = json.loads(index_path.read_text())
        if index.get('status') != 'pass':
            raise SystemExit(f'{index_path}: status is not pass; rerun merge_romfs.py')
        if image.stat().st_size != index['romfs_size']:
            raise SystemExit(f'{image}: size differs from index.json; rerun merge_romfs.py')
        actual_sha = sha256(image)
        if actual_sha != index['romfs_sha256']:
            raise SystemExit(f'{image}: SHA-256 differs from index.json; rerun merge_romfs.py')
        base = index.get('base', {})
        update = index.get('update', {})
        romfs_entry = {
            'size': index['romfs_size'],
            'sha256': index['romfs_sha256'],
            'files': len(index.get('files', [])),
            'bytes_from_base': index.get('bytes_from_base'),
            'bytes_from_update': index.get('bytes_from_update'),
        }

    report = {
        '_comment': 'Generated locally by scripts/make_expected.py from the player\'s own SSBU 13.0.4 dump. '
                    'Contains hashes, sizes and NCA metadata only; no game bytes, keys or saves.',
        'status': 'generated',
        'title_id': args.title,
        'update_title_id': args.update_title,
        'version': args.version,
        'display_version': args.display_version,
        'main_build_id': main_build_id,
        'base_program_nca': base.get('program'),
        'update_program_nca': update.get('program'),
        'exefs_sha256': exefs_sha,
        'rewritten_sha256': rewritten_sha,
        'romfs': romfs_entry,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'status': 'generated', 'output': str(args.output.resolve()),
                      'main_build_id': main_build_id, 'exefs': len(exefs_sha),
                      'rewritten': len(rewritten_sha),
                      'romfs_sha256': romfs_entry['sha256'] if romfs_entry else None}, indent=2))


if __name__ == '__main__':
    main()

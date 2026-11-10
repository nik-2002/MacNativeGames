#!/usr/bin/env python3
"""Build the isolated Jamboree macOS target from original local inputs."""
import argparse
import getpass
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

GAME = Path(__file__).resolve().parents[1]
TITLE = '0100965017338000'
APP_NAME = 'Super Mario Party Jamboree'
LIBHAC_SHA256 = '1431267861db5ff68216315b164f10c0edab4df162cedf5429bf8a143b76de19'


def copy_tree(source, destination):
    """Copy source files without removing generated tables in the build workspace."""
    for src in sorted(source.rglob('*')):
        if (not src.is_file() or any(part in ('__pycache__', 'gen', 'obj', 'bin')
                                     or part.endswith('.dSYM') for part in src.relative_to(source).parts)):
            continue
        dst = destination / src.relative_to(source)
        dst.parent.mkdir(parents=True, exist_ok=True)
        if not dst.is_file() or src.read_bytes() != dst.read_bytes():
            shutil.copy2(src, dst)


def verify_prebuilt():
    root = GAME / 'prebuilt/macos-arm64'
    expected = set()
    for line in (root / 'SHA256SUMS').read_text().splitlines():
        digest, rel = line.split('  ', 1)
        expected.add(rel)
        if hashlib.sha256((root / rel).read_bytes()).hexdigest() != digest:
            raise ValueError(f'shader translator checksum mismatch: {rel}')
    actual = {str(p.relative_to(root)) for p in (root / 'dmsh_xlate').rglob('*') if p.is_file()}
    if actual != expected:
        raise ValueError('shader translator file set differs from SHA256SUMS')


def prepare_offline_dependencies(work, package):
    """Accept an explicit local prerequisite; never download or use a global cache."""
    package = package.expanduser().resolve()
    if not package.is_file():
        raise ValueError('local LibHac 0.19.0 package is missing; see README.md')
    if hashlib.sha256(package.read_bytes()).hexdigest() != LIBHAC_SHA256:
        raise ValueError('LibHac 0.19.0 package SHA-256 mismatch')
    feed = work / 'dependencies/nuget'
    feed.mkdir(parents=True, exist_ok=True)
    shutil.copy2(package, feed / 'libhac.0.19.0.nupkg')
    return feed


def stage(work):
    """Keep all generated code, tables and caches outside the checkout."""
    source = work / 'source'
    verify_prebuilt()
    # Prune only obsolete managed tooling when upgrading an existing workspace.
    # Otherwise copy_tree would retain removed translator sources/resources.
    for rel in ('dm/third_party/ryujinx', 'dm/gfx/tools/dmsh_xlate', 'dm/gfx/tools/dmsh_xlate_bin'):
        old = source / rel
        if old.exists():
            shutil.rmtree(old)
    copy_tree(GAME / 'runtime', source / 'dm')
    copy_tree(GAME / 'prebuilt/macos-arm64/dmsh_xlate', source / 'dm/gfx/tools/dmsh_xlate_bin')
    copy_tree(GAME / 'assets', source / 'assets')
    target = source / 'scripts/build_ipa_from_nsp.py'
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(GAME / 'third_party/nxnative/build_ipa_from_nsp.py', target)
    return source


def link_inputs(inputs, work):
    destination = work / 'input'
    destination.mkdir(parents=True, exist_ok=True)
    wanted = {p.name: p.resolve() for p in inputs.iterdir() if p.suffix.lower() in ('.nsp', '.xci')}
    if not wanted:
        raise ValueError('input folder contains no .nsp or .xci files')
    for old in destination.iterdir():
        if old.is_symlink() and old.suffix.lower() in ('.nsp', '.xci') and old.name not in wanted:
            old.unlink()
    for name, src in wanted.items():
        dst = destination / name
        if dst.is_symlink() and dst.resolve() == src:
            continue
        if dst.exists() or dst.is_symlink():
            raise ValueError(f'refusing to replace an existing input: {dst}')
        dst.symlink_to(src)
    return destination


def verify_originals(build):
    pins = json.loads((GAME / 'assets/expected-2.3.0.json').read_text())
    for name, pin in pins['modules'].items():
        data = (build / 'extract/v458752/ExeFS' / name).read_bytes()
        if len(data) != pin['size'] or hashlib.sha256(data).hexdigest() != pin['sha256']:
            raise ValueError(f'original ExeFS hash mismatch: {name}')
    return pins


def resume(work, source, language):
    """Finish from the 2.3.0 extraction already in the work directory, when the original containers are gone.
    Runs the orchestrator's own Mac stages after extraction; each is reused while its fingerprint holds."""
    build = work / 'input' / f'{TITLE}_build'
    extracted = build / 'extract/v458752'
    if not (extracted / 'RomFS').is_dir() or not (extracted / 'control.nacp').is_file():
        raise ValueError(f'no 2.3.0 extraction to resume from: {extracted}')
    verify_originals(build)
    spec = importlib.util.spec_from_file_location('build_ipa_from_nsp', source / 'scripts/build_ipa_from_nsp.py')
    nx = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(nx)
    repo = nx.find_repo(source / 'scripts/build_ipa_from_nsp.py')
    for rel in ('dm/tools', 'dm/games'):
        sys.path.insert(0, str(repo / rel))
    import game as gamemod, nacp, profile_guess
    nx.pg, nx.nacp = profile_guess, nacp   # module globals main() would set
    g = gamemod.by_title(int(TITLE, 16))
    if g is None or (bad := nx.build_mismatch(extracted, 'v458752', g)):
        raise ValueError(f'extraction is not the registered 2.3.0 build: {bad if g else "no game profile"}')
    # The same environment main() gives its stages: tool paths, workers, and every path inside the build folder.
    env = dict(environment(work), PATH=os.pathsep.join([os.environ.get('PATH', '/usr/bin:/bin:/usr/sbin:/sbin')] + nx.TOOL_PATHS),
               DM_ROOT=str(build), WORK=str(build / 'tmp'))
    env.setdefault('USER', getpass.getuser())
    env.setdefault('J', str(os.cpu_count() or 8))
    (build / 'tmp').mkdir(exist_ok=True)
    py, logs, xlate = sys.executable, build / 'logs', repo / 'dm/gfx/tools/dmsh_xlate_bin/dmsh_xlate'
    nx.PROG.mode = nx.progress_mode('lines')
    try:
        nx.check_prereqs(env, xlate, mac=True)
        lang = nx.game_language(language, True, nacp.languages(extracted / 'control.nacp'))
        src = profile_guess.build_sources(extracted / 'ExeFS', extracted / 'RomFS', g.words('modules'))
        extra = [k for k in ('glslc_capture', 'ue_decode', 'oodle_packs', 'ue_legacy') if src[k][0]]
        if src['graphics'][0] != 'nvn' or extra:
            raise ValueError(f'resume covers only the NVN shader chain: {src["graphics"][0]} {" ".join(extra)}')
        nx.PROG.plan(4)
        patched = build / 'patched_v458752'
        nx.rewrite(py, repo, extracted / 'ExeFS', patched, env, logs, g)
        nx.chain_header(py, repo, env, logs)
        shader = build / 'shader'
        key = nx.split_shaders(py, repo, [extracted / 'RomFS'], [extracted / 'ExeFS/main'], shader / 'pkg', env, logs, g)
        libraries = nx.build_shaders(py, repo, shader, xlate, env, logs, g, key, mac=True)
        nx.mac_run(py, repo, build, extracted, patched, libraries, None, 'nvn', lang, env, logs, g)
    except nx.BuildError as error:
        raise ValueError(str(error)) from error
    finally:
        nx.PROG.close(ok=False)
    return build, lang


def make_icon(image, icns, scratch):
    """The game's own icon (the control data's icon.jpg) as an .icns, at every size Finder and the Dock ask for."""
    iconset = scratch / 'AppIcon.iconset'
    iconset.mkdir(parents=True)
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            name = f'icon_{size}x{size}' + ('@2x' if scale == 2 else '') + '.png'
            subprocess.run(['sips', '-s', 'format', 'png', '-z', str(size * scale), str(size * scale), str(image),
                            '--out', str(iconset / name)], check=True, capture_output=True)
    subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o', str(icns)], check=True)
    shutil.rmtree(iconset)


def copy_game_tree(src, dst):
    """APFS clones where the volume allows them (cp falls back to a full copy), so the RomFS is not stored twice."""
    subprocess.run(['cp', '-c', '-R', '-p', str(src), str(dst)], check=True)


def package(source, build, output, language):
    """Package only after the source build succeeds. Never rewrite a patched binary."""
    if output.suffix != '.app':
        raise ValueError('--output must end in .app')
    if output.exists():
        raise ValueError(f'output exists; choose a new path or move it aside: {output}')
    pins = verify_originals(build)
    profile = source / f'dm/games/{TITLE}'
    # Prevent packaging a cache from a different chain or profile.
    env = dict(os.environ, DM_GAME=TITLE)
    chain_tool = source / 'dm/gfx/tools/dmsh_chain.py'
    chain = subprocess.check_output([sys.executable, str(chain_tool)], env=env, text=True).strip()
    inputs = subprocess.check_output([sys.executable, str(chain_tool), '--inputs'], env=env, text=True).strip()
    libraries = build / 'shader/cache' / f'b-{chain}'
    stamp = dict(line.split('\t', 1) for line in (libraries / 'inputs.tsv').read_text().splitlines() if '\t' in line and not line.startswith('#'))
    if stamp != {'game': TITLE, 'inputs': inputs}:
        raise ValueError('shader library stamp differs from the source profile')
    required = [build / 'tools/dmhost', build / 'patched_v458752/build_src.sha256',
                build / 'font/nintendo_ext.ttf', profile / 'c1_full.tsv', profile / 'cb_extent.tsv']
    for path in required:
        if not path.is_file():
            raise ValueError(f'incomplete build: {path}')
    for name in ('c1_full.tsv', 'cb_extent.tsv'):
        if not (profile / name).read_text().splitlines()[0].startswith(f'# chain b-{chain} inputs {inputs} '):
            raise ValueError(f'stale shader table: {name}')
    partial = output.with_name(output.stem + '.partial.app')
    if partial.exists():
        raise ValueError(f'partial output exists; inspect or remove it first: {partial}')
    resources = partial / 'Contents/Resources/game'
    macos = partial / 'Contents/MacOS'
    resources.mkdir(parents=True)
    macos.mkdir(parents=True)
    try:
        for src, name in [(build / 'extract/v458752/RomFS', 'RomFS'),
                          (build / 'patched_v458752', 'patched'), (build / 'font', 'font'),
                          (profile, 'profile')]:
            copy_game_tree(src, resources / name)
        (resources / 'shader-cache').mkdir()
        copy_game_tree(libraries, resources / 'shader-cache' / libraries.name)
        shutil.copy2(build / 'tools/dmhost', resources / 'dmhost')
        (resources / 'language.txt').write_text(language + '\n')
        icon = {}
        if (build / 'extract/v458752/icon.jpg').is_file():
            make_icon(build / 'extract/v458752/icon.jpg', partial / 'Contents/Resources/AppIcon.icns', build / 'tmp')
            icon = {'CFBundleIconFile': 'AppIcon'}
        with (partial / 'Contents/Info.plist').open('wb') as stream:
            plistlib.dump({**icon, 'CFBundleExecutable': 'Jamboree', 'CFBundleIdentifier': 'org.macnativegames.jamboree',
                          'CFBundleName': APP_NAME, 'CFBundleDisplayName': APP_NAME,
                          'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '2.3.0',
                          'CFBundleVersion': '458752', 'LSMinimumSystemVersion': '26.0',
                          'NSHighResolutionCapable': True, 'LSApplicationCategoryType': 'public.app-category.games'}, stream)
        subprocess.run(['clang', '-arch', 'arm64', '-mmacosx-version-min=26.0', '-O2', '-Wall', '-Wextra', '-Werror', str(GAME / 'app/launcher.c'),
                        '-o', str(macos / 'Jamboree')], check=True)
        # Sign the nested executable before recording its final content hash.
        subprocess.run(['codesign', '--force', '--sign', '-', str(resources / 'dmhost')], check=True)
        # Preserve the rewriter's rule hashes; add portable build provenance for reviewers.
        report = {'game': pins, 'chain': chain, 'shader_inputs': inputs, 'language': language,
                  'host_sha256': hashlib.sha256((resources / 'dmhost').read_bytes()).hexdigest(),
                  'rewrite_rules': (build / 'patched_v458752/build_src.sha256').read_text()}
        (resources / 'build-info.json').write_text(json.dumps(report, indent=2) + '\n')
        # Sign nested Mach-O files explicitly, then the bundle, without touching game data.
        subprocess.run(['codesign', '--force', '--sign', '-', str(partial)], check=True)
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(partial)], check=True)
        output.parent.mkdir(parents=True, exist_ok=True)
        partial.rename(output)
    except Exception:
        # Retain a failed package for inspection; never overwrite a working app.
        raise
    print(f'Built {output}\nSave: ~/Library/Application Support/{APP_NAME}/save')


def environment(work):
    env = dict(os.environ, DM_GAME=TITLE, DM_METAL_RUNTIME='1',
               TMPDIR=str(work / 'tmp'), NUGET_PACKAGES=str(work / 'cache/nuget'),
               DOTNET_CLI_HOME=str(work / 'cache/dotnet'), PYTHONDONTWRITEBYTECODE='1',
               DM_NUGET_SOURCE=str(work / 'dependencies/nuget'),
               DOTNET_CLI_TELEMETRY_OPTOUT='1', DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1',
               DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE='true',
               MACOSX_DEPLOYMENT_TARGET='26.0')
    for key in ('TMPDIR', 'NUGET_PACKAGES', 'DOTNET_CLI_HOME'):
        Path(env[key]).mkdir(parents=True, exist_ok=True)
    # The translator's apphost looks only in the default install locations; a Homebrew .NET is elsewhere.
    if 'DOTNET_ROOT' not in env and (root := dotnet_root(env)):
        env['DOTNET_ROOT'] = root
    return env


def dotnet_root(env):
    """The folder holding shared/Microsoft.NETCore.App of the dotnet on PATH (a Homebrew dotnet is a wrapper script elsewhere)."""
    dotnet = shutil.which('dotnet', path=os.pathsep.join([env.get('PATH', ''), '/opt/homebrew/bin', '/usr/local/bin']))
    if not dotnet:
        return None
    listing = subprocess.run([dotnet, '--list-runtimes'], capture_output=True, text=True, env=env).stdout
    for line in listing.splitlines():
        if line.startswith('Microsoft.NETCore.App ') and line.endswith(']'):
            return str(Path(line[line.index('[') + 1:-1]).parent.parent)
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('inputs', nargs='?', type=Path, help='folder with base NSP/XCI and 2.3.0 update NSP')
    parser.add_argument('--keys', type=Path, help='your local prod.keys (never copied into the app)')
    parser.add_argument('--libhac-package', type=Path,
                        help='local LibHac 0.19.0 .nupkg (SHA-256 pinned; no download)')
    parser.add_argument('--resume', action='store_true',
                        help='finish from the 2.3.0 extraction already in --work-dir (no containers, keys or LibHac)')
    parser.add_argument('--work-dir', required=True, type=Path, help='private build directory outside the checkout')
    parser.add_argument('--output', required=True, type=Path, help='new .app output path')
    parser.add_argument('--language', default='en-US', choices=('en-US', 'en-GB', 'ja', 'fr', 'de', 'es-419', 'es', 'it', 'nl', 'fr-CA', 'ru', 'ko', 'zh-Hant', 'zh-Hans', 'pt-BR'), help='game language, e.g. en-US or zh-Hans')
    args = parser.parse_args()
    work, output = args.work_dir.expanduser().resolve(), args.output.expanduser().resolve()
    if output.exists():
        parser.error(f'output already exists: {output}')
    checkout = GAME.parents[1]
    if any(path == checkout or checkout in path.parents for path in (work, output)):
        parser.error('--work-dir and --output must be outside the checkout to keep game content out of Git')
    if args.resume:
        if args.inputs or args.keys or args.libhac_package:
            parser.error('--resume builds from the existing extraction; give no inputs, --keys or --libhac-package')
        if not work.is_dir():
            parser.error(f'--resume needs an existing work directory: {work}')
        source = stage(work)
        build, language = resume(work, source, args.language)
        package(source, build, output, language)
        return
    if not (args.inputs and args.keys and args.libhac_package):
        parser.error('inputs, --keys and --libhac-package are required (or --resume)')
    if not args.inputs.expanduser().is_dir() or not args.keys.expanduser().is_file():
        parser.error('inputs folder and keys must exist')
    work.mkdir(parents=True, exist_ok=True)
    prepare_offline_dependencies(work, args.libhac_package)
    source = stage(work)
    inputs = link_inputs(args.inputs.expanduser().resolve(), work)
    env = environment(work)
    subprocess.run([sys.executable, str(source / 'scripts/build_ipa_from_nsp.py'), str(inputs),
                    '--keys', str(args.keys.expanduser().resolve()), '--package', 'v458752',
                    '--platform', 'mac', '--language', args.language, '--progress', 'lines'], env=env, check=True)
    package(source, inputs / f'{TITLE}_build', output, args.language)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(f'error: {error}')

#!/usr/bin/env python3
"""Compile the translated shaders of the work folder into Metal libraries the runtime loads instead of compiling.

The runtime translates each Switch shader to MSL once and keeps it in build/shader-cache/rt-<chain>/ (the shader
prefetch fills it with every shader the game sets, about 11,000). Compiling that MSL with Metal at run time costs tens of
milliseconds per library; with the full cache the start-up warm-up waited 94 s for it (2026-10-25). The runtime loads
build/shader-libs/<SHA-256 of the MSL>.metallib when it is there (nvn_mtl.m shader_lib_prebuilt_path), so this script
compiles every cached MSL ahead of time with Xcode's offline Metal compiler, with the runtime's safe math
(totk_precise_opts). Only missing libraries are compiled; a library is keyed by the exact source, so a stale one is never
used.

    xcodebuild -downloadComponent MetalToolchain      (once)
    python3 scripts/prepare_shader_libs.py --work SSBU_build
    python3 scripts/prepare_shader_libs.py --cache-root ~/Library/Application\ Support/MacNativeGames/SSBU   (the app's cache)
"""
import argparse
import concurrent.futures
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import time


def metal_compiler():
    """(path of Xcode's offline Metal compiler, environment) or None."""
    env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
    found = subprocess.run(['xcrun', '--find', 'metal'], capture_output=True, text=True, env=env)
    metal = found.stdout.strip()
    if found.returncode or not metal:
        return None
    if subprocess.run([metal, '--version'], capture_output=True, env=env).returncode:
        return None
    return metal, env


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--work', type=Path, default=Path('SSBU_build'), help='the work folder (default: SSBU_build)')
    p.add_argument('--cache-root', type=Path,
                   help='where shader-cache/ and shader-libs/ live (the app: ~/Library/Application Support/MacNativeGames/SSBU; '
                        'default: <work>/build)')
    p.add_argument('--jobs', type=int, default=max(1, min(8, (os.cpu_count() or 4) - 2)))
    args = p.parse_args(argv)
    build = args.cache_root or args.work / 'build'
    caches = sorted(build.glob('shader-cache/rt-*'))
    if not caches:
        raise SystemExit(f'no translation cache in {build}/shader-cache')
    found = metal_compiler()
    if not found:
        raise SystemExit('Xcode has no Metal toolchain: xcodebuild -downloadComponent MetalToolchain')
    metal, env = found
    libs = build / 'shader-libs'
    libs.mkdir(parents=True, exist_ok=True)
    todo = {}
    total = 0
    for cache in caches:
        for src in cache.glob('*_b.metal'):
            total += 1
            digest = hashlib.sha256(src.read_bytes()).hexdigest()
            if not (libs / f'{digest}.metallib').is_file():
                todo.setdefault(digest, src)
    print(f'{total} translated shaders, {len(todo)} without a library; compiling with {args.jobs} jobs', flush=True)

    def compile_one(item):
        digest, src = item
        partial = libs / f'{digest}.partial'
        r = subprocess.run([metal, '-fmetal-math-mode=safe', '-o', str(partial), str(src)], capture_output=True, text=True, env=env)
        if r.returncode:
            partial.unlink(missing_ok=True)
            return f'{src.name}\n{r.stdout}{r.stderr}'
        partial.replace(libs / f'{digest}.metallib')
        return None

    t0, failed, done = time.time(), [], 0
    with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
        for message in pool.map(compile_one, todo.items()):
            done += 1
            if message:
                failed.append(message)
            if done % 500 == 0:
                print(f'  {done} / {len(todo)} ({time.time() - t0:.0f} s)', flush=True)
    print(f'compiled {len(todo) - len(failed)} libraries in {time.time() - t0:.0f} s; {len(failed)} failed', flush=True)
    if failed:
        (build / 'shader-libs.log').write_text('\n\n'.join(failed))
        print(f'the failed ones (see {build}/shader-libs.log) are compiled by the game when it meets them')
    return 0


if __name__ == '__main__':
    sys.exit(main())

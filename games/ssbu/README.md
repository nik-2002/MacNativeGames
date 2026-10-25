# Super Smash Bros. Ultimate (native port scaffold)

This folder is a **stage 0 scaffold** for running Super Smash Bros. Ultimate natively on Apple silicon, using the
MacNativeGames approach (native ARM64 execution with a Horizon host and NVN-on-Metal), not static recompilation.

It is forked from `games/by3` because that port already has the CMIF domains, `audout:u`, per-stage NVN binding,
indirect draws/dispatch, `ClearBuffer`, `TexturePoolRegisterImage`, `QueueWaitSync` and 60 Hz pacing that SSBU needs.
The by3 game-specific patches and service answers are inherited placeholders, not SSBU facts. Nothing here has booted
SSBU yet.

**You must own the game and its keys.** No game data, assets, keys, firmware, NRO/NSO images or saves are in this
repository. The work folder (`SSBU_build/`) and `mods/` are ignored by git.

- Target: base `01006A800016E000`, update `01006A800016E800`, version **13.0.4** first.
- First scope: offline local play (versus/CPU), picture, sound, input and saves.
- Out of scope for now: online/NPLN, amiibo/NFP, GameCube adapter (WUP-028).

Read [docs/port-plan.md](docs/port-plan.md) for the plan and blockers, [docs/nro.md](docs/nro.md) for the NRO work, and
[docs/existing-ports.md](docs/existing-ports.md) for the separate GPL-3.0 OpenSmash Mac build (reference only).

## What is already here

- `runtime/`: Horizon host, ExeFS loader, services, RomFS, input, audio, frontend.
- `third_party/d2r/`: the NSO rewriter inherited from by3.
- `third_party/d2r_gfx/`: the NVN-on-Metal layer inherited from by3.
- `prebuilt/macos-arm64/totk_xlate`: the shader translator, reused unchanged for now.
- `scripts/`: extraction, RomFS merge, rewrite helpers, the new `make_expected.py` and the experimental `extract_nros.py`.
- `assets/expected-v13.0.4.json`: a clearly marked **template** with no real hashes.
- `runtime/nro_loader.c`: a loud NRO stub; the NRO pipeline is not implemented.

## Inputs

- Base NSP `01006A800016E000`.
- Update NSP `01006A800016E800` at 13.0.4.
- `prod.keys` from your own console.
- Optional system shared fonts from your own firmware if the game asks for them.

The base/update NCAs are read locally; keys stay in memory. The inherited `merge_romfs.py` assumes the by3 sparse-base +
BKTR update shape. **Validate that assumption for SSBU before trusting the merge**; if SSBU's base is a normal NCA, add
that path rather than repacking `data.arc`.

## Build (once you have your own dump)

From `games/ssbu`, with a Python environment from `requirements.txt`:

```sh
python3 scripts/extract_code.py "<update>.nsp" --keys prod.keys \
  --output SSBU_build/extracted/v1304/exefs
python3 scripts/merge_romfs.py "<base>.nsp" "<update>.nsp" --keys prod.keys \
  --output SSBU_build/extracted/v1304/romfs

for m in sdk subsdk0 main; do
  DM_RULESET=native DM_PRIVATE_GATES=0 python3 third_party/d2r/patch_nso.py \
    SSBU_build/extracted/v1304/exefs/$m SSBU_build/rewritten/v1304 $m
done
python3 scripts/prepare_modules.py SSBU_build/extracted/v1304/exefs \
  --output SSBU_build/extracted/v1304/elf

# Fill in the hashes from your dump (kept in the work folder, not the repo)
python3 scripts/make_expected.py --work SSBU_build \
  --output SSBU_build/expected-v13.0.4.json
make prepare EXPECTED=SSBU_build/expected-v13.0.4.json
make runtime
make app GAME="<update>.nsp" KEYS=prod.keys
open "Super Smash Bros. Ultimate.app"
```

`make prepare` without a generated manifest stops with an explanation: the checked-in
`assets/expected-v13.0.4.json` is a template, not a set of real hashes.

The app runs the game from `SSBU_build`; do not move or delete it while the app is installed.

## NRO modules (next milestone)

SSBU keeps roughly 98 `lua2cpp_*` NRO modules inside `data.arc`. The planned pipeline is:

1. inventory them with `make nros` (experimental signature scan, not an ARC parser);
2. rewrite each NRO into a native sidecar keyed by build ID;
3. implement `runtime/nro_loader.c` and the `nn::ro` shim;
4. keep `data.arc` intact and substitute the verified sidecar at `LoadModule` time.

This is not done. `runtime/nro_loader.c` is a stub that would report the requested module and build size; it is not
registered in the override table, so the first boot will stop at the first missing `nn::ro` call rather than execute an
unrewritten module. See [docs/nro.md](docs/nro.md).

## Inherited by3 behavior to re-check

Search for `TODO(ssbu)` and read the notes in `docs/port-plan.md`. The important inherited assumptions are:

- the three-module ExeFS layout and `prepare_runtime.py`'s symbol/relocation/`DT_INIT` checks;
- by3 service answers in `runtime/system_services.c` (network offline, `ExecuteProgram`, `set`/`bsd:u`);
- by3 patch presets and offsets (`make_res_patch.py`, `runtime/game_patches.c`);
- by3 NVN paths and comments in `third_party/d2r_gfx` (historical, not SSBU-verified);
- the Wwise `audout:u` path (SSBU uses Opus; the inherited path may be unused);
- the sparse-base/BKTR RomFS merge.

## Optional patches and mods

`mods/13.0.4/<name>/exefs/*.pchtxt` and `mods/<name>/romfs/` are supported by the inherited tooling, but no SSBU patch
set ships here. The by3 resolution/LOD offsets do not apply to SSBU; add SSBU sites and a build-ID check first.

## Licensing

MacNativeGames is MIT. The by3 fork keeps its third-party notices (`third_party/d2r/LICENSE`, `third_party/d2r_gfx/LICENSE`,
`third_party/licenses/`). OpenSmash-Ultimate and public decompilation projects are reference material only; do not copy
GPL-3.0 code into this tree.

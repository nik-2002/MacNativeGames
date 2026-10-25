# Super Smash Bros. Ultimate port: work log

## 2026-10-21 — stage 0 scaffold

- Forked `games/by3` into `games/ssbu` as the SSBU runtime base. The by3 port already had the CMIF domains, `audout:u`,
  per-stage NVN binding, indirect draws/dispatch, `ClearBuffer`, `TexturePoolRegisterImage`, `QueueWaitSync` and 60 Hz
  pacing that SSBU needs; TotK was the wrong starting point for those paths.
- Changed the identity mechanically: `SSBU`/`ssbu`, `Super Smash Bros. Ultimate`, work folder `SSBU_build`, binary
  `ssbu-native`, bundle `org.macnativegames.ssbu`, log `ssbu.log`, version directory `v1304`, version `13.0.4`.
- Title IDs: base `01006A800016E000`, update `01006A800016E800`.
- `runtime/game_version.h` now defines `GAME_SSBU`, the version directory and the title IDs, and deliberately does not
  guess the main build ID.
- `assets/expected-v13.0.4.json` is a marked template. `prepare_runtime.py` and `prepare_patches.py` refuse to use it until
  it is generated from the player's own dump. `scripts/make_expected.py` generates the manifest from the local work folder.
- Added `scripts/extract_nros.py` (experimental `NRO0` scanner for `data.arc`), `runtime/nro_loader.c/.h` (loud stub) and
  `docs/nro.md` (sidecar, rewrite and `nn::ro` plan).
- Added `docs/port-plan.md`: target 13.0.4, offline scope, pipeline, inherited assumptions, blockers and milestones.
- Added `docs/existing-ports.md`: surveyed OpenSmash-Ultimate's experimental native Apple Silicon build (static
  recompilation plus Vulkan/MoltenVK, GPL-3.0) and recorded it as reference only, not a code dependency. Linked it from
  the plan, README and licensing notes.
- Recorded the read-only USB dry run in `docs/port-plan.md`: base/update RARs and NSP sizes, update CNMT identity
  (`01006A800016E800`, version 1966080 = 13.0.4), key-file coverage and the tight internal disk budget. Nothing was
  extracted.
- Reworked the launcher for the first port: fixed 60 Hz present pacing, no by3 30/120/fixed-900p/LOD/film-grain presets,
  no patch table assumptions. The RomFS mod slot, monitor/window/full-screen/output/MetalFX settings and HUD remain.
- Added SSBU paths to the repository `.gitignore`; the per-game ignore file also covers `SSBU_build/`, `mods/`, extracted
  data, `data.arc`, NRO/NSO images and patch files.
- Updated inherited comments where the mechanical rename would have made false claims about SSBU. The NVN layer keeps its
  historical "Bayonetta 3" comments and now says so explicitly in `third_party/d2r_gfx/README.md`.
- `scripts/make_res_patch.py` and `scripts/prepare_patches.py` are retained as generic/inherited tooling; the resolution
  offsets are Bayonetta 3 offsets and are marked as not applicable to SSBU.

### Status

Not bootable yet. No game data, keys or NRO/NSO images are in the tree. The next work is the NRO pipeline and the first
SSBU boot, in that order (see `docs/port-plan.md`).

### Known gaps

- 98 `lua2cpp_*` NRO modules: extraction is experimental, rewriting and `nn::ro` loading are TODO.
- The inherited `prepare_runtime.py` assumes the by3 three-module layout and `DT_INIT` shape; validate against SSBU.
- The inherited `merge_romfs.py` assumes a sparse base + BKTR update; validate SSBU's base/update shape.
- by3 service answers, patch offsets and NVN paths are unverified for SSBU.
- No SSBU shader seed/cache; shader stutter and missing translations are expected.
- SSBU uses Opus; the inherited Wwise `audout:u` path may be unused.
- Input mapping, saves, local two-player behavior and 60 Hz pacing need direct testing.

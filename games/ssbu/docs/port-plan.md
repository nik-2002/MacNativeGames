# SSBU native port: plan and status

Status: **stage 0 scaffold.** The folder is a fork of `games/by3` with SSBU identity and a working shape, but it has not
booted SSBU. No game data, keys, saves or NRO/NSO images are in this repository. The USB dump has been inspected
read-only; nothing has been extracted. A separate GPL-3.0 Mac build exists (OpenSmash-Ultimate); see
[existing-ports.md](existing-ports.md).

## Target

- Super Smash Bros. Ultimate, base title `01006A800016E000`, update title `01006A800016E800`.
- Target version **13.0.4** first. 13.0.5 is a later delta and can follow once 13.0.4 is stable.
- Native ARM64 execution on Apple silicon, using the MacNativeGames rewriter/Horizon host/NVN-on-Metal approach. This is
  not static recompilation.
- First milestone: offline local play (versus/CPU) with picture, sound, keyboard/controller input and saves.
- Out of scope for the first port: online/NPLN, amiibo/NFP, GameCube adapter (WUP-028), DLC entitlement checks beyond
  making the update's own data usable.

## Why by3 is the base

`games/by3` already contains the pieces SSBU needs and TotK does not exercise as directly:

- CMIF domain handling and `audout:u`;
- per-stage NVN program binding, indirect draws/dispatch, `ClearBuffer`, `TexturePoolRegisterImage`, `QueueWaitSync`;
- 60 Hz present pacing (SSBU is a 60 fps game; no real-time frame-step patch is assumed).

The by3 game-specific patches, service answers and comments are **not** evidence about SSBU. They are inherited code to
re-validate, and the scaffold marks the important ones with `TODO(ssbu)`.

## Existing Mac port (reference only)

OpenSmash-Ultimate (`Denkishi/ssbu-recomp`) is a static recompilation of SSBU 13.0.4/13.0.5. Its `main` branch now has an
experimental native Apple Silicon build (`BUILDING_MAC.md`, `play_mac.sh`): SDL3 for the window/input/audio and Vulkan
through MoltenVK for graphics. It is a native arm64 program, but it is not an NVN-on-Metal renderer.

It does not replace this scaffold, and I found no dedicated NVN-on-Metal SSBU Mac port. OpenSmash is **GPL-3.0**, so its
code and generated tables are reference material only. See [existing-ports.md](existing-ports.md) for links, requirements,
status and the license boundary.

## Inputs (player-supplied, never committed)

- Base NSP `01006A800016E000`.
- Update NSP `01006A800016E800` at 13.0.4.
- `prod.keys` from the player's own console.
- Optional: system shared fonts extracted from the player's firmware if SSBU asks for them.

The base and update are used only to build a local work folder (`SSBU_build/`, ignored by git). The repository ships a
hash **template**, not hashes from a real dump.

## USB dry run (2026-10-21)

Read-only inspection of the player's dump on an external drive. Nothing was extracted or modified.

- The base NSP is 14,638,743,603 bytes. Its ticket name carries title
  `01006A800016E000`; the program NCA is 14,531,444,736 bytes.
- The update NSP is 3,931,425,356 bytes. Its `cnmt.xml` says `Type Patch`, `Id 0x01006a800016e800`, `Version 1966080`; public listings map version
  1966080 to 13.0.4. The program NCA is 3,891,200,512 bytes.
- Keys: the player's `prod.keys` has 231 entries, including `header_key`,
  `key_area_key_application_07`, `titlekek_07` and `eticket_rsa_kek`.
- Internal free space is about 35–37 GiB. The two NSPs alone are about 17.3 GiB; a merged RomFS and build artifacts will
  not fit comfortably. Free internal space is required before the full build; external volumes are cold storage only
  (see the workspace `AGENTS.md`).

## Pipeline

```sh
# 1. Code and RomFS (local work folder)
python3 scripts/extract_code.py "<update>.nsp" --keys prod.keys \
  --output SSBU_build/extracted/v1304/exefs
python3 scripts/merge_romfs.py "<base>.nsp" "<update>.nsp" --keys prod.keys \
  --output SSBU_build/extracted/v1304/romfs

# 2. Rewrite the three ExeFS modules (inherited by3 pipeline; validate the SSBU layout first)
for m in sdk subsdk0 main; do
  DM_RULESET=native DM_PRIVATE_GATES=0 python3 third_party/d2r/patch_nso.py \
    SSBU_build/extracted/v1304/exefs/$m SSBU_build/rewritten/v1304 $m
done
python3 scripts/prepare_modules.py SSBU_build/extracted/v1304/exefs \
  --output SSBU_build/extracted/v1304/elf

# 3. Pin the local hashes, then generate runtime tables
python3 scripts/make_expected.py --work SSBU_build \
  --output SSBU_build/expected-v13.0.4.json
make prepare EXPECTED=SSBU_build/expected-v13.0.4.json

# 4. Build the host (needs the generated headers from step 3)
make runtime
make app GAME="<update>.nsp" KEYS=prod.keys
```

`make nros` runs the experimental `data.arc` scan; it is the start of the NRO milestone, not a working loader.

## Runtime architecture

- `runtime/loader.c`: maps and relocates the ExeFS modules from `rewritten/v1304`.
- `runtime/services.c`: dispatches host overrides and SVCs.
- `runtime/system_services.c`: inherited by3 service answers; SSBU's service survey is TODO.
- `runtime/romfs.c`: read-only RomFS backed by the verified merged image.
- `runtime/game_patches.c`: generic patch-table applier; no SSBU patch set yet.
- `third_party/d2r_gfx`: NVN-on-Metal layer; inherited, with by3-specific paths unverified for SSBU.
- `runtime/nro_loader.c`: NRO boundary stub; see [nro.md](nro.md).

## Known blockers, in order

1. **NRO pipeline.** 98 `lua2cpp_*` modules in `data.arc`; extraction, rewrite, sidecar and `nn::ro` shim are not done.
2. **First boot.** The SSBU `main`/`sdk`/`subsdk0` layout must satisfy the inherited `prepare_runtime.py` assumptions
   (three modules, symbol/relocation tables, `DT_INIT` shape, PLT probe).
3. **Service survey.** Follow every unimplemented service/NVN call from the first boot. by3's answers are a starting
   point, not a specification.
4. **Shader pipeline.** No SSBU shader seed/cache; expect stutter and missing translations until the inventory is built.
5. **Input latency and mapping.** SSBU's two-player/local expectations, controller layout and 60 Hz pacing need direct
   measurement.
6. **Audio.** SSBU uses Opus; the inherited `audout:u`/Wwise path may be unused, and the Opus decoder path needs testing.
7. **RomFS layout.** Validate that the by3 sparse-base/BKTR merge matches SSBU's base and update; do not repack `data.arc`.
8. **Disk budget.** The internal volume has about 35 GiB free; the NSPs, merged RomFS and build artifacts do not fit
   comfortably. Free internal space is required before a full extraction/build; external volumes are cold storage only.

## Milestones

- **M0 (this tree):** scaffold, identity, docs, hash template, NRO scanner, loud NRO stub.
- **M1:** extract and rewrite the three ExeFS modules; `make prepare` + `make runtime` succeed against a local dump.
- **M2:** first boot to `nnMain`, then to the first `nn::ro::LoadModule`.
- **M3:** load one `lua2cpp_*` sidecar and call a known export.
- **M4:** title/menu with picture and sound.
- **M5:** offline versus/CPU match; input, saves, 60 Hz pacing.
- **Later:** 13.0.5, more modes, performance, optional online/amiibo/GameCube adapter work.

## Licensing and provenance

MacNativeGames is MIT. The scaffold is forked from `games/by3` and keeps its third-party notices. OpenSmash-Ultimate and
public decompilation projects are reference material only; do not copy GPL-3.0 code into this tree. See
[existing-ports.md](existing-ports.md). Game data and keys remain the player's responsibility and are never committed.

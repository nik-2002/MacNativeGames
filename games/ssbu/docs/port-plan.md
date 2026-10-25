# SSBU native port: plan and status

Status (2026-10-25): **offline play works.** 13.0.4 boots to the menus and plays matches with correct rendering, sound,
saves, up to eight controllers, DLC from the player's own dump, the in-game manual and controller text entry. No game data,
keys, saves, shaders or NRO/NSO images are in this repository. A separate GPL-3.0 Mac build exists (OpenSmash-Ultimate);
see [existing-ports.md](existing-ports.md). The history is in [../CHANGELOG.md](../CHANGELOG.md).

## Target

- Super Smash Bros. Ultimate, base title `01006A800016E000`, update title `01006A800016E800`.
- Target version **13.0.4** first. 13.0.5 is a later delta and can follow once 13.0.4 is stable.
- Native ARM64 execution on Apple silicon, using the MacNativeGames rewriter/Horizon host/NVN-on-Metal approach. This is
  not static recompilation.
- First milestone: offline local play (versus/CPU) with picture, sound, keyboard/controller input and saves.
- Out of scope for the first port: online/NPLN, amiibo/NFP, GameCube adapter (WUP-028). DLC is supported from the
  player's own add-on NSPs (`make dlc`).

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

The full command list is in the [README](../README.md#build). In short: extract the ExeFS code, merge the base and update
RomFS (the base is a plain NCA, the update a BKTR patch; `merge_romfs.py` handles both), extract the shared fonts, rewrite
the three ExeFS modules, extract and rewrite the 98 NRO modules (`make nros`, `prepare_nros.py`), pin the dump's hashes,
`make prepare runtime shader-tools`, then optionally `make dlc` and `make manual`, and `make app`. After a session that met
new shaders, `scripts/prepare_shader_libs.py` compiles them into Metal libraries.

All of it runs on the internal disk; copy inputs off external drives first (workspace `AGENTS.md`).

## Runtime architecture

- `runtime/loader.c`: maps and relocates the ExeFS modules from `rewritten/v1304`.
- `runtime/nro_loader.c`: `nn::ro`; maps the rewritten `lua2cpp_*` modules from the generated catalog ([nro.md](nro.md)).
- `runtime/services.c`, `runtime/system_services.c`: host overrides and SVCs; `nn::aoc` reports the DLC manifest;
  `nn::web::ShowOfflineHtmlPage` opens the manual.
- `runtime/romfs.c`: read-only RomFS backed by the verified merged image (verification record per image).
- `runtime/input.c`, `runtime/gamepad.m`, `runtime/hid_feedback.c`, `runtime/gamepad_feedback.m`: keyboard and
  per-player controllers, rumble, motion, player lamps.
- `runtime/frontend.m`: window, loading screen, text-entry bar with on-screen keyboard, manual page view.
- `runtime/movie_host.c`: VP9 movies through libvpx (no host pacing for Smash).
- `runtime/game_patches.c`: SSBU code patches (glyph lookup).
- `third_party/d2r_gfx`: NVN-on-Metal (per-pool texture and sampler ids, alpha-test emulation, shader prefetch,
  precompiled libraries, start-up warm-up).

## Open problems

1. **Pipelines met for the first time.** `make shaders` translates and compiles every shader in `data.arc` ahead of play
   (2026-10-26), but a new combination of shaders and render state still builds its Metal pipeline at its first draw
   (tens of ms each); it is recorded and built at the next start.
2. **Start-up time.** The loading screen waits 3–9 s for about 8,000 pipelines, and the background top-up then loads
   about 36,000 libraries (about 35 s on two low-priority threads). A Metal binary archive could cut both.
3. **Old cache in the app bundle.** Since 2026-10-26 the cache lives in Application Support; a bundle copied before then
   still carries its old `build/shader-cache` (unused, APFS-cloned, harmless).
4. **Rare boot crash** in `movie::Buffer::Base` (`subsdk0+0x23b40`), seen once before the movie-pacing fix; not seen since.
5. **Unverified:** the ZR side-menu highlight, a white wedge on the Smash submenu, the player-lamp icon with two
   controllers, and on-screen keyboard navigation on every controller type.
6. **Out of scope:** online play, amiibo, the GameCube adapter, 13.0.5.

Testing note: an agent's test window starts unfocused, and macOS then keeps the game on the efficiency cores. Frame times
from such runs are not representative; use a run from the player's own foreground window
(`~/Library/Logs/MacNativeGames/ssbu.log`).

## Milestones

- **M0 (2026-10-21):** scaffold, identity, docs, hash template, NRO scanner.
- **M1–M3 (2026-10-25):** ExeFS rewrite, `make prepare` / `make runtime`, first boot, NRO modules loaded.
- **M4 (2026-10-25):** title and menus with picture and sound, correct text and UI masks.
- **M5 (2026-10-25):** offline matches; multiple controllers, saves, 60 Hz, DLC, manual, text entry.
- **2026-10-26:** every shader translated ahead of play (`make shaders`), shader cache in Application Support, scaled
  texture copies.
- **Next:** faster start (binary archive), then 13.0.5.

## Licensing and provenance

MacNativeGames is MIT. The scaffold is forked from `games/by3` and keeps its third-party notices. OpenSmash-Ultimate and
public decompilation projects are reference material only; do not copy GPL-3.0 code into this tree. See
[existing-ports.md](existing-ports.md). Game data and keys remain the player's responsibility and are never committed.

# Existing SSBU ports and why this tree still exists

Status: survey as of **2026-10-21**. This page records prior art; it is not a code dependency and nothing here is copied
into MacNativeGames.

## OpenSmash-Ultimate (`Denkishi/ssbu-recomp`)

- Repository: <https://github.com/Denkishi/ssbu-recomp>
- Mac build guide: <https://github.com/Denkishi/ssbu-recomp/blob/main/BUILDING_MAC.md>
- Mac launcher: <https://github.com/Denkishi/ssbu-recomp/blob/main/play_mac.sh>
- Older Mac branch: <https://github.com/Denkishi/ssbu-recomp/tree/mac1-port>

OpenSmash-Ultimate is a static recompilation of SSBU 13.0.4/13.0.5: AArch64 game code is lifted to C and compiled for
the host, with its own Horizon runtime. It is not an emulator and contains no game data, assets, keys or firmware. The
one stated exception is a checked-in list of SDK function names.

The repository now has an **Apple Silicon macOS build**, even though its README headline still says “native Windows
x64.” The Mac build uses SDL3 for the window, sound and controllers, and **Vulkan through MoltenVK** for graphics. It is a
native arm64 program, but it is not an NVN-on-Metal renderer.

Mac support landed in commit `124335a9` on 2026-10-20; the F1 settings menu followed in commit `00d826c`. The `mac1-port`
branch also exists, but `main` is newer.

### Documented Mac requirements

- Apple Silicon Mac (M1 or newer); Intel Macs are not supported.
- macOS 14.4 or newer.
- About **60 GB free disk** and **16 GB RAM** recommended.
- The first build lifts and compiles the whole game; the guide says several hours.
- The player supplies an `exefs/` + `romfs/` dump with the update applied. Their `tools/extract/dump_folder.py` can build
  that layout from the player's own NSP/XCI plus update.

Documented start commands:

```sh
git clone https://github.com/Denkishi/ssbu-recomp
cd ssbu-recomp

bash scripts/macos/install_mac.sh --dump <your-dump-folder>
bash play_mac.sh
```

### Status and limits

The Mac guide still calls this the **first test on a real Mac** and says nobody had played the game on a Mac with that
build yet. It also lists:

- missing MoltenVK/Vulkan features can stop the game with an `nvn_vk:` message;
- speed and shader-preparation behavior are not established;
- mods and the function-hook table are off on macOS;
- online play is off;
- recording movies to the album does not work.

A recent Reddit comment reports a successful build and run on an M5 Max, but treat that as one unverified report rather
than a compatibility guarantee.

### License

OpenSmash-Ultimate is **GPL-3.0**. It is reference material only. Do not copy its code, generated tables, shader
translation code or build scripts into this MIT tree. Reimplement ideas independently and keep the licenses separate.

## What this means for `games/ssbu`

- The project is real prior art and confirms that the static-recompilation route can produce a native Apple Silicon
  program for SSBU.
- It does **not** replace this scaffold. OpenSmash renders through Vulkan/MoltenVK; this tree is building an
  NVN-on-Metal host. I found no dedicated NVN-on-Metal SSBU Mac port as of the survey date.
- Its public material is useful for comparison: the 98 `lua2cpp_*` NRO modules, build-ID detection, shader prewarm/cache
  keyed by game version, Mac packaging and input plumbing.
- Its GPL-3.0 license means we can study behavior and measurements, not lift implementation.

## Search results that are not SSBU Mac ports

- Ryujinx/Yuzu shader caches and emulator setups: those run the Switch build through an emulator, not a native port.
- Super Smash Bros. Melee and Nintendo 64 Smash ports: different games and codebases.
- Windows-only SSBU recompilation projects: no Mac build found in this survey.

## Related pages

- [Port plan and status](port-plan.md)
- [NRO pipeline](nro.md)

# Super Smash Bros. Ultimate (native macOS port)

Super Smash Bros. Ultimate 13.0.4 running natively on Apple silicon with the MacNativeGames approach: the game's own ARM64
code runs on a Horizon host layer, and NVN draws through Metal. This is not static recompilation.

**Status (2026-10-25): offline play works.** Boot, loading screen, intro movie, menus, character select and matches render
correctly at 60 Hz with sound. Up to eight controllers each play as their own player, DLC from the player's own dump is
recognised, the in-game manual (Y Help) opens, and names can be typed with a controller. See
[CHANGELOG.md](CHANGELOG.md) for what changed and [docs/port-plan.md](docs/port-plan.md) for what is still open.

It is forked from `games/by3`, which already had the CMIF domains, per-stage NVN binding, indirect draws, `ClearBuffer`,
`TexturePoolRegisterImage`, `QueueWaitSync` and 60 Hz pacing that Smash needs.

**You must own the game and its keys.** No game data, assets, keys, firmware, NRO/NSO images, shaders or saves are in this
repository. The work folder (`SSBU_build/`) and `mods/` are ignored by git.

- Title IDs: base `01006A800016E000`, update `01006A800016E800` (version 13.0.4), add-ons `01006A800016F001`–`F0FF`.
- Scope: offline local play. Online/NPLN, amiibo/NFP and the GameCube adapter are not supported; the Online tile does
  not connect.

## Inputs

- Base NSP `01006A800016E000` and update NSP `01006A800016E800` (13.0.4).
- `prod.keys` from your own console.
- Your firmware's shared fonts (the game and its manual use them).
- Optional: your add-on (DLC) NSPs.

Copy every input to the internal disk before building; external drives are cold storage only (see the workspace
`AGENTS.md`). The keys stay in memory; nothing is sent anywhere.

## Build

From `games/ssbu`, with a Python environment from `requirements.txt` and Xcode's Metal toolchain
(`xcodebuild -downloadComponent MetalToolchain`):

```sh
# Code, data and fonts
python3 scripts/extract_code.py "<update>.nsp" --keys prod.keys --output SSBU_build/extracted/v1304/exefs
python3 scripts/merge_romfs.py "<base>.nsp" "<update>.nsp" --keys prod.keys --output SSBU_build/extracted/v1304/romfs
python3 scripts/extract_shared_fonts.py --keys prod.keys --firmware <unpacked firmware NCAs> \
  --output SSBU_build/extracted/firmware/shared-fonts

# The three ExeFS modules, then the 98 lua2cpp NRO modules (docs/nro.md)
for m in sdk subsdk0 main; do
  DM_RULESET=native DM_PRIVATE_GATES=0 python3 third_party/d2r/patch_nso.py \
    SSBU_build/extracted/v1304/exefs/$m SSBU_build/rewritten/v1304 $m
done
python3 scripts/prepare_modules.py SSBU_build/extracted/v1304/exefs --output SSBU_build/extracted/v1304/elf
make nros                                          # NRO0 + NRR images out of data.arc
python3 scripts/prepare_nros.py                    # rewrite them, write nro_catalog.c

# Hashes of your dump, runtime tables, host, shader tools
python3 scripts/make_expected.py --work SSBU_build --output SSBU_build/expected-v13.0.4.json
make prepare EXPECTED=SSBU_build/expected-v13.0.4.json
make runtime shader-tools

# Optional extras
make dlc DLC=<folder of add-on NSPs> KEYS=prod.keys
make manual BASE="<base>.nsp" UPDATE="<update>.nsp" KEYS=prod.keys

make app GAME="<update>.nsp" KEYS=prod.keys
open "Super Smash Bros. Ultimate.app"
```

The app runs the game from `SSBU_build`; do not move or delete it while the app is installed.

### Shaders

Smash's shaders are translated (Switch GPU code to MSL) the first time the game loads them and kept in
`SSBU_build/build/shader-cache/`. Compile the cache into Metal libraries ahead of time, or the runtime compiles them at
start-up (slow):

```sh
python3 scripts/prepare_shader_libs.py --work SSBU_build
```

Run it again after playing with new fighters or stages: their shaders are translated during that session, and the first
appearance of each one hitches once. The very first start after new libraries also waits while macOS builds its own
shader cache (about a minute); later starts wait a few seconds.

## Start-up

The loading screen shows a progress bar while every pipeline the game has used is built ("Preparing graphics"); the game
starts when that is done, so the intro movie and the menus do not stutter. Shader variants no list names finish in the
background at low priority. The first start of a copy of the game data also verifies all 17.6 GB of it once (about 15 s);
later starts reuse that check.

## Controls

Keyboard (player 1):

| Switch | Mac key | Switch | Mac key |
|---|---|---|---|
| A / B | J / K (Space is also B) | X / Y | I / U |
| L / R | Q / E | ZL / ZR | Option / Shift |
| + / − | Return / Tab or Esc | Stick clicks | Z / C |
| Left stick | W A S D | Right stick | Arrow keys |
| D-pad | T F G H | | |

Shortcut keys: 1 shows or hides the overlays, 2 cycles frame interpolation, 3 cycles the output modes, 4 toggles
ultrawide.

Controllers: every controller macOS sees (Switch Pro, DualSense, Xbox and others) is its own player, in the order they
connect; the first one shares player 1 with the keyboard. Players 1–4 light their controller's player lamps. Rumble goes
to the player the game vibrates. `SSBU_MERGE_PADS=1` makes every controller drive player 1 instead.

Text entry (names): a bar with an on-screen keyboard opens over the game. Type on the Mac keyboard, click the keys, or use
any controller: D-pad / stick move, A types, B deletes, Y adds a space, L capitals, R symbols, + done, − cancel.

Y Help opens the game's own manual pages over the game; B or Escape goes back and closes it.

## Switches

| Variable | Effect |
|---|---|
| `SSBU_DLC=0` | Report no add-ons. |
| `SSBU_MERGE_PADS=1` | All controllers drive player 1. |
| `SSBU_WARM_BEFORE_START=0` | Start the game after the title shaders only (the old, stuttery order). |
| `SSBU_SHADER_PREFETCH=0` | Do not translate shaders when the game loads them. |
| `TOTK_RUMBLE=0` / `TOTK_GYRO=0` | No rumble / no motion sensor. |
| `TOTK_MOVIE_PACE=1` | Host-side movie pacing (TotK's; Smash times its movies itself). |
| `TOTK_UBO_SNAPSHOT=1` | Copy uniforms at submit (TotK's behaviour; magnifies Smash's 2D screens). |
| `TOTK_INPUT_LOG=1` | Log each controller id and state the game reads. |

## Mods

`mods/13.0.4/<name>/exefs/*.pchtxt` and `mods/<name>/romfs/` are supported by the inherited tooling, but no SSBU patch set
ships here. The by3 resolution/LOD offsets do not apply to SSBU; add SSBU sites and a build-ID check first.

## Licensing

MacNativeGames is MIT. The by3 fork keeps its third-party notices (`third_party/d2r/LICENSE`, `third_party/d2r_gfx/LICENSE`,
`third_party/licenses/`). The NRO loader and its rewrite pipeline are adapted from the MIT
`NicholasDominici/super-smash-bros-ultimate-ios` project. OpenSmash-Ultimate and public decompilation projects are reference
material only; do not copy GPL-3.0 code into this tree ([docs/existing-ports.md](docs/existing-ports.md)).

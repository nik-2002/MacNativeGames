# Super Smash Bros. Ultimate port: work log

## 2026-10-26 — crashes, saves, Help pages, controllers

### Crashes

- **Menu clips:** a looping clip (Help > Techniques, menu previews) overflowed the decoder's input queues when it
  rewound, and the queued times overwrote the frame pointers: a crash some minutes into the menus. The queues are bounded,
  a rewind keeps the buffers the game holds and the decoder's pictures, and the clip's first key frame is decoded again
  when a loop resumes at its second frame. Loops went from hundreds of VP9 errors each to none.
- **Kazuya:** macOS can map a fighter's script module between the low space and the alias space, a range memory queries
  answered as host-owned. The game's unwinder then found no code there, and an exception thrown through Kazuya's scripts
  ended the game. Loaded modules are asked first.
- **Graphics:** an NVN function the port lacks (83 of 523: debug, GL interop, transform feedback, tessellation, getters)
  is logged once and returns 0 instead of ending the game (`DM_NVN_STRICT=1`: stop). Integer clears (`ClearColori`,
  `ClearColorui`, `ClearTexturei`) are implemented.
- **Shaders:** a shader that fails to translate, a translator that exits, or a translation Metal cannot compile skips the
  draws that need it instead of ending the game; a new translator starts for the next shader. A dead translator's pipe no
  longer raises SIGPIPE (which ended the game without a log).

### Saves

- **Journal:** writes that are not committed no longer survive the game ending, as on the console. Before the first change
  after a commit the committed save is cloned beside it (an APFS clone, no space until files change); Commit drops the
  clone. A start that finds one restores the committed save and keeps the unfinished one once as `<save>.interrupted`.
  `probe-save` covers it (23 checks).

### Help pages

- How to Play, Mode Guide and Move List open (the NX browser's Gamepad API, first-paint event, font event and focus are
  stood in for); D-pad navigation moves to the item in line; no focus ring; the Switch font is the page default and
  button glyphs render. Y Help fades to black at once and its web process is started ahead.

### Portable app

- The app can live on a USB drive: the game data is inside it and found from the app's own place, while saves, the shader
  cache and logs stay in Application Support on the Mac. The data check's record names the volume by its UUID instead of
  the device number macOS hands out at each mount, and off APFS/HFS (exFAT) it leaves out the made-up inode and ctime, so
  a moved or replugged copy does not hash 17.6 GB again. Moving the app within the Mac: checked, reused in 1.7 s.

### Controllers

- Controllers keep playing while another app is in front (`SSBU_BACKGROUND_PADS=0`: frontmost only), are read on their
  own queue, keep their player on reconnect, use a round dead zone, and simple pads (a single Joy-Con) work.

## 2026-10-26 — shaders ahead of play, cache out of the app, scaled copies

- **Every shader before play:** `make shaders`. `scripts/extract_shaders.py` reads all 34,054 shaders from `data.arc`:
  - the `.nushdb` model shaders, where each control section is followed by its code;
  - the `.eff` effect shaders, inside NintendoWare BNSH containers, paired through their 24-byte
    {control, code, sizes} records.

  The pack holds exactly the bytes the game hands over: 13,734 of the 14,139 shaders a session had used are in it with
  the same keys, and the rest are built into `main`. The runtime's `shader-sweep` mode translates the pack (20,320 new,
  69 s) and `prepare_shader_libs.py` compiles it (13,266 libraries). A fighter or stage met for the first time no longer
  hitches 1.5–3 s.
- **Shader cache moved:** the cache and libraries live in Application Support (`SSBU_CACHE_ROOT`), not inside the app
  bundle, where play wrote into the signed app. The first start clones the old cache there; the app and work-folder
  runs share it.
- **Scaled texture copies:** copies that change size, mirror or format run as a render pass. Smash halves its depth-stencil
  buffer for its half-resolution effects; that copy was skipped. `probe-gpu-scaled-copy` checks every pixel of depth,
  depth-stencil, nearest, linear and mirrored copies.
- **Scissor warning:** the second scissor set at start (Labo VR stereo halves) is unused, since no shader selects a
  viewport index; its log line no longer reads as an error.

## 2026-10-25 — first boot to offline play

### Boot

- The scaffold boots 13.0.4 to the menus and into matches. `nn::ro` loads the 98 `lua2cpp_*` NRO modules from rewritten
  images listed in a generated catalog (`scripts/prepare_nros.py`, `runtime/nro_loader.c`; see `docs/nro.md`).

### Rendering

- Matches render. Smash binds two texture pools and two sampler pools with overlapping ids. Each pool now gets its own
  id range; before, stages and fighters drew with the dummy texture (a black or white match).
- No crash when the game frees a texture pool on stage unload.
- Window images start cleared, so the first frame is no longer magenta.
- The versus screen and match intro are no longer magnified about 2x. Uniforms are read live instead of copied at submit
  (that copy was a TotK fix; `TOTK_UBO_SNAPSHOT=1` brings it back).
- Menu text lays out with the game's own glyphs. The glyph-lookup patch returns NULL to the 13 callers that check for
  it, so missing glyphs get registered; only the 4 callers that don't check get the dummy glyph.
- The NVN alpha test is emulated for every draw, with the game's reference value (`SetAlphaRef`). UI masks no longer
  spill past their shapes.
- A cube texture viewed as one slice is a 2D view. Metal used to abort on it after 25 minutes on the menus.

### Shaders and start-up

- **Shader prefetch:** each shader is translated when the game loads it (`nvnProgramSetShaders`) on four background
  workers, each with its own translator process.
- **Translator hang:** the translator is spawned with an empty signal mask. It had inherited a blocked `SIGCHLD` and
  hung, which stopped all drawing.
- **Precompiled libraries:** `scripts/prepare_shader_libs.py` compiles the translation cache into Metal libraries, which
  the runtime loads instead of compiling.
- **Stalls:** a match on a stage new to the cache went from 9.5 s of shader stalls to 0.66 s.
- **Loading screen:** it shows a progress bar until every recorded pipeline is built, and the game starts after that.
  Before, the screen went black at the first frame and the warm-up ran on 6 threads behind the intro.
- **Background top-up:** variants no list names finish afterwards on 2 threads at utility priority.
- **Movie pacing:** host pacing is off for Smash, which times its movies itself. Paced frames were handed over only when
  the game presented, but its main thread waits for the first movie frame before presenting. The intro started about
  8 s late behind a black screen, and the stall is the likely cause of a rare boot crash in `movie::Buffer::Base`.
- **Data verification:** the record is kept per copy of the data. The app's copy and a work-folder copy shared one
  record, so each start of the other copy re-hashed 17.6 GB (14 s before the first frame).

### Input

- **One player per controller:** every controller is its own Npad id and player (up to 8), with player lamps; the
  keyboard shares player 1 with the first controller.
- **Rumble** goes to the player the game vibrates. Before, the last controller connected got every player's rumble.
- **Motion** comes from player 1's controller.
- **Player-light patterns** follow the Switch (P2 = two lamps, and so on).
- **On-screen keyboard:** the text-entry bar has one that any controller drives. A 9-key symbols row crashed the game
  on R; it's fixed.

### Content

- **DLC:** `make dlc` verifies the player's add-on NSPs and writes a manifest; `nn::aoc` reports those add-ons. Smash's
  add-ons hold only a dummy file, because the content is already in `data.arc`. Checked with 99 add-ons: Piranha Plant,
  the Challenger Packs, stages and music unlock.
- **Y Help:** opens the game's offline manual over the game in a WebKit view, with an `nx` stand-in for the web applet,
  the Switch's own fonts, and a fade-in fitted to 16:9.
- **`make manual`** merges the base manual with the update's BKTR patch (`merge_romfs.py --content html-document`) and
  decodes the shared fonts for it.

### Status

Offline play works: menus, single matches with CPUs and local players, DLC fighters, sound, saves.

### Open

- The first appearance of a new fighter or stage still hitches once while its shaders translate.
- The shader cache lives inside the app bundle.
- The ZR side-menu highlight and the player-lamp icon with two controllers are unverified.
- See `docs/port-plan.md`.

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

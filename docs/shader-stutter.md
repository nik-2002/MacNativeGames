# Shader stutter: what it is, what it costs, and what removes it

This page is the record of one investigation into the hitch a player sees when the
game meets a shader it has not prepared. It holds the measurements, the changes,
and what is still open. The rules of this repository apply to it: no game content,
measurements before claims, and a change that is not verified stays off.

## The symptom

A frame that takes 200 ms to 2.4 s while the camera is under the player's control.
The game does not crash and does not lose the picture; it stops.

## What the long-frame log says

The runtime logs every long frame with what it spent the time on
(`[长帧] 帧 … 整帧 … ms，提交+出图 … ms，GPU … ms；新建管线 N 条 + 着色器库 M 个共 X ms`).
One Breath of the Wild session on an M1 MacBook Air (8 GB), 121,000 frames:

| | |
|---|---|
| long frames logged | 7,347 |
| of those, frames that built a pipeline or a shader library | **259** |
| time spent in that work | **49.1 s** |
| worst frame | 2,394 ms, of which 2,130 ms was 2,130 shader libraries |
| frames over 100 ms | 156 |
| frames over 1 s | 17 |

The same session's own count of where the shader libraries came from:

```
[dm] [nvn-mtl] 着色器库：预编译加载 0 个，现编 11601 个
```

Zero libraries loaded precompiled, 11,601 compiled while the game was running.

## Why a shader is compiled at all

The game's graphics code is Maxwell machine code, which no Apple GPU runs. It is
translated to Metal Shading Language, and the Metal compiler turns that into code
the GPU runs. On the Switch both steps happened on Nintendo's own machine before
the game was pressed onto a card, so the player never sees them.

Three things decide whether a player sees them here:

1. **Is the shader already translated?** The build prepares the shaders it finds in
   the game files (`prepare_shader_seed.py`) and the shared shader list
   (`assets/shader_list.tsv`) names the bind states players met. A shader that is
   in neither is translated while the game runs: the translation is the first half
   of the hitch.
2. **Is the translated shader already compiled?** With Xcode's Metal toolchain
   installed, the build compiles every prepared shader into a library
   (`build_app.py step_shader_libs`) and the game loads it. Without the toolchain
   the game compiles it on first use, and that is the second half of the hitch.
3. **How long does the pipeline take?** A fraction of a millisecond
   (3,424 pipelines in 0.7 s), so it is not the problem.

## The three fixes

### 1. The build ships the compiled libraries (the whole hitch)

`build_app.py` says so when the toolchain is missing:

```
3/4 shaders: no Metal toolchain (xcodebuild -downloadComponent MetalToolchain), so the startup shaders go
into Metal's cache for the app's location at the end of the build instead; moving the app makes them cold again
```

That line appears in the build log of an app that then spends 49 s compiling shaders
while the player plays. `xcodebuild -downloadComponent MetalToolchain` (839 MB) is
the whole fix; the build then writes `build/shader-libs/<SHA-256 of the MSL>.metallib`
into the app, and the game loads those instead of compiling.

`prepare_botw_shader_libs.py` (in the developer's own folder, not in this
repository) does the same for an app that is already installed, so the fix does not
need the game files again.

### 2. The seed prepares every shader, not only the startup ones

`prepare_shader_seed.py` translated the default bind state of the *startup*
shaders only (the ones the title screen and the menus need): 9,953 of the 19,727
shaders the game files hold. The other 9,774 were translated while playing, the
first time the player met them.

The default bind state is the one most shaders are drawn with. Of the bind states
players recorded for Breath of the Wild, 83.4% are the default one, so preparing
every shader for it removes the translation from most first meetings.

Measured on the 1.6.0 game data:

| | before | after |
|---|---:|---:|
| shaders discovered in the game files | 19,727 | 19,690 |
| prepared for the default bind state | 9,953 | 19,690 |
| prepared variants in the seed | 11,148 | 21,389 |
| of those from the shared list | 1,718 | 11,659 |
| failures | 44 | 44 |
| time to prepare | 40 s | 127 s |
| files in the seed | 33,160 | 60,350 |

(The 37 shaders less are the ones in the game module that a patch to the module
changed; the measurement ran against an already patched module, a build from the
original files finds them all.)

A prepared shader that is not a startup one used to get no row in the warm list: the
runtime builds that pipeline when the draw needs it, which costs a fraction of a
millisecond, while the library itself comes from the app. That was not enough: the
warm-up did not load the library, and the driver compiles the AIR of a library it has
never seen (about 0.1 s) the first time the game draws with it. The first visit to a
region logged 1,362 ms with 9 shader libraries.

Every prepared variant is warmed now (commit `3db0685`):

| | before | after |
|---|---:|---:|
| warm rows | 11,659 | 20,351 |
| warm-up time | 9.2 s | 13.7 s |
| render pipelines the warm-up builds | 8,543 | 11,045 |

The first frame still waits only for the title list (20 ms).

### 3. The shared shader list carries what players met

The list held 1,718 variants for 1,713 shaders. A played session recorded 11,699
variants over 11,109 shaders; the 9,981 rows the list did not have were added
(commit `c066e74`). Every added row is a variant the build can now prepare ahead
of play.

The list is the channel that works without anyone writing code: play, and send
the file the game writes (see [the shared shader list](shader-list.md)).

## What upstream does about the same hitch (2026-10-22)

Upstream worked on this area in parallel and much of it is now in this branch
(`bc461fc` and the commits before it):

| Upstream | What it does | How it meets this page |
|---|---|---|
| `27baca0`, `ea6c5a7`, `6446e09` | A pipeline archive: the compiled GPU code of a pipeline is kept on disk, one file per pipeline, and the game takes it from there | The pipeline was never the problem (a fraction of a millisecond); the archive saves the *library* compiles on later runs. |
| `bfdd085`, `bc461fc` | New shaders are translated on background threads, and the shaders that cannot wait are prepared at once, in parallel | Removes the translation from the submit thread, which is where this page's hitch happens. |
| `852f862` | The patched variants (sampler border colours, missing varyings) are compiled into the app with the startup shaders | The same fix as fix 1, for the variants the runtime rewrites. |
| `b06c88d` | The border-colour pipelines are warmed from the recipes the game recorded | The warm list learns to carry them. |
| `prepare_shader_seed.py` | The preparation keeps an inventory of the RomFS's shaders and a cache of the translations beside the seed folder | A preparation that runs again after the list grew translates only the new bind states. It is kept as it is here. |

Two of the upstream changes are worth naming, because they are the trade this
repository's rules do not allow silently:

- `311f7ec` skips a draw inside an occlusion count while its shader is prepared
  (the count it leaves at 0 is reported as 1).
- `b06c88d` draws a border-colour pipeline with the plain pipeline (whose samplers
  clamp to the edge) until the real one is ready.

Both put a frame on screen before every draw of it is right, which the rule in
`CONTRIBUTING.md` ("the picture must be correct before it is fast") does not allow
on the Mac. Upstream keeps them behind `TOTK_OCCL_SKIP=0`, `TOTK_BORDER_PLAIN=0`
and `TOTK_ASYNC_SHADERS=0`, so they can be off.

## What is left

- A shader whose bind state is neither the default one nor one the list names is
  still translated and compiled at first use. 16.6% of the recorded bind states are
  not the default one. Upstream's background translation moves that work off the
  submit thread, but the draw is then drawn without it (or later), which is the
  trade named above.
- The Metal libraries are built for the GPU family of the machine that built them.
  A different Mac compiles its own.
- macOS's own cache of compiled libraries is keyed in part by the length of the
  program's path, is a fixed size, and is emptied when the disk fills. The app's
  own `shader-libs` folder does not have those problems.
- The numbers above were measured before upstream's parallel work was merged here.
  They are the reference for the shader side of the stutter, not for the pipeline
  side: the pipeline archive, the background translation and the prebuilt variants
  change what a session costs, and they need their own measurement on the same
  route.

## How to measure

`docs/performance-followups.md` has the protocol: the same route, the same save,
the same camera, cold and warm caches apart, at least 8 × 30 s windows in
A/B/B/A/B/A/A/B order, every slow frame kept, and the picture checked as well.
The numbers above come from the long-frame log of one session, which is a count of
the work done, not a frame-rate measurement.

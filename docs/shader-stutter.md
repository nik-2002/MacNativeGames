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

A prepared shader that is not a startup one is not warmed (no row in the warm
list): the runtime builds that pipeline when the draw needs it, which costs a
fraction of a millisecond, while the library itself comes from the app. The warm
list grows from 11,148 to 11,659 rows, not to 21,389.

### 3. The shared shader list carries what players met

The list held 1,718 variants for 1,713 shaders. A played session recorded 11,699
variants over 11,109 shaders; the 9,981 rows the list did not have were added
(commit `c066e74`). Every added row is a variant the build can now prepare ahead
of play.

The list is the channel that works without anyone writing code: play, and send
the file the game writes (see [the shared shader list](shader-list.md)).

## What is left

- A shader whose bind state is neither the default one nor one the list names is
  still translated and compiled at first use. 16.6% of the recorded bind states are
  not the default one.
- The Metal libraries are built for the GPU family of the machine that built them.
  A different Mac compiles its own.
- macOS's own cache of compiled libraries is keyed in part by the length of the
  program's path, is a fixed size, and is emptied when the disk fills. The app's
  own `shader-libs` folder does not have those problems.

## How to measure

`docs/performance-followups.md` has the protocol: the same route, the same save,
the same camera, cold and warm caches apart, at least 8 × 30 s windows in
A/B/B/A/B/A/A/B order, every slow frame kept, and the picture checked as well.
The numbers above come from the long-frame log of one session, which is a count of
the work done, not a frame-rate measurement.

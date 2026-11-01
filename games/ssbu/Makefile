# Super Smash Bros. Ultimate native runtime scaffold. Self-contained: the Horizon host (runtime/), the rewriter
# (third_party/d2r), the NVN-on-Metal layer (third_party/d2r_gfx), the shader translator (prebuilt/) and the scripts are
# this folder's own copies, forked from games/by3 (which was forked from games/totk); nothing here reads games/totk or
# games/by3. Everything generated goes to the work folder. This tree is a scaffold: the NRO pipeline and SSBU service
# work are not implemented yet (see README.md and docs/nro.md).
# Inputs come from scripts/extract_code.py, scripts/merge_romfs.py and the rewrite (see README.md), then:
#   make prepare   # scripts/prepare_runtime.py: tables, RomFS index, fonts config
#   make runtime   # SSBU_build/build/ssbu-native
#   make boot      # run it from the work folder (cwd: extracted/ and rewritten/ are read relative to it)

WORK ?= SSBU_build
OUT := $(WORK)/build
PY ?= python3
NATIVE_OPT ?= -O2
# The template in assets/ has no hashes. After make_expected.py, pass the generated manifest:
#   make prepare EXPECTED=SSBU_build/expected-v13.0.4.json
EXPECTED ?= assets/expected-v13.0.4.json

GFX_SRC := $(wildcard third_party/d2r_gfx/gfx/nvn/*.c third_party/d2r_gfx/gfx/nvn/*.m third_party/d2r_gfx/gfx/nvn/*.S third_party/d2r_gfx/gfx/tex/*.c third_party/d2r_gfx/gfx/tex/*.m)
GFX_OBJECTS := $(patsubst %,$(OUT)/obj/%.o,$(GFX_SRC))
GFX_HEADERS := $(wildcard third_party/d2r_gfx/gfx/nvn/*.h third_party/d2r_gfx/gfx/nvn/include/*.h third_party/d2r_gfx/host/*.h)
GFX_FLAGS := -std=gnu11 -Wno-error -Wno-unused-function -Wno-unused-parameter -fobjc-arc -Ithird_party/d2r_gfx/gfx/nvn/include

RUNTIME_SRC := $(filter-out runtime/frontend_ios.m,$(wildcard runtime/*.c runtime/*.m runtime/*.S))
RUNTIME_HEADERS := $(wildcard runtime/*.h)
GENERATED := $(OUT)/runtime_tables.h $(OUT)/romfs_config.h $(OUT)/shared_fonts_config.h

.PHONY: prepare runtime boot clean
prepare:
	"$(PY)" scripts/prepare_runtime.py --work "$(WORK)" --expected "$(EXPECTED)"

$(GENERATED):
	@echo "missing $@: run make prepare" && false

$(OUT)/obj/%.o: % $(GFX_HEADERS) Makefile
	@mkdir -p "$(dir $@)"
	xcrun clang $(NATIVE_OPT) -g -Wall -Wextra $(GFX_FLAGS) -c "$<" -o "$@"

$(OUT)/ssbu-native: $(RUNTIME_SRC) $(RUNTIME_HEADERS) $(GENERATED) $(GFX_OBJECTS) Makefile
	xcrun clang -std=c11 $(NATIVE_OPT) -g -Wall -Wextra -Werror -Wno-deprecated-declarations \
	  -Ithird_party/d2r_gfx/gfx/nvn/include -I$(OUT) -I/opt/homebrew/opt/opus/include/opus -I/opt/homebrew/opt/libvpx/include \
	  $(RUNTIME_SRC) $(GFX_OBJECTS) /opt/homebrew/opt/opus/lib/libopus.a /opt/homebrew/opt/libvpx/lib/libvpx.a \
	  -framework Metal -framework MetalFX -framework Foundation -framework QuartzCore -framework ImageIO -framework CoreGraphics \
	  -framework CoreText -framework UniformTypeIdentifiers -fobjc-arc -framework Cocoa -framework CoreVideo -framework CoreFoundation -framework VideoToolbox -framework CoreMedia \
	  -framework AudioToolbox -framework GameController -framework CoreHaptics -framework IOKit -framework WebKit -framework IOBluetooth -framework CoreBluetooth -o "$@"

runtime: $(OUT)/ssbu-native

# The runtime shader translation the graphics layer starts on first use: <work>/build/shader-service/totk_xlate (the
# repository's prebuilt NativeAOT translator, checked against its SHA-256) and <work>/build/spirv-cross/spirv-cross,
# built like build_app.py does (same pinned commit, sources and flags as SPIRV-Cross's CMake Release build).
SPIRV_CROSS_COMMIT := aa217aeb6c9f0ace7a0ab233b28807edf45eb165
SPIRV_CROSS_SOURCES := main.cpp spirv_cfg.cpp spirv_cpp.cpp spirv_cross.cpp spirv_cross_parsed_ir.cpp spirv_cross_util.cpp \
  spirv_glsl.cpp spirv_hlsl.cpp spirv_msl.cpp spirv_parser.cpp spirv_reflect.cpp
.PHONY: shader-tools
shader-tools: $(OUT)/shader-service/totk_xlate $(OUT)/spirv-cross/spirv-cross
$(OUT)/shader-service/totk_xlate: prebuilt/macos-arm64/totk_xlate prebuilt/macos-arm64/totk_xlate.sha256
	@mkdir -p "$(dir $@)"
	test "$$(shasum -a 256 "$<" | cut -d' ' -f1)" = "$$(cut -d' ' -f1 "prebuilt/macos-arm64/totk_xlate.sha256")"
	cp "$<" "$@" && chmod +x "$@"
$(OUT)/spirv-cross/spirv-cross:
	@mkdir -p "$(WORK)/src" "$(dir $@)obj"
	test -d "$(WORK)/src/SPIRV-Cross" || git clone -q https://github.com/KhronosGroup/SPIRV-Cross.git "$(WORK)/src/SPIRV-Cross"
	git -C "$(WORK)/src/SPIRV-Cross" checkout -q $(SPIRV_CROSS_COMMIT)
	for f in $(SPIRV_CROSS_SOURCES); do xcrun clang++ -O3 -DNDEBUG -std=c++11 -arch arm64 -Wno-deprecated-declarations \
	  -c "$(WORK)/src/SPIRV-Cross/$$f" -o "$(dir $@)obj/$$f.o" & done; wait
	xcrun clang++ -arch arm64 $(addprefix $(dir $@)obj/,$(addsuffix .o,$(SPIRV_CROSS_SOURCES))) -o "$@"

# SSBU_LOG: where the boot's stderr goes (the host is loud on purpose; every abort names what is missing).
SSBU_LOG ?= $(WORK)/logs/boot.log
boot: runtime
	@mkdir -p "$(dir $(SSBU_LOG))"
	cd "$(WORK)" && TOTK_HEADLESS=$${TOTK_HEADLESS-} ./build/ssbu-native rewritten/v1304 boot 2> "$(abspath $(SSBU_LOG))"; echo "exit $$?; log: $(SSBU_LOG)"

# The host H.264 movie decoder (runtime/movie_host.c, decoder type 1) against ffmpeg's decode of a libx264 clip with
# B-frames: length-prefixed samples with an avcC record, and Annex B samples in a format without a size; and the VP9
# decoder against ffmpeg's native decode of a libvpx clip.
.PHONY: probe-movie-avc
$(OUT)/movie-probe-avc: scripts/movie_probe_avc.c runtime/movie_host.c runtime/movie_host.h runtime/runtime.h
	@mkdir -p "$(dir $@)"
	xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -I/opt/homebrew/opt/libvpx/include scripts/movie_probe_avc.c runtime/movie_host.c \
	  /opt/homebrew/opt/libvpx/lib/libvpx.a -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework CoreFoundation -o "$@"
probe-movie-avc: $(OUT)/movie-probe-avc
	python3 scripts/movie_probe_avc_inputs.py "$(WORK)/analysis/movie-probe-avc"
	"$(OUT)/movie-probe-avc" "$(WORK)/analysis/movie-probe-avc/lp.bin" "$(WORK)/analysis/movie-probe-avc/ref.nv12" lp
	"$(OUT)/movie-probe-avc" "$(WORK)/analysis/movie-probe-avc/annexb.bin" "$(WORK)/analysis/movie-probe-avc/ref.nv12" annexb
	PROBE_KEEP=4 "$(OUT)/movie-probe-avc" "$(WORK)/analysis/movie-probe-avc/lp.bin" "$(WORK)/analysis/movie-probe-avc/ref.nv12" lp
	"$(OUT)/movie-probe-avc" "$(WORK)/analysis/movie-probe-avc/vp9.bin" "$(WORK)/analysis/movie-probe-avc/ref_vp9.nv12" vp9

# The pipeline archive (third_party/d2r_gfx/gfx/nvn/totk_pipeline_archive.h) on this Mac's GPU: a first process writes a
# render and a compute pipeline to their files, a second takes both from them with MTLPipelineOptionFailOnBinaryArchiveMiss.
.PHONY: probe-pipeline-archive
$(OUT)/pipeline-archive-probe: scripts/pipeline_archive_probe.m third_party/d2r_gfx/gfx/nvn/totk_pipeline_archive.h
	@mkdir -p "$(dir $@)"
	xcrun clang -fobjc-arc -O1 -Wall -Wno-unused-function -Wno-unused-variable scripts/pipeline_archive_probe.m -framework Metal -framework Foundation -o "$@"
probe-pipeline-archive: $(OUT)/pipeline-archive-probe
	rm -rf "$(WORK)/analysis/pipeline-archive-probe" && mkdir -p "$(WORK)/analysis/pipeline-archive-probe"
	"$(OUT)/pipeline-archive-probe" "$(WORK)/analysis/pipeline-archive-probe" write
	"$(OUT)/pipeline-archive-probe" "$(WORK)/analysis/pipeline-archive-probe" read

# The player's mods, made into checked tables: exefs patches (mods/13.0.4/<name>/exefs/*.pchtxt) -> <work>/patches,
# RomFS mods (mods/<name>/romfs/...) -> their manifest.tsv (sizes and SHA-256 of the replacements and the originals).
.PHONY: patches mods nros dlc manual app
patches:
	"$(PY)" scripts/prepare_patches.py --work "$(WORK)" --expected "$(EXPECTED)"
mods:
	for d in mods/*/romfs; do [ -d "$$d" ] && "$(PY)" scripts/make_mod_manifest.py "$$d" --romfs "$(WORK)/extracted/v1304/romfs"; done; true

# Experimental NRO scan: SSBU keeps its 98 lua2cpp_* NRO modules inside data.arc. The scanner writes candidates and a
# manifest to <work>/extracted/v1304/nros; rewriting/loading them is the next milestone (docs/nro.md).
NROS ?= $(WORK)/extracted/v1304/nros
nros:
	"$(PY)" scripts/extract_nros.py "$(WORK)/extracted/v1304/romfs/data.arc" --output "$(NROS)"

# Add-on content (DLC) from the player's own NSPs: DLC=<folder of add-on NSPs, copied to the internal disk> KEYS=<prod.keys>.
# Writes <work>/dlc/<title id>/ and <work>/dlc/manifest.json, which the runtime reads (nn::aoc, runtime/services.c).
DLC ?=
dlc:
	@[ -n "$(DLC)" ] && [ -n "$(KEYS)" ] || { echo "make dlc DLC=<folder of add-on NSPs> KEYS=<prod.keys>"; exit 1; }
	"$(PY)" scripts/extract_dlc.py --keys "$(KEYS)" --input "$(DLC)" --output "$(WORK)/dlc"

# The offline manual (Y Help in the menus): the HtmlDocument NCA of the base game merged with the update's patch,
# verified, unpacked to <work>/manual; the runtime shows its pages over the game (runtime/frontend.m).
#   make manual BASE=<base game NSP> UPDATE=<update NSP> KEYS=<prod.keys>
BASE ?=
UPDATE ?=
manual:
	@[ -n "$(BASE)" ] && [ -n "$(UPDATE)" ] && [ -n "$(KEYS)" ] || { echo "make manual BASE=<base NSP> UPDATE=<update NSP> KEYS=<prod.keys>"; exit 1; }
	rm -rf "$(WORK)/manual-image" "$(WORK)/manual"
	"$(PY)" scripts/merge_romfs.py "$(BASE)" "$(UPDATE)" --keys "$(KEYS)" --content html-document --output "$(WORK)/manual-image"
	"$(PY)" scripts/unpack_romfs.py "$(WORK)/manual-image" --output "$(WORK)/manual"
	"$(PY)" scripts/decode_shared_fonts.py "$(WORK)/extracted/firmware/shared-fonts" --output "$(WORK)/manual/html-document/system-fonts"
	rm -rf "$(WORK)/manual-image"

# Every shader in data.arc (the .nushdb model shaders and each fighter's / stage's .eff effect shaders), translated and
# compiled before play, so a fighter or stage met for the first time does not hitch: extract_shaders.py writes the pack,
# the runtime's shader-sweep translates it into the shader cache, prepare_shader_libs.py compiles it. CACHE_ROOT is
# where the app keeps its shaders (the launcher's SSBU_CACHE_ROOT). About half an hour the first time; reruns skip what
# is cached.
CACHE_ROOT ?= $(HOME)/Library/Application Support/MacNativeGames/SSBU
.PHONY: shaders
shaders: runtime shader-tools
	"$(PY)" scripts/extract_shaders.py "$(WORK)/extracted/v1304/romfs/romfs.bin" --output "$(WORK)/shader-pack.bin"
	cd "$(WORK)" && SSBU_CACHE_ROOT="$(CACHE_ROOT)" SSBU_SHADER_PACK="$(abspath $(WORK))/shader-pack.bin" ./build/ssbu-native rewritten/v1304 shader-sweep
	"$(PY)" scripts/prepare_shader_libs.py --cache-root "$(CACHE_ROOT)"

# The app: a small launcher bundle (settings window with presets, then the game) that runs the game from the work
# folder, which it names in Info.plist (SSBUWorkFolder): nothing large is copied. Its icon comes from the game's own
# control data (GAME=<base or update NSP> KEYS=<prod.keys>), or the app goes without one.
APP ?= Super Smash Bros. Ultimate.app
GAME ?=
KEYS ?=
$(OUT)/launcher: app/launcher.m Makefile
	@mkdir -p "$(dir $@)"
	xcrun clang -std=gnu11 -O2 -Wall -Wextra -Werror -fobjc-arc app/launcher.m -framework Cocoa -o "$@"
$(OUT)/AppIcon.icns:
	@mkdir -p "$(dir $@)"
	@if [ -n "$(GAME)" ] && [ -n "$(KEYS)" ]; then cd scripts && "$(PY)" extract_app_icon.py "$(GAME)" --keys "$(KEYS)" --title 01006a800016e000 --output "$(abspath $@)"; \
	 else echo "no GAME= / KEYS=: the app gets no icon"; fi
app: runtime shader-tools $(OUT)/launcher $(OUT)/AppIcon.icns
	rm -rf "$(APP)" && mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp "$(OUT)/launcher" "$(APP)/Contents/MacOS/Super Smash Bros. Ultimate"
	[ -f "$(OUT)/AppIcon.icns" ] && cp "$(OUT)/AppIcon.icns" "$(APP)/Contents/Resources/" || true
	printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
	  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	  '<plist version="1.0"><dict>' \
	  '<key>CFBundleExecutable</key><string>Super Smash Bros. Ultimate</string>' \
	  '<key>CFBundleIdentifier</key><string>org.macnativegames.ssbu</string>' \
	  '<key>CFBundleName</key><string>Super Smash Bros. Ultimate</string>' \
	  '<key>CFBundlePackageType</key><string>APPL</string>' \
	  '<key>CFBundleShortVersionString</key><string>13.0.4</string>' \
	  '<key>CFBundleVersion</key><string>1</string>' \
	  '<key>CFBundleIconFile</key><string>AppIcon</string>' \
	  '<key>LSMinimumSystemVersion</key><string>26.0</string>' \
	  '<key>LSApplicationCategoryType</key><string>public.app-category.action-games</string>' \
	  '<key>NSHighResolutionCapable</key><true/>' \
	  '<key>NSBluetoothAlwaysUsageDescription</key><string>Pairs new controllers from the game'"'"'s controller screen.</string>' \
	  '<key>SSBUWorkFolder</key><string>$(abspath $(WORK))</string>' \
	  '</dict></plist>' > "$(APP)/Contents/Info.plist"
	codesign --force --sign - "$(APP)"
	@echo "built $(APP) (game data stay in $(abspath $(WORK)))"

# Install the (small) app where Launchpad and Spotlight look: /Applications, or ~/Applications when that is not writable.
INSTALL_DIR ?= $(shell [ -w /Applications ] && echo /Applications || echo $(HOME)/Applications)
.PHONY: install
install: app
	mkdir -p "$(INSTALL_DIR)" && rm -rf "$(INSTALL_DIR)/$(APP)" && cp -R "$(APP)" "$(INSTALL_DIR)/"
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$(INSTALL_DIR)/$(APP)"
	@echo "installed $(INSTALL_DIR)/$(APP)"

clean:
	rm -rf "$(OUT)/obj" "$(OUT)/ssbu-native" "$(OUT)/launcher" "$(OUT)/AppIcon.icns"

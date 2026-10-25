# NRO modules in Super Smash Bros. Ultimate

Status (2026-10-25): **working.** The game loads all of its `lua2cpp_*` modules through `nn::ro` and plays.

## How it works now

1. `make nros` (`scripts/extract_nros.py`) scans `data.arc` for `NRO0` images and the game's `.nrr` registration files and
   writes them to `SSBU_build/extracted/v1304/nros/` and `nrrs/` (100 images on 13.0.4).
2. `scripts/prepare_nros.py` admits only images whose SHA-256 appears in an NRR registration, wraps each one in an
   uncompressed `NSO0` carrier, rewrites it with `third_party/d2r/patch_nso.py` (the same native rewrite as the ExeFS
   modules), and writes `rewritten/v1304/<module>.patched.bin` plus the C catalog `nro_catalog.c` / `nro_catalog.json`.
3. `make prepare` compiles the catalog into the runtime.
4. At run time `runtime/nro_loader.c` answers `nn::ro`: `RegisterModuleInfo` checks the NRR, and `LoadModule` hashes the
   guest's NRO buffer, looks it up in the catalog, and maps the verified rewritten image. Code never executes from the
   guest's buffer. It relocates the module, resolves its imports, registers its unwind tables and runs its initializers.

The loader and pipeline are adapted from the MIT `NicholasDominici/super-smash-bros-ultimate-ios` project.

The sections below are the original design notes (2026-10-21), kept for background.

## Why this exists

SSBU's executable code is split between the ExeFS modules loaded by the native loader (`main`, `sdk`, `subsdk0`) and
roughly 98 `lua2cpp_*` NRO modules stored inside `data.arc`. The ExeFS side is covered by the inherited by3 loader. The
NRO side is the main missing piece before the game can reach gameplay.

The goal is not to repack the 15+ GB `data.arc`. It is to:

1. inventory the NROs once from the player's own dump;
2. rewrite each NRO into a native ARM64 sidecar keyed by its build ID;
3. replace `nn::ro::LoadModule` in the host so the original buffer is ignored and the verified sidecar is mapped.

That keeps the archive intact and makes a module patch a small sidecar change instead of a full archive rewrite.

## 1. Inventory and extraction

`scripts/extract_nros.py` scans the extracted `data.arc` for valid `NRO0` headers:

```sh
make nros
# or
python3 scripts/extract_nros.py SSBU_build/extracted/v1304/romfs/data.arc \
  --output SSBU_build/extracted/v1304/nros
```

The scanner is deliberately conservative but still **experimental**: it validates the NRO header and text/ro/data bounds,
not the ARC file table. If it finds nothing, the entries may be compressed/encrypted or the archive needs a real parser.
The manifest (`nros.json`) records offset, size, SHA-256 and segment layout.

Expected inventory from public references: 98 `lua2cpp_*` modules. Confirm the count and names from your own dump; do not
hard-code a count into the loader.

## 2. Identity: build ID, not path

An NRO may be loaded from a different archive offset after an update. Key the sidecar by a stable identity:

- Prefer the module's GNU build-id note / NRO module ID if present.
- Otherwise use the SHA-256 of the whole NRO as the initial key, and record the name and size as metadata.
- Never key by the `data.arc` offset alone.

Suggested work layout (all ignored by git):

```
SSBU_build/
  extracted/v1304/nros/
    nros.json
    0001a2b3-<sha-prefix>-lua2cpp_....nro
  rewritten/v1304/nros/
    <build-id>/
      image.patched.bin
      meta.json            # name, original SHA-256, rewrite SHA-256, segments, imports, gates
```

`meta.json` is what the host reads. The original `.nro` stays in `extracted/` for verification only.

## 3. Rewriter requirements

The inherited `third_party/d2r/patch_nso.py` handles `NSO0` images. NRO support needs a separate mode (or a small
NRO-to-NSO adapter) because:

- the NRO header is not the NSO header, and NRO segments are normally uncompressed;
- BSS is described by the NRO header, not by an NSO `bss_size` field in the same place;
- the dynamic section, symbol tables and REL/RELA/RELR relocations must be discovered from the NRO's own dynamic tags;
- the same Apple-silicon rewrites apply: `x18`/`tpidr_el0` slots, `svc`, `mrs cntpct_el0` gates, and any SSBU-specific
  cuts/observation points (registered by **SSBU build ID**, never by a by3 offset).

Do not copy the by3 `CUTS`/`OBS` tables into an SSBU build-ID entry. They are Bayonetta 3 offsets and are inert only
because the build ID does not match.

## 4. Loader requirements

`runtime/nro_loader.c` is the boundary. The real implementation needs:

1. **Parse** `NRO0`: text/ro/data offsets and sizes, BSS size, module name, dynamic table, API info.
2. **Find** the sidecar by build ID; verify its SHA-256 before mapping.
3. **Map** text as RX, rodata as R, data as RW, BSS as zero-filled RW, with the same relative layout the NRO expects.
4. **Relocate** REL/RELA/RELR entries; reject a relocation outside the data range or onto an unverified word.
5. **Resolve imports** through `runtime_override` / `runtime_symbol`; unresolved strong imports stop the load with the
   module and symbol name.
6. **Run** `DT_INIT` and the init array; verify the constructor state the same way the NSO loader does.
7. **Return** a handle that `nn::ro::UnloadModule` can use; implement `GetBufferSize` from the parsed header.
8. **Record** the module in the same permission/query tables as the ExeFS modules if the game asks `nn::ro` about it.

The first version should be loud: if a module has no sidecar, abort with its name and build ID. Silently executing the
original NRO is worse than stopping.

## 5. `nn::ro` shim

Register the real symbols in `runtime/system_services.c` only after the loader works. The likely names are the public
`nn::ro` API (`Initialize`, `LoadModule`, `UnloadModule`, `GetBufferSize`, `GetModuleCount`, `GetModuleInfo`), but the
exact mangled names must come from the SSBU `main`/`sdk` symbol tables. Do not guess them into the override table.

`LoadModule` should receive the game's original buffer, read its build ID, look up the sidecar, and ignore the original
bytes after verification. That is what avoids a `data.arc` repack.

## 6. Test plan

- Inventory: count and name every candidate; compare with the public 98-module expectation.
- Rewrite: structural checker + equivalence checks on each module, as the by3 NSO pipeline does.
- Loader: map one module, resolve a known import, run `DT_INIT`, call one exported function, unload.
- Integration: boot to the first `nn::ro::LoadModule`, then follow the next missing service/NVN call.
- Regression: every sidecar is hash-pinned; changing an NRO without regenerating its sidecar must fail.

## 7. Open questions

- Are the `lua2cpp_*` NROs stored uncompressed in `data.arc`, or does the archive layer decompress them?
- Does SSBU use NRO `nn::ro` for all 98 modules, or does some code load them through a custom loader?
- Are there NRO-to-NRO imports, or do all imports resolve against `main`/`sdk`/`subsdk0`?
- What is the exact build-ID source for each module (GNU note vs. a header field)?
- Does the game ever call `UnloadModule` during a match, or only at mode changes?

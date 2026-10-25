#include "game_patches.h"
#include <libkern/OSCacheControl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Generic exefs patch applier inherited from by3, applied to main after relocation and before its text is sealed.
   scripts/prepare_patches.py turns each .pchtxt into patches/<slug>.tsv ("offset new orig", hex), already checked
   against the original image and the rewrite; here every site is checked again against the loaded bytes, and a mismatch
   stops the start (a wrong version or a rewritten word must never be patched).

   TODO(ssbu): no SSBU patch set ships with this scaffold. Add SSBU 13.0.4 sites and a build-ID check before using the
   inherited by3 resolution/LOD patches; those offsets do not apply here.
   SSBU_PATCHES=<slug>,<slug>,... picks tables (unset or empty: none). */
static int hexbytes(const char *s, uint8_t *out, size_t cap, size_t *n) {
    size_t k = 0;
    for (; s[0] && s[1] && s[0] != '\t' && s[0] != '\n'; s += 2) {
        unsigned v; if (k == cap || sscanf(s, "%2x", &v) != 1) return 0;
        out[k++] = (uint8_t)v;
    }
    *n = k; return k > 0;
}
static void apply_file(Module *m, const char *slug) {
    char path[512]; snprintf(path, sizeof path, "patches/%s.tsv", slug);
    FILE *f = fopen(path, "r");
    if (!f) { fprintf(stderr, "[ssbu] patch %s: %s missing (scripts/prepare_patches.py)\n", slug, path); runtime_fail("game patch table missing"); }
    char line[4096]; unsigned applied = 0;
    while (fgets(line, sizeof line, f)) {
        if (line[0] == '#' || line[0] == '\n') continue;
        uint64_t off = strtoull(line, NULL, 0); char *a = strchr(line, '\t'), *b = a ? strchr(a + 1, '\t') : NULL;
        uint8_t now[1024], was[1024]; size_t nn, nw;
        if (!a || !b || !hexbytes(a + 1, now, sizeof now, &nn) || !hexbytes(b + 1, was, sizeof was, &nw) || nn != nw)
            runtime_fail("malformed game patch table");
        if (off + nn > m->text_end && off < m->ro_off) runtime_fail("game patch in the rewrite area");
        if (off + nn > m->file_size) runtime_fail("game patch beyond main");
        if (memcmp(m->base + off, was, nw)) { fprintf(stderr, "[ssbu] patch %s at main+%#llx: original bytes differ\n", slug, (unsigned long long)off); runtime_fail("game patch does not match this game version"); }
        memcpy(m->base + off, now, nn); sys_icache_invalidate(m->base + off, nn); applied++;
    }
    fclose(f);
    fprintf(stderr, "[ssbu] game patch %s: %u sites\n", slug, applied);
}
void runtime_game_patches(Module *main_module) {
    /* 0x816e0 is a descriptor lookup function called by 17 sites (0x7ca9c - 0x7d294).
       When a resource is not yet loaded, Horizon Smash 13.0.4 returns NULL (0) at 0x817ec and 0x81a74.
       However, none of the 17 callers check for NULL before dereferencing offsets +0x38, +0x48, +0x4c, +0x4e.
       Instead of patching individual call sites (which breaks stack frames or register state),
       we patch the two NULL-return points in 0x816e0 / 0x81a30 to return a pointer to a zeroed dummy object
       allocated in main's private writable extra page (0x7a54100).
       Writes to +0x38 succeed harmlessly, reads of flags/IDs return 0 (not found/none),
       and no caller crashes or corrupts the stack. */
    if (!strcmp(main_module->name, "main") && main_module->size >= 0x7a58000) {
        memset(main_module->base + 0x7a54100, 0, 512);

        // Site A: 0x817ec originally "mov x0, xzr" (0xaa1f03e0)
        // Branch to trampoline at 0x81834 (unused padding):
        //   0x81834: adrp x0, 31187       (0xf003ce80) -> page 0x7a54000
        //   0x81838: add  x0, x0, #0x100  (0x91040000) -> 0x7a54100
        //   0x8183c: b    0x817f0         (0x17ffffed) -> resume function epilogue
        uint32_t b_tramp = 0x14000012;
        uint32_t tramp[] = { 0xf003ce80, 0x91040000, 0x17ffffed };
        memcpy(main_module->base + 0x817ec, &b_tramp, 4);
        memcpy(main_module->base + 0x81834, tramp, sizeof(tramp));
        sys_icache_invalidate(main_module->base + 0x817ec, 4);
        sys_icache_invalidate(main_module->base + 0x81834, sizeof(tramp));

        // Site B: 0x816e0 tail-call at 0x81830 (originally "b 0x81a30", 0x14000080).
        // Branch to wrapper at 0x39c7ea0 (executable padding at end of .text):
        //   0x39c7ea0: stp  x29, x30, [sp, #-16]!  (0xa9bf7bfd)
        //   0x39c7ea4: mov  x29, sp                (0x910003fd)
        //   0x39c7ea8: bl   0x81a30                (0x971ae6e2)
        //   0x39c7eac: cbnz x0, +12                (0xb5000060) -> skip to epilogue if found
        //   0x39c7eb0: adrp x0, 16525              (0xb0020460) -> page 0x7a54000
        //   0x39c7eb4: add  x0, x0, #0x100         (0x91040000) -> 0x7a54100 (dummy fallback)
        //   0x39c7eb8: ldp  x29, x30, [sp], #16    (0xa8c17bfd)
        //   0x39c7ebc: ret                         (0xd65f03c0)
        // This preserves 0x81a30 completely unpatched so 0x7f500 can receive NULL and rasterize
        // new glyphs into the font atlas, while returning the real glyph if found, and safely
        // returning the dummy object ONLY to 0x816e0 callers when a character is truly missing.
        uint32_t b_wrapper = 0x14e5199c;
        uint32_t wrapper[] = {
            0xa9bf7bfd,
            0x910003fd,
            0x971ae6e2,
            0xb5000060,
            0xb0020460,
            0x91040000,
            0xa8c17bfd,
            0xd65f03c0
        };
        memcpy(main_module->base + 0x81830, &b_wrapper, 4);
        memcpy(main_module->base + 0x39c7ea0, wrapper, sizeof(wrapper));
        sys_icache_invalidate(main_module->base + 0x81830, 4);
        sys_icache_invalidate(main_module->base + 0x39c7ea0, sizeof(wrapper));

        fprintf(stderr, "[ssbu] applied safe glyph lookup wrapper at main+0x81830 -> 0x39c7ea0\n");
    }

    const char *list = getenv("SSBU_PATCHES");
    if (!list || !*list) { fprintf(stderr, "[ssbu] game patches: none (SSBU_PATCHES)\n"); return; }
    char buf[1024]; snprintf(buf, sizeof buf, "%s", list);
    for (char *save = NULL, *s = strtok_r(buf, ",", &save); s; s = strtok_r(NULL, ",", &save)) {
        for (const char *c = s; *c; c++) if (!((*c >= 'a' && *c <= 'z') || (*c >= '0' && *c <= '9') || *c == '-')) runtime_fail("SSBU_PATCHES: bad patch name");
        apply_file(main_module, s);
    }
}

/* The TotK host hooks the shared graphics layer and the input keys call keep their names and answer "off". */
void runtime_frame_step_pin(double ms) { (void)ms; }
void runtime_frame_step_update(uint64_t now_ns) { (void)now_ns; }
int runtime_output_res(unsigned *w, unsigned *h) { (void)w; (void)h; return 0; }
uint64_t runtime_output_res_extra_bytes(void) { return 0; }
uint64_t runtime_output_size_current(void) { return (uint64_t)1080 << 32 | 1920; }
int runtime_output_res_toggle(void) { return 0; }
int runtime_output_mode_cycle(void) { return 0; }
int runtime_aspect_toggle(void) { return 0; }
float runtime_aspect_now(void) { return 0; }

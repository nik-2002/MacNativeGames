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
static uint32_t arm64_bl(uint64_t from, uint64_t to) { return 0x94000000u | (uint32_t)(((int64_t)to - (int64_t)from) / 4 & 0x3ffffff); }
static uint32_t arm64_adrp(uint64_t from, uint64_t page, unsigned rd) {
    uint32_t imm = (uint32_t)(((int64_t)(page & ~0xfffull) - (int64_t)(from & ~0xfffull)) >> 12) & 0x1fffff;
    return 0x90000000u | (imm & 3) << 29 | (imm >> 2) << 5 | rd;
}
/* Glyph lookup main+0x816e0 (font manager, cp, size, style) returns the glyph's node in the manager's glyph cache, or
   NULL when the glyph is not registered there yet. 13 of its 17 callers check for NULL and then register the glyph or
   measure without it; four use the result directly: 0x7ca9c and 0x7cafc (right after registering the same glyph),
   0x7ccfc and 0x7cdb8. Only those four get a zeroed dummy glyph when the lookup has none (the wrapper at 0x39c7ea0,
   padding after .text). Before (2026-10-25), every lookup returned the dummy instead
   of NULL: the checking callers took a missing glyph for a present one and never registered it (about 2,400 lookups
   found nothing in one pass through the menus), and text was laid out with zero-width glyphs: it overflowed its boxes
   and icons covered the first letter. */
static void glyph_lookup_fallback(Module *m) {
    const uint64_t B = 0x39c7ea0, P = 0x7a54000;
    uint32_t w[] = { 0xa9bf7bfd, 0x910003fd, arm64_bl(B + 0x08, 0x816e0), 0xb50000c0, arm64_adrp(B + 0x10, P, 0),
                     0x91400c09, 0x5280002a, 0xb82a013f, 0x91040000, 0xa8c17bfd, 0xd65f03c0 };
    /* stp x29,x30; mov x29,sp; bl 0x816e0; cbnz x0,ret; adrp x0,page; add x9,x0,#0x3000; mov w10,#1; stadd w10,[x9];
       add x0,x0,#0x100; ldp x29,x30; ret */
    static const uint64_t sites[] = { 0x7ca9c, 0x7cafc, 0x7ccfc, 0x7cdb8 };
    memset(m->base + P, 0, 0x4000);
    memcpy(m->base + B, w, sizeof w); sys_icache_invalidate(m->base + B, sizeof w);
    for (size_t i = 0; i < sizeof sites / sizeof *sites; i++) {
        uint32_t old, want = arm64_bl(sites[i], 0x816e0), bl = arm64_bl(sites[i], B); memcpy(&old, m->base + sites[i], 4);
        if (old != want) runtime_fail("glyph lookup fallback: call site does not match 13.0.4");
        memcpy(m->base + sites[i], &bl, 4); sys_icache_invalidate(m->base + sites[i], 4);
    }
    fprintf(stderr, "[ssbu] glyph lookup: NULL-safe fallback at the 4 unchecked call sites\n");
}
void runtime_game_patches(Module *main_module) {
    if (!strcmp(main_module->name, "main") && main_module->size >= 0x7a58000) glyph_lookup_fallback(main_module);

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

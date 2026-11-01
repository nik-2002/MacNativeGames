/* Probe for the host H.264 movie::Decoder (runtime/movie_host.c, decoder type 1 through VideoToolbox), driven through its
   entries the way the game's movie player drives the library: every sample of a clip (scripts/movie_probe_avc_inputs.py:
   libx264 High profile with B-frames, 640x360) goes in, the outputs must come in presentation order and equal ffmpeg's
   own decode (packed NV12) byte for byte, outputs are held until all 8 output slots are taken so inputs have to wait, and
   end of stream comes out last. Each run plays the clip, flushes, and plays it again on the same decoder (a looping menu
   clip). Runs:
     lp      length-prefixed samples, SPS and PPS in the format's avcC record, the format names the movie's size
     annexb  start-code samples with in-band SPS and PPS, a format without a size (the host's default 1920x1080 must
             become the movie's own 640x360)
     vp9     the same check for the VP9 decoder (decoder type 3, libvpx at SSBU_MOVIE_THREADS, utility QoS): a libvpx clip
             from the same script, no reordering
   Stand-ins replace the guest's movie::Buffer, movie::MediaData and nn::os events (as games/totk/scripts/movie_probe.c).
   usage: movie-probe-avc <samples.bin> <ref.nv12> lp|annexb|vp9 */
#include "../runtime/movie_host.h"
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

_Noreturn void runtime_fail(const char *s) { fprintf(stderr, "movie probe: runtime_fail: %s\n", s); exit(3); }
static int checks;
static void need(int c, const char *fmt, ...) {
    checks++; if (c) return;
    va_list ap; va_start(ap, fmt); fprintf(stderr, "movie probe: FAILED: "); vfprintf(stderr, fmt, ap); fputc('\n', stderr); va_end(ap); exit(1);
}

/* ---- stand-ins for the guest ---- */
typedef struct { int offset, size; void *data; size_t cap; } Buf;
static void buf_set_range(void *b, int o, int s) { ((Buf *)b)->offset = o; ((Buf *)b)->size = s; }
static void buf_set_data(void *b, void *d, size_t c) { ((Buf *)b)->data = d; ((Buf *)b)->cap = c; }
static void *buf_base(const void *b) { return ((const Buf *)b)->data; }
static size_t buf_capacity(const void *b) { return ((const Buf *)b)->cap; }
static void *buf_data(const void *b) { return (uint8_t *)((const Buf *)b)->data + ((const Buf *)b)->offset; }
static size_t buf_size(const void *b) { return (size_t)((const Buf *)b)->size; }
typedef struct { char key[32]; int kind, v[4]; const char *s; Buf *b; } Entry;
typedef struct { Entry e[32]; int n; } Md;
static Entry *md_slot(Md *m, const char *k) { for (int i = 0; i < m->n; i++) if (!strcmp(m->e[i].key, k)) return &m->e[i]; if (m->n == 32) runtime_fail("md full"); Entry *e = &m->e[m->n++]; snprintf(e->key, sizeof e->key, "%s", k); return e; }
static const Entry *md_get(const Md *m, const char *k) { for (int i = 0; i < m->n; i++) if (!strcmp(m->e[i].key, k)) return &m->e[i]; return NULL; }
static bool md_find_int32(const void *m, const char *k, int *v) { const Entry *e = md_get(m, k); if (!e || e->kind != 1) return false; *v = e->v[0]; return true; }
static bool md_find_string(const void *m, const char *k, const char **v) { const Entry *e = md_get(m, k); if (!e || e->kind != 2) return false; *v = e->s; return true; }
static bool md_find_buffer(const void *m, const char *k, void **b) { const Entry *e = md_get(m, k); if (!e || e->kind != 4) return false; *b = e->b; return true; }
static void md_set_int32(void *m, const char *k, int v) { Entry *e = md_slot(m, k); e->kind = 1; e->v[0] = v; }
static void md_set_rect(void *m, const char *k, int l, int t, int r, int b) { Entry *e = md_slot(m, k); e->kind = 3; e->v[0] = l; e->v[1] = t; e->v[2] = r; e->v[3] = b; }
static void md_set_string(void *m, const char *k, const char *v) { Entry *e = md_slot(m, k); e->kind = 2; e->s = v; }
static void md_set_buffer(Md *m, const char *k, Buf *b) { Entry *e = md_slot(m, k); e->kind = 4; e->b = b; }
typedef struct { int count; } Event;
static void signal_event(void *ev) { ((Event *)ev)->count++; }
static int orig_d0_calls;
static void orig_d0(void *obj) { orig_d0_calls++; (void)obj; }
static int orig_other(void) { return 0x7776; }
static char fake_vtable[0xa8];
void *runtime_symbol(const char *name) {   /* the guest symbols the H.264 path resolves itself */
    if (!strcmp(name, "_ZNK5movie6Buffer4DataEv")) return (void *)buf_data;
    if (!strcmp(name, "_ZNK5movie6Buffer4SizeEv")) return (void *)buf_size;
    if (!strcmp(name, "_ZNK5movie9MediaData10FindBufferEPKcPPNS_6BufferE")) return (void *)md_find_buffer;
    return NULL;
}

/* ---- entries ---- */
typedef void (*ctor_t)(void *, int, int, int, int); typedef void (*obj_t)(void *);
typedef int (*md_t)(void *, void *); typedef int (*int_t)(void *); typedef int (*pp_t)(void *, int *, int *);
typedef int (*ib_t)(void *, int, void *); typedef int (*send_t)(void *, int, int, int, int64_t, unsigned);
typedef int (*acq_t)(void *, int *, int64_t *, unsigned *, int *); typedef int (*i_t)(void *, int);
#define E(t, w) ((t)movie_host_entry(w))

static uint8_t *read_file(const char *path, size_t *n) {
    FILE *f = fopen(path, "rb"); if (!f) { perror(path); exit(2); }
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *b = malloc((size_t)sz); if (!b || fread(b, 1, (size_t)sz, f) != (size_t)sz) { perror(path); exit(2); }
    fclose(f); *n = (size_t)sz; return b;
}
typedef struct { const uint8_t *p; uint32_t n; int64_t pts; } Sample;
static int cmp_i64(const void *a, const void *b) { int64_t x = *(const int64_t *)a, y = *(const int64_t *)b; return x < y ? -1 : x > y; }

/* One play of the clip: every sample, then end of stream; every output compared, in presentation order. Input buffers
   the player took and did not fill stay its own across a flush, as the game's do (the host gives them out again only
   when they are sent). */
static int in_free[16], nfree;
static int play(void *dec, Event *ev, const Sample *s, int ns, const int64_t *order, const uint8_t *ref, int W, int H, int pass) {
    size_t fb = (size_t)W * H * 3 / 2; uint8_t *dst = malloc(fb); Buf ob = {0};
    int held[16], frame_of[16] = {0}, nheld = 0, next = 0, compared = 0, eos_sent = 0, eos_seen = 0, peak = 0, last = -1;
    for (int guard = 0; !eos_seen || nheld; guard++) {
        need(guard < 100000, "pass %d: decode loop makes progress (compared %d, next %d)", pass, compared, next);
        for (;;) {
            int idx = -1, rem = 0, st = E(pp_t, MOVIE_ACQUIRE_INPUT)(dec, &idx, &rem);
            if (st) { need(st == 0x1011 && idx == -1, "no input: 0x1011"); break; }
            in_free[nfree++] = idx;
        }
        while (nfree && !eos_sent) {
            int idx = in_free[0]; memmove(in_free, in_free + 1, (size_t)--nfree * sizeof in_free[0]);
            Buf ib = {0}; need(E(ib_t, MOVIE_GET_INPUT)(dec, idx, &ib) == 0 && ib.data && ib.cap >= (2u << 20), "input buffer %d", idx);
            if (next < ns) {
                memcpy(ib.data, s[next].p, s[next].n);
                need(E(send_t, MOVIE_SEND_INPUT)(dec, idx, 0, (int)s[next].n, s[next].pts, 0) == 0, "SendInputBufferForDecode %d", next);
                next++;
            } else { need(E(send_t, MOVIE_SEND_INPUT)(dec, idx, 0, 0, 0, 4) == 0, "end of stream input"); eos_sent = 1; }
        }
        for (;;) {
            int idx = -1, rem = 0; int64_t t = 0; unsigned fl = 0;
            int st = E(acq_t, MOVIE_ACQUIRE_OUTPUT)(dec, &idx, &t, &fl, &rem);
            if (st) { need(st == 0x100e && idx == -1, "no output: 0x100e"); break; }
            need(ev[2].count >= 1, "format changed signalled before the first output");
            if (fl & 4) { need(compared + nheld == ns, "pass %d: end of stream after all %d frames (got %d)", pass, ns, compared + nheld); need(E(i_t, MOVIE_RELEASE_OUTPUT)(dec, idx) == 0, "release EOS"); eos_seen = 1; break; }
            int k = 0; while (k < ns && order[k] != t) k++;
            need(k < ns && k == last + 1, "pass %d: output time %lld is frame %d, expected frame %d (presentation order)", pass, (long long)t, k, last + 1);
            last = k; frame_of[idx] = k; held[nheld++] = idx; if (nheld > peak) peak = nheld;
        }
        while (nheld && (nheld >= 8 || !nfree || eos_sent)) {
            buf_set_data(&ob, dst, fb); buf_set_range(&ob, 0, (int)fb);
            need(E(ib_t, MOVIE_GET_OUTPUT)(dec, held[0], &ob) == 0 && ob.offset == 0 && ob.size == (int)fb, "GetOutputBuffer frame %d (size %d)", compared, ob.size);
            size_t fk = (size_t)frame_of[held[0]];
            if (memcmp(dst, ref + fb * fk, fb)) {
                size_t k = 0; while (dst[k] == ref[fb * fk + k]) k++;
                need(0, "pass %d: frame %zu differs from ffmpeg's decode at byte %zu (%s plane): %u vs %u", pass, fk, k, k < (size_t)W * H ? "Y" : "UV", dst[k], ref[fb * fk + k]);
            }
            checks++;
            need(E(i_t, MOVIE_RELEASE_OUTPUT)(dec, held[0]) == 0, "ReleaseOutputBufferIndex"); compared++;
            memmove(held, held + 1, (size_t)--nheld * sizeof held[0]);
            break;
        }
    }
    need(compared == ns, "pass %d: frames compared %d of %d", pass, compared, ns);
    need(peak == 8, "pass %d: all 8 output slots were held at once (peak %d): inputs had to wait", pass, peak);
    free(dst); return compared;
}

int main(int argc, char **argv) {
    if (argc != 4 || (strcmp(argv[3], "lp") && strcmp(argv[3], "annexb") && strcmp(argv[3], "vp9"))) { fprintf(stderr, "usage: movie-probe-avc <samples.bin> <ref.nv12> lp|annexb|vp9\n"); return 2; }
    const int lp = !strcmp(argv[3], "lp"), vp9 = !strcmp(argv[3], "vp9");
    setenv("TOTK_MOVIE_PACE", "0", 1);
    MovieGuest api = {signal_event, buf_set_range, buf_set_data, buf_base, buf_capacity, md_find_int32, md_find_string,
                      md_set_int32, md_set_rect, md_set_string, fake_vtable + 0x10, {0}};
    for (int i = 0; i < MOVIE_ENTRIES; i++) api.orig[i] = (void *)orig_other;
    api.orig[MOVIE_D0] = (void *)orig_d0;
    movie_host_set_guest(&api);
    size_t fn, rn; uint8_t *f = read_file(argv[1], &fn), *ref = read_file(argv[2], &rn);
    uint32_t hd[4]; need(fn > 20 && !memcmp(f, "AVCP", 4), "sample file header"); memcpy(hd, f + 4, 16);
    int W = (int)hd[0], H = (int)hd[1], ns = (int)hd[2]; uint32_t avcc_n = hd[3]; size_t fb = (size_t)W * H * 3 / 2;
    need(rn == fb * (size_t)ns, "reference holds %d frames of %zu bytes", ns, fb);
    const uint8_t *avcc = f + 20; size_t pos = 20 + avcc_n;
    Sample *s = calloc((size_t)ns, sizeof *s); int64_t *order = calloc((size_t)ns, sizeof *order);
    for (int i = 0; i < ns; i++) {
        need(pos + 12 <= fn, "sample %d header", i);
        memcpy(&s[i].n, f + pos, 4); memcpy(&s[i].pts, f + pos + 4, 8); pos += 12;
        need(pos + s[i].n <= fn, "sample %d size", i); s[i].p = f + pos; pos += s[i].n; order[i] = s[i].pts;
    }
    qsort(order, (size_t)ns, sizeof *order, cmp_i64);
    int reordered = 0; for (int i = 0; i < ns; i++) reordered += s[i].pts != order[i];
    need(vp9 ? reordered == 0 : reordered > 0, vp9 ? "VP9: presentation order is decode order" : "the clip has B-frames (decode order differs from presentation order)");

    void *dec[2] = {0}; E(ctor_t, MOVIE_CTOR)(dec, vp9 ? 3 : 1, 4, 1, 16);
    need(dec[0] == fake_vtable + 0x10 && dec[1] != NULL, "host decoder: library vtable, host state at +8");
    Event ev[4] = {{0}}; void *events[4] = {&ev[0], &ev[1], &ev[2], &ev[3]};
    need(E(md_t, MOVIE_REGISTER_EVENTS)(dec, events) == 0, "RegisterClientEvents");
    Md bad = {0}; md_set_string(&bad, "mime", vp9 ? "video/avc" : "video/x-vnd.on2.vp9"); md_set_int32(&bad, "width", W); md_set_int32(&bad, "height", H);
    need(E(md_t, MOVIE_CONFIGURE)(dec, &bad) == 0x2001, "the other codec's format is refused");
    Md fmt = {0}; md_set_string(&fmt, "mime", vp9 ? "video/x-vnd.on2.vp9" : "video/avc"); Buf rec = {0, (int)avcc_n, (void *)avcc, avcc_n};
    if (vp9) { md_set_int32(&fmt, "width", W); md_set_int32(&fmt, "height", H); }
    if (lp) { md_set_int32(&fmt, "width", W); md_set_int32(&fmt, "height", H); md_set_buffer(&fmt, "avcc", &rec); }
    need(E(md_t, MOVIE_CONFIGURE)(dec, &fmt) == 0, "Configure");
    need(E(int_t, MOVIE_START)(dec) == 0 && ev[0].count == 1, "Start signals input available");

    int frames = play(dec, ev, s, ns, order, ref, W, H, 1);
    int size = 0, count = 0; need(E(pp_t, MOVIE_GET_OUTPUT_SIZE)(dec, &size, &count) == 0 && size == (int)fb && count == 1, "output size %d count %d", size, count);
    Md of = {0}; need(E(md_t, MOVIE_GET_OUTPUT_FORMAT)(dec, &of) == 0, "GetOutputFormat"); int v;
    need(md_find_int32(&of, "width", &v) && v == W && md_find_int32(&of, "height", &v) && v == H && md_find_int32(&of, "nv12-uv-offset", &v) && v == W * H, "output format is the movie's %dx%d", W, H);
    need(E(int_t, MOVIE_FLUSH)(dec) == 0, "Flush");   /* the clip starts over on the same decoder */
    frames += play(dec, ev, s, ns, order, ref, W, H, 2);
    need(E(int_t, MOVIE_STOP)(dec) == 0, "Stop");
    E(obj_t, MOVIE_D0)(dec);
    need(orig_d0_calls == 1 && dec[1] == NULL && dec[0] == fake_vtable + 0x10, "delete: host state freed, the library frees the object");
    printf("{\"probe\":\"movie-avc\",\"run\":\"%s\",\"frames\":%d,\"reordered\":%d,\"checks\":%d,\"ok\":true}\n", argv[3], frames, reordered, checks);
    return 0;
}

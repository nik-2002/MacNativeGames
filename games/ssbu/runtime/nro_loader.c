/* Native NRO module loader and nn::ro HLE service for Super Smash Bros. Ultimate.
   Adapted from the MIT `NicholasDominici/super-smash-bros-ultimate-ios` NRO loader (`dm/host/hle_ro.c` and `loader.c`).
   Only exact cataloged NRO0 images with active NRR registrations are admitted, and execution always comes from
   offline-rewritten `.patched.bin` images, never from guest input buffers. */
#include "nro_loader.h"
#include "runtime.h"
#include <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <libkern/OSCacheControl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define RO_OK 0u
#define RO_FAIL (22u | (1u << 9))
#define RO_BAD_NRO 0x816u
#define RO_NOT_FOUND 0xa16u
#define RO_BAD_NRR 0xc16u
#define GAME_TITLE_ID_SSBU 0x01006a800016e000ull

enum {
    NRO_MAX = 128,
    RO_MODULES = 512,
    RO_REGISTRATIONS = 64,
    NRO_DEFERRED_MAX = 4096,
};

typedef struct {
    int64_t d_tag;
    union { uint64_t d_val; uint64_t d_ptr; } d_un;
} Elf64_Dyn;

typedef struct {
    uint32_t st_name;
    uint8_t st_info;
    uint8_t st_other;
    uint16_t st_shndx;
    uint64_t st_value;
    uint64_t st_size;
} Elf64_Sym;

typedef struct {
    uint64_t r_offset;
    uint64_t r_info;
    int64_t r_addend;
} Elf64_Rela;

enum {
    DT_PLTRELSZ = 2,
    DT_STRTAB = 5,
    DT_SYMTAB = 6,
    DT_RELA = 7,
    DT_RELASZ = 8,
    DT_STRSZ = 10,
    DT_INIT = 12,
    DT_FINI = 13,
    DT_JMPREL = 23,
    DT_INIT_ARRAY = 25,
    DT_INIT_ARRAYSZ = 27,
    R_AARCH64_ABS64 = 257,
    R_AARCH64_GLOB_DAT = 1025,
    R_AARCH64_JUMP_SLOT = 1026,
    R_AARCH64_RELATIVE = 1027,
    STB_LOCAL = 0,
    STB_WEAK = 2,
    STT_FUNC = 2,
    STV_DEFAULT = 0,
};

typedef struct {
    void *module;
    uint32_t loaded, reserved;
    const void *image;
    void *bss;
} ro_module_abi;

typedef struct {
    uint32_t registered, reserved;
    const void *image;
    void *prev, *next;
} ro_registration_abi;

_Static_assert(sizeof(ro_module_abi) == 0x20, "SDK Module ABI");
_Static_assert(sizeof(ro_registration_abi) == 0x20, "SDK RegistrationInfo ABI");

typedef struct {
    char name[32];
    const ssbu_nro_catalog_entry *catalog;
    uint8_t *base;
    size_t size, file_size;
    uint64_t text_end, ro_off, data_off, key_off, patch_off;
    unsigned key_idx[4];
    const Elf64_Dyn *dyn;
    const Elf64_Sym *symtab;
    const char *strtab;
    unsigned nsym;
    unsigned *symh, symh_mask;
    uint64_t init, fini, init_array, init_arraysz;
    void *nro_sdk_object;
    uint64_t load_serial;
    uint64_t dependencies[(NRO_MAX + 63) / 64];
    unsigned char *permissions;
    void *eh_frame;
    unsigned active : 1, initialized : 1, committed : 1, retiring : 1;
} NroModule;

typedef struct nro_region {
    char name[32];
    const char *source_name;
    uintptr_t base;
    size_t size;
    struct nro_region *next;
} nro_region;

typedef struct {
    uint64_t *slot;
    const ssbu_nro_export_entry *export_ent;
} nro_deferred;

typedef struct {
    void *guest;
    NroModule *module;
    unsigned loading;
} ro_module_record;

typedef struct {
    void *guest;
    unsigned count;
    uint8_t *hashes;
} ro_registration;

static char g_rewritten_dir[1024];
static NroModule g_nro[NRO_MAX];
static _Atomic(nro_region *) g_nro_regions[NRO_MAX];
static _Atomic unsigned g_nro_region_count;
static nro_region *g_nro_region_history;
static nro_deferred g_nro_deferred[NRO_DEFERRED_MAX];
static unsigned g_nro_deferred_count;
static ro_module_record g_ro_modules[RO_MODULES];
static ro_registration g_ro_registrations[RO_REGISTRATIONS];
static uint64_t g_load_serial;
static unsigned g_finalizing;

static pthread_once_t g_lock_once = PTHREAD_ONCE_INIT;
static pthread_mutex_t g_nro_lock;
static pthread_mutex_t g_perm_lock = PTHREAD_MUTEX_INITIALIZER;

static void lock_init(void) {
    pthread_mutexattr_t attr;
    pthread_mutexattr_init(&attr);
    pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&g_nro_lock, &attr);
    pthread_mutexattr_destroy(&attr);
}
static void nro_lock(void) { pthread_once(&g_lock_once, lock_init); pthread_mutex_lock(&g_nro_lock); }
static void nro_unlock(void) { pthread_mutex_unlock(&g_nro_lock); }

static size_t page_up(size_t x) { return (x + 0x3fff) & ~(size_t)0x3fff; }
static uint32_t read32(const void *p) { uint32_t n; memcpy(&n, p, 4); return n; }
static uint64_t read64(const void *p) { uint64_t n; memcpy(&n, p, 8); return n; }

void runtime_nro_set_rewritten_dir(const char *dir) {
    if (!dir || snprintf(g_rewritten_dir, sizeof g_rewritten_dir, "%s", dir) >= (int)sizeof g_rewritten_dir)
        runtime_fail("NRO rewritten directory path too long");
}

int runtime_nro_supported(void) {
    return g_ssbu_nro_catalog_count > 0 && g_ssbu_nro_catalog_count <= NRO_MAX &&
           g_ssbu_nrr_catalog_count > 0 && g_ssbu_nrr_catalog_count <= RO_REGISTRATIONS &&
           g_ssbu_nro_export_count > 0;
}

static void nro_deferred_unavailable(void) {
    runtime_fail("NRO function called before its provider module committed, or after unload");
}

static const ssbu_nro_export_entry *nro_export_find(const char *name) {
    if (!runtime_nro_supported() || !name) return NULL;
    unsigned lo = 0, hi = g_ssbu_nro_export_count;
    while (lo < hi) {
        unsigned mid = lo + (hi - lo) / 2;
        const ssbu_nro_export_entry *e = &g_ssbu_nro_exports[mid];
        int cmp = strcmp(name, e->name);
        if (!cmp) return e->module_index < g_ssbu_nro_catalog_count ? e : NULL;
        if (cmp < 0) hi = mid;
        else lo = mid + 1;
    }
    return NULL;
}

uintptr_t runtime_nro_defer_import(void *slot, const char *name, unsigned kind, int64_t addend) {
    const ssbu_nro_export_entry *e = nro_export_find(name);
    if (!e) return 0;
    if (e->type != STT_FUNC || (kind != R_AARCH64_GLOB_DAT && kind != R_AARCH64_JUMP_SLOT && kind != R_AARCH64_ABS64) ||
        addend != 0 || ((uintptr_t)slot & 7))
        runtime_fail("unsupported deferred NRO import");
    if (g_nro_deferred_count >= NRO_DEFERRED_MAX)
        runtime_fail("deferred NRO import table full");
    g_nro_deferred[g_nro_deferred_count++] = (nro_deferred){(uint64_t *)slot, e};
    return (uintptr_t)nro_deferred_unavailable;
}

static uint32_t sym_hash(const char *s) {
    uint32_t h = 2166136261u;
    while (*s) h = (h ^ (uint8_t)*s++) * 16777619u;
    return h;
}

static void build_symhash(NroModule *m) {
    unsigned cap = 16;
    while (cap < m->nsym * 2) cap <<= 1;
    m->symh = calloc(cap, sizeof *m->symh);
    if (!m->symh) runtime_fail("NRO symbol hash allocation");
    m->symh_mask = cap - 1;
    for (unsigned i = 1; i < m->nsym; i++) {
        const Elf64_Sym *s = &m->symtab[i];
        if (!s->st_shndx) continue;
        const char *nm = m->strtab + s->st_name;
        for (unsigned j = sym_hash(nm) & m->symh_mask;; j = (j + 1) & m->symh_mask) {
            if (!m->symh[j]) { m->symh[j] = i; break; }
            if (!strcmp(m->strtab + m->symtab[m->symh[j]].st_name, nm)) break;
        }
    }
}

static void *nro_module_sym(NroModule *m, const char *name) {
    if (!m || !m->base || !name || !m->symh) return NULL;
    for (unsigned j = sym_hash(name) & m->symh_mask; m->symh[j]; j = (j + 1) & m->symh_mask) {
        const Elf64_Sym *s = &m->symtab[m->symh[j]];
        if (!strcmp(m->strtab + s->st_name, name))
            return s->st_value < m->key_off ? m->base + s->st_value : NULL;
    }
    return NULL;
}

void *runtime_nro_symbol(const char *name) {
    if (!name || !runtime_nro_supported()) return NULL;
    nro_lock();
    void *found = NULL;
    uint64_t serial = UINT64_MAX;
    for (unsigned i = 0; i < g_ssbu_nro_catalog_count; i++) {
        NroModule *m = &g_nro[i];
        if (!m->active) continue;
        void *p = nro_module_sym(m, name);
        if (p && m->load_serial < serial) {
            found = p;
            serial = m->load_serial;
        }
    }
    nro_unlock();
    return found;
}

int runtime_nro_describe_address(uint64_t a, const char **name, uint64_t *off) {
    unsigned count = atomic_load_explicit(&g_nro_region_count, memory_order_acquire);
    for (unsigned i = 0; i < count; i++) {
        nro_region *r = atomic_load_explicit(&g_nro_regions[i], memory_order_acquire);
        if (!r) continue;
        if (a >= r->base && a - r->base < r->size) {
            if (name) *name = r->source_name ? r->source_name : r->name;
            if (off) *off = a - r->base;
            return 1;
        }
    }
    return 0;
}

uint64_t runtime_nro_image_bytes(void) {
    uint64_t bytes = 0;
    if (!runtime_nro_supported()) return 0;
    nro_lock();
    for (unsigned i = 0; i < g_ssbu_nro_catalog_count; i++)
        if (g_nro[i].base) bytes += g_nro[i].size;
    nro_unlock();
    return bytes;
}

static unsigned nro_page_permission(NroModule *m, uint64_t off) {
    if (off < m->data_off) return off < page_up(m->text_end) ? 5 : 1;
    if (off >= m->key_off) return off >= m->patch_off ? 5 : 1;
    return m->permissions ? m->permissions[(off - m->data_off) / 4096] : 3;
}

int runtime_nro_module_permission(uint64_t address, uint64_t size, unsigned permission, uint64_t *result_out) {
    unsigned count = atomic_load_explicit(&g_nro_region_count, memory_order_acquire);
    for (unsigned i = 0; i < count; i++) {
        nro_region *r = atomic_load_explicit(&g_nro_regions[i], memory_order_acquire);
        if (!r || address < r->base || address - r->base >= r->size) continue;
        NroModule *m = &g_nro[i];
        uint64_t base = (uintptr_t)m->base;
        if (!base || address < base || address - base < m->data_off || address - base >= m->key_off || size > m->key_off - (address - base)) {
            *result_out = 0xd401;
            return 1;
        }
        uint64_t off = address - base;
        pthread_mutex_lock(&g_perm_lock);
        if (!m->permissions) {
            size_t cnt = (m->key_off - m->data_off + 4095) / 4096;
            m->permissions = malloc(cnt);
            if (!m->permissions) runtime_fail("NRO permission table");
            memset(m->permissions, 3, cnt);
        }
        for (uint64_t p = 0; p < size / 4096; p++) {
            if (m->permissions[(off - m->data_off) / 4096 + p] & 16) {
                pthread_mutex_unlock(&g_perm_lock);
                *result_out = 0xd401;
                return 1;
            }
        }
        memset(m->permissions + (off - m->data_off) / 4096, permission, size / 4096);
        uint64_t lo = off & ~0x3fffULL, hi = page_up(off + size);
        for (uint64_t page = lo; page < hi; page += 0x4000) {
            unsigned combined = 0;
            for (unsigned p = 0; p < 4; p++) combined |= nro_page_permission(m, page + p * 4096);
            int prot = (combined & 1 ? PROT_READ : 0) | (combined & 2 ? PROT_WRITE : 0);
            if (combined & 4) runtime_fail("NRO permission overlaps executable page");
            if (mprotect(m->base + page, 0x4000, prot) != 0) runtime_fail("NRO data permission mprotect");
        }
        pthread_mutex_unlock(&g_perm_lock);
        *result_out = 0;
        return 1;
    }
    return 0;
}

int runtime_nro_module_lock_permission(uint64_t address, uint64_t size, unsigned mask, unsigned attribute, uint64_t *result_out) {
    (void)mask; (void)attribute;
    unsigned count = atomic_load_explicit(&g_nro_region_count, memory_order_acquire);
    for (unsigned i = 0; i < count; i++) {
        nro_region *r = atomic_load_explicit(&g_nro_regions[i], memory_order_acquire);
        if (!r || address < r->base || address - r->base >= r->size) continue;
        NroModule *m = &g_nro[i];
        uint64_t start = (uintptr_t)m->base;
        if (!start || address < start || address - start < m->data_off || address - start >= m->key_off || size > m->key_off - (address - start)) {
            *result_out = 0xd401;
            return 1;
        }
        pthread_mutex_lock(&g_perm_lock);
        if (!m->permissions) {
            size_t cnt = (m->key_off - m->data_off + 4095) / 4096;
            m->permissions = malloc(cnt);
            if (!m->permissions) runtime_fail("NRO attribute table");
            memset(m->permissions, 3, cnt);
        }
        size_t first = (address - start - m->data_off) / 4096;
        for (uint64_t p = 0; p < size / 4096; p++) m->permissions[first + p] |= 16;
        pthread_mutex_unlock(&g_perm_lock);
        *result_out = 0;
        return 1;
    }
    return 0;
}

int runtime_nro_module_query(uint64_t address, uint64_t *base, uint64_t *size, unsigned *state, unsigned *permission, unsigned *attribute) {
    unsigned count = atomic_load_explicit(&g_nro_region_count, memory_order_acquire);
    for (unsigned i = 0; i < count; i++) {
        nro_region *r = atomic_load_explicit(&g_nro_regions[i], memory_order_acquire);
        if (!r) continue;
        NroModule *m = &g_nro[i];
        uint64_t start = (uintptr_t)m->base;
        if (!start || address < start || address - start >= m->key_off) continue;
        uint64_t off = (address - start) & ~4095ULL, lo = off, hi = off + 4096;
        uint64_t text_bytes = page_up(m->text_end);
        pthread_mutex_lock(&g_perm_lock);
        unsigned perm = nro_page_permission(m, off);
        int data = off >= text_bytes;
        uint64_t limit = data ? text_bytes : 0, end = data ? m->key_off : text_bytes;
        while (lo > limit && nro_page_permission(m, lo - 4096) == perm) lo -= 4096;
        while (hi < end && nro_page_permission(m, hi) == perm) hi += 4096;
        pthread_mutex_unlock(&g_perm_lock);
        *base = start + lo;
        *size = hi - lo;
        *state = data ? 4 : 3;
        *permission = perm & 7;
        *attribute = perm & 16;
        static _Atomic int s_qlog = 0;
        if (atomic_fetch_add_explicit(&s_qlog, 1, memory_order_relaxed) < 20) {
            fprintf(stderr, "[ssbu-ro] module_query(%#llx for %s) -> base=%#llx size=%#llx state=%u perm=%u\n",
                    (unsigned long long)address, m->name, (unsigned long long)*base, (unsigned long long)*size, *state, *permission);
        }
        return 1;
    }
    return 0;
}

static uint64_t nro_deferred_target(NroModule *m, const ssbu_nro_export_entry *e) {
    if (!m || !m->base || e->module_index != (unsigned)(m - g_nro)) return 0;
    uintptr_t target = (uintptr_t)nro_module_sym(m, e->name), base = (uintptr_t)m->base;
    return target >= base && target - base == e->offset && e->offset < m->text_end ? target : 0;
}

static int nro_deferred_validate(NroModule *m) {
    for (unsigned i = 0; i < g_nro_deferred_count; i++) {
        const nro_deferred *d = &g_nro_deferred[i];
        if (d->export_ent->module_index == (unsigned)(m - g_nro) && !nro_deferred_target(m, d->export_ent)) {
            fprintf(stderr, "[ssbu-ro] NRO %s missing admitted export %s\n", m->name, d->export_ent->name);
            return 0;
        }
    }
    return 1;
}

static void nro_deferred_publish(NroModule *m, int available) {
    for (unsigned i = 0; i < g_nro_deferred_count; i++) {
        const nro_deferred *d = &g_nro_deferred[i];
        if (d->export_ent->module_index != (unsigned)(m - g_nro)) continue;
        uint64_t target = available ? nro_deferred_target(m, d->export_ent) : (uint64_t)nro_deferred_unavailable;
        if (!target) runtime_fail("NRO admitted export disappeared after initialization");
        atomic_store_explicit((_Atomic uint64_t *)d->slot, target, memory_order_release);
    }
}

static NroModule *dynamic_provider(uint64_t address) {
    for (unsigned i = 0; i < g_ssbu_nro_catalog_count; i++) {
        NroModule *m = &g_nro[i];
        uint64_t base = (uint64_t)m->base;
        if (base && address >= base && address - base < m->size) return m;
    }
    return NULL;
}

static void read_nro_layout(NroModule *m) {
    char path[1200];
    snprintf(path, sizeof path, "%s/%s.fixups.tsv", g_rewritten_dir, m->name);
    FILE *f = fopen(path, "r");
    if (!f) runtime_fail("cannot open NRO fixups.tsv");
    static const char *kn[4] = {"K18", "KTLS", "KTLR", "KGATE"};
    char line[256], key[32];
    unsigned long v;
    while (fgets(line, sizeof line, f)) {
        if (sscanf(line, "# %31s %lx", key, &v) != 2) continue;
        if (!strcmp(key, "PATCH_OFF")) m->patch_off = v;
        else if (!strcmp(key, "KEY_PAGE_OFF")) m->key_off = v;
        else if (!strcmp(key, "TEXT_END")) m->text_end = v;
        else if (!strcmp(key, "RO_OFF")) m->ro_off = v;
        else if (!strcmp(key, "DATA_OFF")) m->data_off = v;
        else for (int k = 0; k < 4; k++) {
            size_t n = strlen(kn[k]);
            if (!strncmp(key, "KEY_", 4) && !strncmp(key + 4, kn[k], n) && !strcmp(key + 4 + n, "_IDX"))
                m->key_idx[k] = (unsigned)strtoul(strrchr(line, '\t') + 1, NULL, 10);
        }
    }
    fclose(f);
    if (!m->patch_off || m->key_off % 0x4000) runtime_fail("invalid NRO layout in fixups.tsv");
}

static void map_nro_image(NroModule *m) {
    char path[1200];
    snprintf(path, sizeof path, "%s/%s.patched.bin", g_rewritten_dir, m->name);
    int fd = open(path, O_RDONLY);
    if (fd < 0) runtime_fail("cannot open NRO patched.bin");
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size <= 0) runtime_fail("stat NRO patched.bin");
    m->file_size = (size_t)st.st_size;
    m->size = page_up(m->file_size);
    m->base = mmap(NULL, m->size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (m->base == MAP_FAILED) runtime_fail("mmap NRO module");
    if (read(fd, m->base, m->file_size) != (ssize_t)m->file_size) runtime_fail("read NRO patched.bin");
    close(fd);

    uint64_t *key_page = (uint64_t *)(m->base + m->key_off);
    memset(key_page, 0, 0x4000);
    for (unsigned i = 0; i < 4; i++)
        key_page[m->key_idx[i]] = (uint64_t)runtime_keys[i] * 8;
    if (mprotect(m->base + m->key_off, 0x4000, PROT_READ) != 0) runtime_fail("NRO key page mprotect");

    size_t rx = page_up(m->text_end);
    if (mprotect(m->base, rx, PROT_READ | PROT_EXEC) != 0) runtime_fail("NRO text mprotect");
    size_t po = m->patch_off & ~(size_t)0x3fff;
    if (mprotect(m->base + po, m->size - po, PROT_READ | PROT_EXEC) != 0) runtime_fail("NRO patch mprotect");
    sys_icache_invalidate(m->base, rx);
    sys_icache_invalidate(m->base + po, m->size - po);
}

static void parse_nro_dynamic(NroModule *m) {
    uint32_t mod0 = *(uint32_t *)(m->base + 4);
    if (memcmp(m->base + mod0, "MOD0", 4) != 0) runtime_fail("NRO missing MOD0");
    m->dyn = (const Elf64_Dyn *)(m->base + mod0 + *(int32_t *)(m->base + mod0 + 4));
    for (const Elf64_Dyn *d = m->dyn; d->d_tag; d++) {
        switch (d->d_tag) {
        case DT_SYMTAB: m->symtab = (const Elf64_Sym *)(m->base + d->d_un.d_ptr); break;
        case DT_STRTAB: m->strtab = (const char *)(m->base + d->d_un.d_ptr); break;
        case DT_INIT: m->init = d->d_un.d_ptr; break;
        case DT_FINI: m->fini = d->d_un.d_ptr; break;
        case DT_INIT_ARRAY: m->init_array = d->d_un.d_ptr; break;
        case DT_INIT_ARRAYSZ: m->init_arraysz = d->d_un.d_val; break;
        }
    }
    m->nsym = (unsigned)(((const uint8_t *)m->strtab - (const uint8_t *)m->symtab) / sizeof(Elf64_Sym));
    build_symhash(m);
}

static uintptr_t resolve_nro_import(const char *name, unsigned kind) {
    void *p = kind == R_AARCH64_JUMP_SLOT ? runtime_observer(name) : NULL;
    if (!p) p = runtime_override(name);
    if (p) return (uintptr_t)runtime_hle_wrap_named(p, name);
    p = runtime_symbol(name);
    return (uintptr_t)p;
}

static int relocate_nro(NroModule *m) {
    uint64_t rela = 0, relasz = 0, jmprel = 0, pltsz = 0;
    for (const Elf64_Dyn *d = m->dyn; d->d_tag; d++) {
        switch (d->d_tag) {
        case DT_RELA: rela = d->d_un.d_ptr; break;
        case DT_RELASZ: relasz = d->d_un.d_val; break;
        case DT_JMPREL: jmprel = d->d_un.d_ptr; break;
        case DT_PLTRELSZ: pltsz = d->d_un.d_val; break;
        }
    }
    const Elf64_Rela *tabs[2] = {(const Elf64_Rela *)(m->base + rela), (const Elf64_Rela *)(m->base + jmprel)};
    uint64_t sizes[2] = {relasz, pltsz};
    for (int t = 0; t < 2; t++) {
        for (uint64_t i = 0; i < sizes[t] / sizeof(Elf64_Rela); i++) {
            const Elf64_Rela *r = &tabs[t][i];
            uint64_t *where = (uint64_t *)(m->base + r->r_offset);
            unsigned type = (unsigned)(r->r_info & 0xffffffffu), si = (unsigned)(r->r_info >> 32);
            if (!type) continue;
            if (type == R_AARCH64_RELATIVE) {
                *where = (uint64_t)m->base + r->r_addend;
                continue;
            }
            const Elf64_Sym *s = &m->symtab[si];
            const char *nm = m->strtab + s->st_name;
            uint64_t v = 0;
            void *ov = type == R_AARCH64_JUMP_SLOT ? runtime_observer(nm) : NULL;
            if (!ov) ov = runtime_override(nm);
            if (ov) v = (uint64_t)runtime_hle_wrap_named(ov, nm);
            if (!v && s->st_shndx) {
                uint64_t self = (uint64_t)m->base + s->st_value;
                unsigned bind = s->st_info >> 4, vis = s->st_other & 3;
                v = (bind == STB_LOCAL || vis != STV_DEFAULT) ? self : (uint64_t)runtime_symbol(nm);
                if (!v) v = self;
            }
            int weak0 = !v && !s->st_shndx && (s->st_info >> 4) == STB_WEAK && !runtime_symbol(nm) && !runtime_override(nm);
            if (!v && !weak0) v = resolve_nro_import(nm, type);
            if (!v && !weak0) {
                fprintf(stderr, "[ssbu-ro] NRO %s (%s) unresolved strong import %s\n",
                        m->name, m->catalog->source_name, nm);
                return 0;
            }
            if (v) {
                NroModule *provider = dynamic_provider(v);
                if (provider && provider != m) {
                    unsigned slot = (unsigned)(provider - g_nro);
                    m->dependencies[slot / 64] |= 1ull << (slot % 64);
                }
            }
            if (type == R_AARCH64_JUMP_SLOT) *where = v;
            else *where = v + r->r_addend;
        }
    }
    return 1;
}

static void dynamic_release(NroModule *m) {
    atomic_store_explicit(&g_nro_regions[m - g_nro], NULL, memory_order_release);
    if (m->base) munmap(m->base, m->size);
    free(m->symh);
    pthread_mutex_lock(&g_perm_lock);
    free(m->permissions);
    m->permissions = NULL;
    pthread_mutex_unlock(&g_perm_lock);
    memset(m, 0, sizeof *m);
}

static void dynamic_collect(void) {
    unsigned retained[NRO_MAX] = {0};
    for (unsigned i = 0; i < g_ssbu_nro_catalog_count; i++)
        retained[i] = g_nro[i].base && !g_nro[i].retiring;
    int changed;
    do {
        changed = 0;
        for (unsigned i = 0; i < g_ssbu_nro_catalog_count; i++) {
            if (!retained[i]) continue;
            for (unsigned j = 0; j < g_ssbu_nro_catalog_count; j++) {
                if (!retained[j] && (g_nro[i].dependencies[j / 64] & (1ull << (j % 64)))) {
                    retained[j] = 1;
                    changed = 1;
                }
            }
        }
    } while (changed);
    for (unsigned i = 0; i < g_ssbu_nro_catalog_count; i++)
        if (g_nro[i].base && g_nro[i].retiring && !retained[i])
            dynamic_release(&g_nro[i]);
}

static const ssbu_nro_catalog_entry *nro_identify(const void *image) {
    if (!runtime_nro_supported() || !image || memcmp((const uint8_t *)image + 0x10, "NRO0", 4) != 0)
        return NULL;
    uint32_t size = read32((const uint8_t *)image + 0x18);
    uint32_t bss = read32((const uint8_t *)image + 0x38);
    if (size < 0x80 || size > 256u * 1024 * 1024 || bss > 256u * 1024 * 1024)
        return NULL;
    int candidate = 0;
    for (unsigned i = 0; i < g_ssbu_nro_catalog_count; i++)
        candidate |= (g_ssbu_nro_catalog[i].image_size == size && g_ssbu_nro_catalog[i].bss_size == bss);
    if (!candidate) return NULL;
    uint8_t hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(image, size, hash);
    for (unsigned i = 0; i < g_ssbu_nro_catalog_count; i++) {
        const ssbu_nro_catalog_entry *e = &g_ssbu_nro_catalog[i];
        if (e->image_size == size && e->bss_size == bss && !memcmp(e->sha256, hash, sizeof hash))
            return e;
    }
    return NULL;
}

static NroModule *nro_load_entry(const ssbu_nro_catalog_entry *entry) {
    unsigned index = (unsigned)(entry - g_ssbu_nro_catalog);
    if (index >= g_ssbu_nro_catalog_count || index >= NRO_MAX) return NULL;
    NroModule *m = &g_nro[index];
    if (m->base) return NULL;
    snprintf(m->name, sizeof m->name, "%s", entry->name);
    m->catalog = entry;
    m->active = 1;
    m->load_serial = ++g_load_serial;
    read_nro_layout(m);
    map_nro_image(m);
    parse_nro_dynamic(m);
    if (!nro_deferred_validate(m) || !relocate_nro(m)) {
        dynamic_release(m);
        return NULL;
    }

    uint32_t mod0 = *(uint32_t *)(m->base + 4);
    int64_t object_offset = (int64_t)mod0 + *(int32_t *)(m->base + mod0 + 0x18);
    typedef void (*initialize_fn)(void *, uintptr_t, size_t, const Elf64_Dyn *, unsigned);
    initialize_fn initialize = (initialize_fn)runtime_symbol("_ZN2nn2ro6detail8RoModule10InitializeEmmPKNS1_3Elf5Elf643DynEb");
    if (!initialize || object_offset < (int64_t)m->data_off || (uint64_t)object_offset + 0xd0 > m->size) {
        dynamic_release(m);
        return NULL;
    }
    m->nro_sdk_object = m->base + object_offset;
    ((void **)m->nro_sdk_object)[0] = ((void **)m->nro_sdk_object)[1] = m->nro_sdk_object;
    initialize(m->nro_sdk_object, (uintptr_t)m->base, entry->image_size + entry->bss_size, m->dyn, 0);

    uint32_t eh_start = *(uint32_t *)(m->base + mod0 + 16);
    uint32_t eh_end = *(uint32_t *)(m->base + mod0 + 20);
    if (eh_start != 0 && eh_end > eh_start) {
        uint8_t *hdr = m->base + mod0 + eh_start;
        int32_t eh_rel = *(int32_t *)(hdr + 4);
        void *eh_frame = (void *)(hdr + 4 + eh_rel);
        m->eh_frame = eh_frame;
        static void (*s_unw_add)(uintptr_t);
        if (!s_unw_add) {
            uint8_t *sdk_base = runtime_module_base("sdk");
            if (sdk_base) s_unw_add = (void (*)(uintptr_t))(void *)(sdk_base + 0x51e868);
        }
        if (s_unw_add) {
            s_unw_add((uintptr_t)eh_frame);
            fprintf(stderr, "[ssbu-ro] registered guest eh_frame %p for %s\n", eh_frame, m->name);
        }
    }

    nro_region *region = calloc(1, sizeof *region);
    if (!region) runtime_fail("NRO region allocation");
    snprintf(region->name, sizeof region->name, "%s", m->name);
    region->source_name = entry->source_name;
    region->base = (uintptr_t)m->base;
    region->size = m->size;
    region->next = g_nro_region_history;
    g_nro_region_history = region;
    atomic_store_explicit(&g_nro_regions[index], region, memory_order_release);
    if (atomic_load_explicit(&g_nro_region_count, memory_order_relaxed) <= index)
        atomic_store_explicit(&g_nro_region_count, index + 1, memory_order_release);

    if (m->init) ((void (*)(void))(m->base + m->init))();
    m->initialized = 1;
    fprintf(stderr, "[ssbu-ro] loaded %s (%s) at %p size=%#zx\n", m->name, entry->source_name, m->base, m->size);
    return m;
}

static int nro_commit(NroModule *m) {
    if (!m || !m->active || !m->initialized || m->retiring || m->committed) return 0;
    m->committed = 1;
    nro_deferred_publish(m, 1);
    return 1;
}

static int nro_unload(NroModule *m) {
    if (!m || !m->active) return 0;
    if (m->committed) {
        nro_deferred_publish(m, 0);
        m->committed = 0;
    }
    if (m->initialized && m->fini) ((void (*)(void))(m->base + m->fini))();
    if (m->eh_frame) {
        static void (*s_unw_remove)(uintptr_t);
        if (!s_unw_remove) {
            uint8_t *sdk_base = runtime_module_base("sdk");
            if (sdk_base) s_unw_remove = (void (*)(uintptr_t))(void *)(sdk_base + 0x51ea18);
        }
        if (s_unw_remove) {
            s_unw_remove((uintptr_t)m->eh_frame);
            fprintf(stderr, "[ssbu-ro] unregistered guest eh_frame %p for %s\n", m->eh_frame, m->name);
        }
        m->eh_frame = NULL;
    }
    m->initialized = m->active = 0;
    m->retiring = 1;
    fprintf(stderr, "[ssbu-ro] unloaded %s (%s)\n", m->name, m->catalog ? m->catalog->source_name : "?");
    dynamic_collect();
    return 1;
}

/* ---------- nn::ro HLE entry points ---------- */
static ro_module_record *find_ro_record(const void *guest) {
    for (unsigned i = 0; i < RO_MODULES; i++)
        if (g_ro_modules[i].guest == guest) return &g_ro_modules[i];
    return NULL;
}

static int is_registered_hash(const uint8_t hash[32]) {
    for (unsigned i = 0; i < RO_REGISTRATIONS; i++) {
        const ro_registration *r = &g_ro_registrations[i];
        for (unsigned j = 0; r->guest && j < r->count; j++)
            if (!memcmp(r->hashes + j * 32, hash, 32)) return 1;
    }
    return 0;
}

static uint32_t h_ro_Initialize(void) {
    fprintf(stderr, "[ssbu-ro] nn::ro::Initialize (%u cataloged NROs)\n", g_ssbu_nro_catalog_count);
    return RO_OK;
}

static uint32_t h_ro_LookupSymbol(uintptr_t *out, const char *name) {
    if (!out || !name) return RO_NOT_FOUND;
    nro_lock();
    void *p = runtime_symbol(name);
    if (p) *out = (uintptr_t)p;
    nro_unlock();
    return p ? RO_OK : RO_NOT_FOUND;
}

static uint32_t h_ro_LookupModuleSymbol(uintptr_t *out, const void *guest, const char *name) {
    if (!out || !guest || !name) return RO_NOT_FOUND;
    nro_lock();
    ro_module_record *rec = find_ro_record(guest);
    void *p = (rec && !rec->loading && rec->module && rec->module->active) ? nro_module_sym(rec->module, name) : NULL;
    if (p) *out = (uintptr_t)p;
    nro_unlock();
    return p ? RO_OK : RO_NOT_FOUND;
}

static uint32_t h_ro_GetBufferSize(size_t *out, const void *image) {
    if (!out) return RO_BAD_NRO;
    *out = 0;
    if (!runtime_nro_supported() || !image) return RO_FAIL;
    const ssbu_nro_catalog_entry *entry = nro_identify(image);
    if (!entry) return RO_BAD_NRO;
    *out = entry->bss_size;
    return RO_OK;
}

static uint32_t h_ro_LoadModule(void *guest, const void *image, void *bss, size_t size, int flag) {
    if (!runtime_nro_supported() || !guest || !image || flag < 0 || flag > 3) return RO_FAIL;
    const ssbu_nro_catalog_entry *entry = nro_identify(image);
    if (!entry || size < entry->bss_size || (entry->bss_size && !bss)) return RO_BAD_NRO;
    nro_lock();
    if (g_finalizing || find_ro_record(guest) || !is_registered_hash(entry->sha256)) {
        nro_unlock();
        return RO_FAIL;
    }
    ro_module_record *rec = NULL;
    for (unsigned i = 0; i < RO_MODULES; i++) {
        if (!g_ro_modules[i].guest) { rec = &g_ro_modules[i]; break; }
    }
    if (!rec) { nro_unlock(); return RO_FAIL; }
    *rec = (ro_module_record){guest, NULL, 1};
    NroModule *m = nro_load_entry(entry);
    if (!m) {
        memset(rec, 0, sizeof *rec);
        nro_unlock();
        return RO_FAIL;
    }
    ro_module_abi value = {m->nro_sdk_object, 1, 0, image, bss};
    memcpy(guest, &value, sizeof value);
    *rec = (ro_module_record){guest, m, 0};
    if (!nro_commit(m)) {
        memset(rec, 0, sizeof *rec);
        ((ro_module_abi *)guest)->loaded = 0;
        nro_unload(m);
        nro_unlock();
        return RO_FAIL;
    }
    nro_unlock();
    return RO_OK;
}

static uint32_t h_ro_LoadModule2(void *guest, const void *image, void *bss, size_t size, int flag, unsigned b) {
    if (b & 255) return RO_FAIL;
    return h_ro_LoadModule(guest, image, bss, size, flag);
}

static void h_ro_UnloadModule(void *guest) {
    if (!guest) return;
    nro_lock();
    ro_module_record *rec = find_ro_record(guest);
    if (rec && !rec->loading) {
        NroModule *m = rec->module;
        memset(rec, 0, sizeof *rec);
        nro_unload(m);
        ((ro_module_abi *)guest)->loaded = 0;
    }
    nro_unlock();
}

static uint32_t h_ro_RegisterModuleInfo(void *guest, const void *image) {
    if (!runtime_nro_supported() || !guest || !image || memcmp(image, "NRR0", 4) != 0)
        return RO_BAD_NRR;
    const uint8_t *bytes = image;
    uint32_t size = read32(bytes + 0x338), offset = read32(bytes + 0x340), count = read32(bytes + 0x344);
    if (size < 0x350 || size > 16u * 1024 * 1024 || offset < 0x350 || offset > size ||
        count > (size - offset) / 32 || read64(bytes + 0x330) != GAME_TITLE_ID_SSBU)
        return RO_BAD_NRR;
    uint8_t hash[32];
    CC_SHA256(image, size, hash);
    int allowed = 0;
    for (unsigned i = 0; i < g_ssbu_nrr_catalog_count; i++)
        allowed |= (g_ssbu_nrr_catalog[i].image_size == size && !memcmp(hash, g_ssbu_nrr_catalog[i].sha256, 32));
    if (!allowed) return RO_BAD_NRR;
    nro_lock();
    ro_registration *rec = NULL;
    for (unsigned i = 0; i < RO_REGISTRATIONS; i++) {
        if (g_ro_registrations[i].guest == guest) { nro_unlock(); return RO_FAIL; }
        if (!rec && !g_ro_registrations[i].guest) rec = &g_ro_registrations[i];
    }
    if (!rec || g_finalizing) { nro_unlock(); return RO_FAIL; }
    uint8_t *hashes = malloc(count ? (size_t)count * 32 : 1);
    if (!hashes) { nro_unlock(); return RO_FAIL; }
    memcpy(hashes, bytes + offset, (size_t)count * 32);
    *rec = (ro_registration){guest, count, hashes};
    ro_registration_abi value = {1, 0, image, (uint8_t *)guest + 0x10, (uint8_t *)guest + 0x10};
    memcpy(guest, &value, sizeof value);
    fprintf(stderr, "[ssbu-ro] registered NRR (%u hashes)\n", count);
    nro_unlock();
    return RO_OK;
}

static void h_ro_UnregisterModuleInfo(void *guest) {
    if (!guest) return;
    nro_lock();
    for (unsigned i = 0; i < RO_REGISTRATIONS; i++) {
        if (g_ro_registrations[i].guest == guest) {
            free(g_ro_registrations[i].hashes);
            memset(&g_ro_registrations[i], 0, sizeof g_ro_registrations[i]);
            ((ro_registration_abi *)guest)->registered = 0;
            break;
        }
    }
    nro_unlock();
}

static void h_ro_Finalize(void) {
    nro_lock();
    for (unsigned i = 0; i < RO_MODULES; i++) {
        if (g_ro_modules[i].loading) {
            nro_unlock();
            return;
        }
    }
    g_finalizing = 1;
    for (;;) {
        ro_module_record *last = NULL;
        for (unsigned i = 0; i < RO_MODULES; i++) {
            if (g_ro_modules[i].guest && (!last || g_ro_modules[i].module->load_serial > last->module->load_serial))
                last = &g_ro_modules[i];
        }
        if (!last) break;
        h_ro_UnloadModule(last->guest);
    }
    for (unsigned i = 0; i < RO_REGISTRATIONS; i++)
        if (g_ro_registrations[i].guest)
            h_ro_UnregisterModuleInfo(g_ro_registrations[i].guest);
    g_finalizing = 0;
    nro_unlock();
}

void *runtime_ro_override(const char *name) {
    static const struct { const char *name; void *fn; } entries[] = {
        {"_ZN2nn2ro10InitializeEv", h_ro_Initialize},
        {"_ZN2nn2ro8FinalizeEv", h_ro_Finalize},
        {"_ZN2nn2ro12LookupSymbolEPmPKc", h_ro_LookupSymbol},
        {"_ZN2nn2ro18LookupModuleSymbolEPmPKNS0_6ModuleEPKc", h_ro_LookupModuleSymbol},
        {"_ZN2nn2ro13GetBufferSizeEPmPKv", h_ro_GetBufferSize},
        {"_ZN2nn2ro10LoadModuleEPNS0_6ModuleEPKvPvmi", h_ro_LoadModule},
        {"_ZN2nn2ro10LoadModuleEPNS0_6ModuleEPKvPvmib", h_ro_LoadModule2},
        {"_ZN2nn2ro12UnloadModuleEPNS0_6ModuleE", h_ro_UnloadModule},
        {"_ZN2nn2ro18RegisterModuleInfoEPNS0_16RegistrationInfoEPKv", h_ro_RegisterModuleInfo},
        {"_ZN2nn2ro20UnregisterModuleInfoEPNS0_16RegistrationInfoE", h_ro_UnregisterModuleInfo},
    };
    for (size_t i = 0; i < sizeof entries / sizeof *entries; i++)
        if (!strcmp(name, entries[i].name)) return entries[i].fn;
    return NULL;
}


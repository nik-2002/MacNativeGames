/* Horizon services inherited from by3 plus SSBU-specific HLE services, answered in-process over IPC (ipc.c)
   or by SDK symbol name (runtime_ssbu_override). Command numbers and layouts follow the public switchbrew
   descriptions. Local Mii database and offline service stubs adapted from NicholasDominici/super-smash-bros-ultimate-ios
   and seedds/nxnative (MIT License). */
#include "runtime.h"
#include "ipc.h"
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <stdlib.h>

/* ---------- set: nn::settings ISettingsServer ---------- */
/* nn::settings::Language order -> language code (switchbrew "Settings services", LanguageCode). */
static const char *const language_codes[] = {
    "ja", "en-US", "fr", "de", "it", "es", "zh-CN", "ko", "nl", "pt", "ru", "zh-TW", "en-GB", "fr-CA", "es-419",
    "zh-Hans", "zh-Hant", "pt-BR",
};
enum { LANGUAGES = sizeof language_codes / sizeof *language_codes, REGION_USA = 1 };

static uint64_t code_of(unsigned language) {
    uint64_t v = 0;
    memcpy(&v, language_codes[language], strlen(language_codes[language]));
    return v;
}
/* Writes up to `room` codes into a guest out buffer; returns how many. */
static int32_t write_codes(uint64_t addr, uint64_t size) {
    uint64_t *out = ipc_guest(addr, size);
    int32_t n = 0;
    for (; n < LANGUAGES && (uint64_t)(n + 1) * 8 <= size; n++) out[n] = code_of((unsigned)n);
    return n;
}
static void settings_handler(IpcSession *s, const IpcRequest *rq, IpcResponse *rs) {
    switch (rq->cmd) {
    case 0: { uint64_t v = runtime_desired_language(); IPC_OUT(rs, v); return; }   /* GetLanguageCode */
    case 1: {                                                                    /* GetAvailableLanguageCodes (C buffer) */
        if (!rq->nc) runtime_fail("set GetAvailableLanguageCodes: no output buffer");
        int32_t n = write_codes(rq->c[0].addr, rq->c[0].size);
        rs->xout[rs->nxout++] = (IpcBuffer){rq->c[0].addr, (uint64_t)n * 8, 0};
        IPC_OUT(rs, n); return;
    }
    case 2: {                                                                    /* MakeLanguageCode(Language) */
        uint32_t language = IPC_ARG(rq, uint32_t, 0);
        if (language >= LANGUAGES) { fprintf(stderr, "[ssbu-set] MakeLanguageCode(%u)\n", language); runtime_fail("set MakeLanguageCode: unknown language"); }
        uint64_t v = code_of(language); IPC_OUT(rs, v); return;
    }
    case 3: case 6: { int32_t n = LANGUAGES; IPC_OUT(rs, n); return; }          /* GetAvailableLanguageCodeCount(2) */
    case 4: { int32_t v = REGION_USA; IPC_OUT(rs, v); return; }                   /* GetRegionCode */
    case 5: {                                                                    /* GetAvailableLanguageCodes2 (B buffer) */
        if (!rq->nb) runtime_fail("set GetAvailableLanguageCodes2: no output buffer");
        int32_t n = write_codes(rq->b[0].addr, rq->b[0].size); IPC_OUT(rs, n); return;
    }
    case 8: { uint8_t v = 0; IPC_OUT(rs, v); return; }                            /* GetQuestFlag: not a kiosk unit */
    default: ipc_unimplemented(s, rq);
    }
}

/* ---------- bsd:u: nn::socket, offline ---------- */
enum { BSD_ENETDOWN = 50, SK_EAI_FAIL = 4 };
static void bsd_result(IpcResponse *rs, int32_t ret, uint32_t err) { IPC_OUT(rs, ret); IPC_OUT(rs, err); }
static void bsd_handler(IpcSession *s, const IpcRequest *rq, IpcResponse *rs) {
    switch (rq->cmd) {
    case 0: { uint64_t pid = 0; IPC_OUT(rs, pid); return; }                         /* RegisterClient(config, tmem) */
    case 1: return;                                                               /* StartMonitoring(pid) */
    case 2: case 3:                                                               /* Socket / SocketExempt */
        fprintf(stderr, "[ssbu-net] socket(%u, %u, %u) refused: offline\n", IPC_ARG(rq, uint32_t, 0), IPC_ARG(rq, uint32_t, 4), IPC_ARG(rq, uint32_t, 8));
        bsd_result(rs, -1, BSD_ENETDOWN); return;
    default: ipc_unimplemented(s, rq);
    }
}

/* ---------- Generic Result / offline helpers ---------- */
#define RESULT(module, description) ((uint32_t)(module) | ((uint32_t)(description) << 9))
#define RES_FAIL RESULT(2, 1)
#define NIFM_UNAVAILABLE RESULT(110, 300)
#define SSL_UNAVAILABLE RESULT(123, 300)
#define NSA_UNAVAILABLE RESULT(124, 280)

static void nop(void) {}
static uint32_t ok(void) { return 0; }
static uint32_t fail(void) { return RES_FAIL; }
static uint8_t ret_false(void) { return 0; }
static uint8_t ret_true(void) { return 1; }
static uint32_t nifm_unavailable(void) { return NIFM_UNAVAILABLE; }
static uint32_t ssl_unavailable(void) { return SSL_UNAVAILABLE; }
static uint32_t nsa_unavailable(void) { return NSA_UNAVAILABLE; }
static void nifm_request(void) { static int once; if (!once++) fprintf(stderr, "[ssbu-net] network request: offline\n"); }
static int64_t network_clock_now(void) { return (int64_t)time(NULL); }   /* time_point: seconds since the epoch */
static void environment_identifier(char *out) { if (!out) runtime_fail("nsd environment output"); memset(out, 0, 8); memcpy(out, "lp1", 3); }
static void execute_program(int index, const void *param, uint64_t size) {
    (void)param; fprintf(stderr, "[ssbu] nn::oe::ExecuteProgram(%d, %llu bytes)\n", index, (unsigned long long)size);
}
static void push_open_users(void) {}
static uint32_t pop_open_users(int32_t *count, void *handles, int32_t max) {
    (void)handles; (void)max; if (!count) runtime_fail("PopOpenUsers count pointer"); *count = 0; return 0;
}

/* ---------- Local Mii service (nn::mii::Database) backed by genuine signed SDK templates ---------- */
enum { MII_SOURCE_DATABASE = 1, MII_SOURCE_DEFAULT = 2, MII_DEFAULT_COUNT = 6 };
typedef struct { uint8_t bytes[0x58]; } mii_char_info;
typedef struct { uint64_t alignment; uint8_t rest[0x3c]; } mii_store_data;
typedef struct { uint64_t words[2]; } mii_utility;
typedef struct { int age, gender, face_color; } mii_random_desc;
typedef struct { void *service; } mii_database;
_Static_assert(sizeof(mii_char_info) == 0x58, "SDK CharInfo size");
_Static_assert(sizeof(mii_store_data) == 0x48, "aligned StoreData workspace");
_Static_assert(sizeof(mii_utility) == 0x10, "SDK UtilityImpl size");
_Static_assert(sizeof(mii_database) == 8, "SDK Database size");

typedef struct {
    void (*utility_ctor)(mii_utility *);
    void (*utility_dtor)(mii_utility *);
    void (*build_default)(mii_store_data *, mii_utility *, int);
    void (*build_random)(mii_store_data *, mii_utility *, const mii_random_desc *);
    void (*from_ver3)(const void *, mii_store_data *, mii_utility *);
    void (*to_char)(mii_char_info *, const mii_store_data *);
    int (*verify_char)(const mii_char_info *);
    int (*verify_ver3)(const void *);
} mii_sdk_helpers;

static mii_sdk_helpers mii_helpers;
static mii_char_info mii_defaults[MII_DEFAULT_COUNT];
static pthread_once_t mii_helpers_once = PTHREAD_ONCE_INIT;
static int mii_helpers_ready;
static char mii_local_service;

static void mii_check_char(const mii_char_info *info) {
    int error = mii_helpers.verify_char(info);
    if (error) runtime_fail("mii: original SDK rejected generated CharInfo");
}
static void mii_make_default(mii_char_info *out, int index) {
    mii_utility utility;
    mii_store_data store = {0};
    mii_helpers.utility_ctor(&utility);
    mii_helpers.build_default(&store, &utility, index);
    mii_helpers.to_char(out, &store);
    mii_helpers.utility_dtor(&utility);
    mii_check_char(out);
}
static void mii_resolve_helpers(void) {
#define MII_HELPER(field, symbol) \
    mii_helpers.field = runtime_symbol(symbol); \
    if (!mii_helpers.field) { fprintf(stderr, "[ssbu-mii] missing SDK helper %s\n", symbol); return; }
    MII_HELPER(utility_ctor, "_ZN2nn3mii6detail11UtilityImplC1Ev");
    MII_HELPER(utility_dtor, "_ZN2nn3mii6detail11UtilityImplD1Ev");
    MII_HELPER(build_default, "_ZN2nn3mii6detail12StoreDataRaw12BuildDefaultEPNS1_11UtilityImplEi");
    MII_HELPER(build_random, "_ZN2nn3mii6detail12StoreDataRaw11BuildRandomEPNS1_11UtilityImplERKNS0_10RandomDescE");
    MII_HELPER(from_ver3, "_ZNK2nn3mii6detail16Ver3StoreDataRaw16BuildToStoreDataEPNS1_12StoreDataRawEPNS1_11UtilityImplE");
    MII_HELPER(to_char, "_ZN2nn3mii6detail11CharInfoRaw19SetFromStoreDataRawERKNS1_12StoreDataRawE");
    MII_HELPER(verify_char, "_ZNK2nn3mii6detail11CharInfoRaw6VerifyEv");
    MII_HELPER(verify_ver3, "_ZNK2nn3mii6detail16Ver3StoreDataRaw6VerifyEv");
#undef MII_HELPER
    for (int i = 0; i < MII_DEFAULT_COUNT; ++i) mii_make_default(&mii_defaults[i], i);
    mii_helpers_ready = 1;
    fprintf(stderr, "[ssbu-mii] local Mii database initialized (%d SDK default Miis)\n", MII_DEFAULT_COUNT);
}
static int mii_is_initialized(const mii_database *database) {
    return database && database->service == &mii_local_service && mii_helpers_ready;
}
static int mii_source_valid(int source) { return source >= 0 && !(source & ~3); }

static pthread_once_t mii_author_once = PTHREAD_ONCE_INIT;
static uint8_t mii_author_uuid[16];
static void mii_author_init(void) {
    arc4random_buf(mii_author_uuid, sizeof mii_author_uuid);
    mii_author_uuid[6] = (mii_author_uuid[6] & 15) | 0x40;
    mii_author_uuid[8] = (mii_author_uuid[8] & 63) | 0x80;
}
static void h_mii_GetDeviceId(void *out) {
    if (!out) runtime_fail("mii: null GetDeviceId output");
    pthread_once(&mii_author_once, mii_author_init);
    memcpy(out, mii_author_uuid, sizeof mii_author_uuid);
}
static void h_mii_Ctor(mii_database *database) { if (database) database->service = NULL; }
static void h_mii_Dtor(mii_database *database) { if (database) database->service = NULL; }
static uint32_t h_mii_Initialize(mii_database *database) {
    if (!database) return RES_FAIL;
    pthread_once(&mii_helpers_once, mii_resolve_helpers);
    if (!mii_helpers_ready) return RES_FAIL;
    database->service = &mii_local_service;
    return 0;
}
static int h_mii_IsUpdated(const mii_database *database, int source) {
    if (!mii_is_initialized(database) || !mii_source_valid(source)) runtime_fail("mii: IsUpdated invalid state");
    return 0;
}
static int h_mii_GetCount(const mii_database *database, int source) {
    if (!mii_is_initialized(database) || !mii_source_valid(source)) runtime_fail("mii: GetCount invalid state");
    return source & MII_SOURCE_DEFAULT ? MII_DEFAULT_COUNT : 0;
}
static uint32_t h_mii_Get(const mii_database *database, int *count, mii_char_info *out, int capacity, int source) {
    if (!count) return RES_FAIL;
    *count = 0;
    if (!mii_is_initialized(database) || !mii_source_valid(source) || capacity < 0 || (capacity && !out)) return RES_FAIL;
    int n = source & MII_SOURCE_DEFAULT ? MII_DEFAULT_COUNT : 0;
    if (n > capacity) n = capacity;
    if (n) memcpy(out, mii_defaults, (size_t)n * sizeof *out);
    *count = n;
    return 0;
}
static void h_mii_BuildDefault(const mii_database *database, mii_char_info *out, int index) {
    if (!mii_is_initialized(database) || !out || index < 0 || index >= MII_DEFAULT_COUNT) runtime_fail("mii: invalid BuildDefault arguments");
    mii_make_default(out, index);
}
static void h_mii_BuildRandom(const mii_database *database, mii_char_info *out, const mii_random_desc *description) {
    if (!mii_is_initialized(database) || !out || !description ||
        description->age < 0 || description->age > 3 || description->gender < 0 || description->gender > 2 ||
        description->face_color < 0 || description->face_color > 3) runtime_fail("mii: invalid BuildRandom arguments");
    mii_utility utility;
    mii_store_data store = {0};
    mii_helpers.utility_ctor(&utility);
    mii_helpers.build_random(&store, &utility, description);
    mii_helpers.to_char(out, &store);
    mii_helpers.utility_dtor(&utility);
    mii_check_char(out);
}
static uint32_t h_mii_Convert(const mii_database *database, mii_char_info *out, const void *legacy) {
    if (!mii_is_initialized(database) || !out || !legacy || mii_helpers.verify_ver3(legacy)) return RES_FAIL;
    mii_utility utility;
    mii_store_data store = {0};
    mii_char_info converted;
    mii_helpers.utility_ctor(&utility);
    mii_helpers.from_ver3(legacy, &store, &utility);
    mii_helpers.to_char(&converted, &store);
    mii_helpers.utility_dtor(&utility);
    if (mii_helpers.verify_char(&converted)) return RES_FAIL;
    memcpy(out, &converted, sizeof converted);
    return 0;
}
static uint32_t h_mii_AppendMii(int *index) {
    if (index) *index = -1;
    return 0xe7eu; /* SDK AppletOutput::GetResult cancellation result */
}

/* ---------- nn::ngc::ProfanityFilter ---------- */
static uint32_t ngc_v_zero(void) { return 0; }
static void ngc_v_none(void *self) { (void)self; }
static uint32_t ngc_v_check(void *self, uint32_t *masks, uint32_t pat, const void **words, uint64_t n) {
    (void)self; (void)pat; (void)words;
    for (uint64_t i = 0; masks && i < n; i++) masks[i] = 0;
    return 0;
}
static uint32_t ngc_v_mask(void *self, int *masked, void *text, uint32_t region) {
    (void)self; (void)text; (void)region;
    if (masked) *masked = 0;
    return 0;
}
static void *ngc_vtable(void) {
    enum { NV = 40 }; static void *vt[NV + 2]; static int built;
    if (built) return built > 0 ? &vt[2] : NULL;
    void **sdk = runtime_symbol("_ZTVN2nn3ngc15ProfanityFilterE");
    if (!sdk) { built = -1; return NULL; }
    static const struct { const char *name; void *fn; } M[] = {
        {"_ZN2nn3ngc15ProfanityFilterD1Ev", (void *)ngc_v_none}, {"_ZN2nn3ngc15ProfanityFilterD0Ev", (void *)ngc_v_none},
        {"_ZN2nn3ngc15ProfanityFilter8FinalizeEv", (void *)ngc_v_none},
        {"_ZN2nn3ngc15ProfanityFilter19CheckProfanityWordsEPjjPPKcm", (void *)ngc_v_check},
        {"_ZN2nn3ngc15ProfanityFilter19CheckProfanityWordsEPjjPPKDsm", (void *)ngc_v_check},
        {"_ZN2nn3ngc15ProfanityFilter19CheckProfanityWordsEPjjPPKtm", (void *)ngc_v_check},
        {"_ZN2nn3ngc15ProfanityFilter24MaskProfanityWordsInTextEPiPcj", (void *)ngc_v_mask},
        {"_ZN2nn3ngc15ProfanityFilter24MaskProfanityWordsInTextEPiPDsj", (void *)ngc_v_mask},
        {"_ZN2nn3ngc15ProfanityFilter24MaskProfanityWordsInTextEPiPtj", (void *)ngc_v_mask},
    };
    void *addr[sizeof M / sizeof *M];
    for (unsigned k = 0; k < sizeof M / sizeof *M; k++) addr[k] = runtime_symbol(M[k].name);
    vt[0] = sdk[0]; vt[1] = sdk[1];
    int n = 0;
    for (; n < NV && (uintptr_t)sdk[2 + n] >= 0x10000; n++) {
        vt[2 + n] = (void *)ngc_v_zero;
        for (unsigned k = 0; k < sizeof M / sizeof *M; k++) if (addr[k] && sdk[2 + n] == addr[k]) { vt[2 + n] = M[k].fn; break; }
    }
    built = 1;
    return &vt[2];
}
static void h_ngc_Ctor(void *self) { void *vt = ngc_vtable(); if (vt && self) memcpy(self, &vt, sizeof vt); }

/* ---------- Quiet bound events (ldn, friends, aoc, oe) ---------- */
static _Alignas(16) uint8_t g_ev_notify[0x100], g_ev_invite[0x100];
static void bind_event_arg(void *ev) { if (ev) hle_bind_system_event(ev, 0); }
static void *quiet_notify_ev(void *self) { (void)self; hle_bind_system_event(g_ev_notify, 0); return g_ev_notify; }
static void *quiet_invite_ev(void) { hle_bind_system_event(g_ev_invite, 0); return g_ev_invite; }
static uint32_t signal_event_arg2(void *self, void *ev) { (void)self; if (ev) hle_signal_system_event(ev); return 0; }
static uint32_t has_done_true(void *self, uint8_t *done) { (void)self; if (done) *done = 1; return 0; }
static void *move_self(void *self, void *other) { (void)other; return self; }
static uint32_t out_zero_fail(int *count) { if (count) *count = 0; return RES_FAIL; }
static uint32_t out_u64_zero_fail(uint64_t *n) { if (n) *n = 0; return RES_FAIL; }
static uint32_t out_ptr_null_fail(void **out) { if (out) *out = NULL; return RES_FAIL; }
static uint32_t out_bool_false_ok(uint8_t *out) { if (out) *out = 0; return 0; }
static uint32_t ldn_scan(void *out, int *n) { (void)out; if (n) *n = 0; return RES_FAIL; }
static uint32_t ldn_ip(uint32_t *a, uint32_t *m) { if (a) *a = 0; if (m) *m = 0; return RES_FAIL; }
static uint32_t nifm_ip_cfg(uint32_t *a, uint32_t *b, uint32_t *c, uint32_t *d, uint32_t *e) {
    uint32_t *p[5] = {a, b, c, d, e}; for (int i = 0; i < 5; i++) if (p[i]) *p[i] = 0; return NIFM_UNAVAILABLE;
}
static uint32_t nifm_primary_ip(uint32_t *a) { if (a) *a = 0; return NIFM_UNAVAILABLE; }
static uint32_t fr_blocked_list(int *count) { if (count) *count = 0; return RES_FAIL; }
static uint32_t ssl_import_pki(void *self, uint64_t *id) { (void)self; if (id) *id = 0; return SSL_UNAVAILABLE; }
static uint32_t pdm_play_stats(void *out, const void *ids, int count) {
    if (out && count > 0) memset(out, 0, (size_t)count * 0x28);
    (void)ids; return 0;
}

/* ---------- Sockets (C++ & C offline stubs) ---------- */
static __thread int t_skerr = BSD_ENETDOWN;
static int sk_fail(void) { t_skerr = BSD_ENETDOWN; return -1; }
static long sk_fail_l(void) { t_skerr = BSD_ENETDOWN; return -1; }
static int sk_errno(void) { return t_skerr; }
static void sk_set_errno(int e) { t_skerr = e; }
static void *sk_null_host(void) { t_skerr = BSD_ENETDOWN; return NULL; }
static int sk_gai(const char *h, const char *s, const void *hint, void **res) { (void)h; (void)s; (void)hint; if (res) *res = NULL; return SK_EAI_FAIL; }
static const char *sk_gai_str(int e) { (void)e; return "network unavailable"; }

/* ---------- nn::oe & nn::settings helpers ---------- */
static void oe_display_version(char *v) { if (v) { memset(v, 0, 16); memcpy(v, "13.0.4", 6); } }
static void oe_pseudo_device_id(uint8_t *uuid) {
    static const uint8_t k[16] = {0x78, 0x62, 0x6c, 0x00, 0x53, 0x57, 0x4e, 0x41, 0x54, 0x49, 0x56, 0x45, 0x31, 0x30, 0x30, 0x31};
    if (uuid) memcpy(uuid, k, 16);
}
static void oe_default_res(int *w, int *h) {
    int hh = runtime_handheld_mode();
    if (w) *w = hh ? 1280 : 1920;
    if (h) *h = hh ? 720 : 1080;
}
static int oe_perf_cfg(int mode) { return mode == 1 ? 0x00010001 : 0x00010000; }
static unsigned set_lang_eq(const int32_t *lang, const char *code) {
    if (!lang || !code || (unsigned)*lang >= LANGUAGES) return 0;
    return strncmp(language_codes[*lang], code, 8) == 0;
}
static unsigned set_lang_eq2(const char *code, const int32_t *lang) { return set_lang_eq(lang, code); }
static uint64_t set_lang_make(int lang) { return (unsigned)lang < LANGUAGES ? code_of((unsigned)lang) : 0; }

void *runtime_ssbu_override(const char *name) {
    static const struct { const char *name; void *fn; } entries[] = {
        /* nn::mii local database */
        {"_ZN2nn3mii6detail11GetDeviceIdEPNS1_8DeviceIdE", h_mii_GetDeviceId},
        {"_ZN2nn3mii8DatabaseC1Ev", h_mii_Ctor},
        {"_ZN2nn3mii8DatabaseD1Ev", h_mii_Dtor},
        {"_ZN2nn3mii8Database10InitializeEv", h_mii_Initialize},
        {"_ZN2nn3mii8Database9IsUpdatedEi", h_mii_IsUpdated},
        {"_ZNK2nn3mii8Database8GetCountEi", h_mii_GetCount},
        {"_ZN2nn3mii8Database3GetEPiPNS0_8CharInfoEii", h_mii_Get},
        {"_ZNK2nn3mii8Database12BuildDefaultEPNS0_8CharInfoEi", h_mii_BuildDefault},
        {"_ZN2nn3mii8Database11BuildRandomEPNS0_8CharInfoERKNS0_10RandomDescE", h_mii_BuildRandom},
        {"_ZN2nn3mii8Database7ConvertEPNS0_8CharInfoERKNS0_13Ver3StoreDataE", h_mii_Convert},
        {"_ZN2nn3mii9AppendMiiEPi", h_mii_AppendMii},

        /* nn::oe */
        {"_ZN2nn2oe13MuteRecordingEv", nop}, {"_ZN2nn2oe15UnmuteRecordingEv", nop},
        {"_ZN2nn2oe15EnableRecordingEv", nop}, {"_ZN2nn2oe16DisableRecordingEv", nop},
        {"_ZN2nn2oe16EnableScreenShotEv", nop}, {"_ZN2nn2oe17DisableScreenShotEv", nop},
        {"_ZN2nn2oe23BeginBlockingHomeButtonEv", nop}, {"_ZN2nn2oe21EndBlockingHomeButtonEv", nop},
        {"_ZN2nn2oe29SetScreenShotImageOrientationENS_5album16ImageOrientationE", nop},
        {"_ZN2nn2oe24SetAlbumImageOrientationENS_5album16ImageOrientationE", nop},
        {"_ZN2nn2oe37IsUserInactivityDetectionTimeExtendedEv", ret_false},
        {"_ZN2nn2oe30InitializeCopyrightFrameBufferEPvm", nop},
        {"_ZN2nn2oe17SetCopyrightImageEPKvmiiiiNS0_16WindowOriginModeE", nop},
        {"_ZN2nn2oe22SetCopyrightVisibilityEb", nop},
        {"_ZN2nn2oe21IsCpuOverclockEnabledEv", ret_false},
        {"_ZN2nn2oe27GetDefaultDisplayResolutionEPiS1_", oe_default_res},
        {"_ZN2nn2oe38GetDefaultDisplayResolutionChangeEventEPNS_2os11SystemEventE", bind_event_arg},
        {"_ZN2nn2oe40SendServerMaintenanceOverlayNotificationENS_4time9PosixTimeES2_", nop},
        {"_ZN2nn2oe27GetPerformanceConfigurationENS0_15PerformanceModeE", oe_perf_cfg},
        {"_ZN2nn2oe17GetDisplayVersionEPNS0_14DisplayVersionE", oe_display_version},
        {"_ZN2nn2oe17GetPseudoDeviceIdEPNS_4util4UuidE", oe_pseudo_device_id},
        {"_ZN2nn2oe31EnterExitRequestHandlingSectionEv", nop},
        {"_ZN2nn2oe31LeaveExitRequestHandlingSectionEv", nop},
        {"_ZN2nn2oe29BeginAutoSleepDisabledSectionEv", nop},
        {"_ZN2nn2oe27EndAutoSleepDisabledSectionEv", nop},
        {"_ZN2nn2oe20SwitchLcdBacklightOnEv", nop},
        {"_ZN2nn2oe21SwitchLcdBacklightOffEv", nop},
        {"_ZN2nn2oe27SetTvPowerStateMatchingModeENS0_24TvPowerStateMatchingModeE", nop},
        {"_ZN2nn2oe28RequestToRelaunchApplicationEv", nop},
        {"_ZN2nn2oe14ExecuteProgramEiPKvm", execute_program},

        /* nn::bcat */
        {"_ZN2nn4bcat10InitializeEv", nop},
        {"_ZN2nn4bcat25MountDeliveryCacheStorageEv", fail},
        {"_ZN2nn4bcat27UnmountDeliveryCacheStorageEv", nop},
        {"_ZN2nn4bcat24RequestSyncDeliveryCacheEPNS0_21DeliveryCacheProgressE", fail},
        {"_ZN2nn4bcat24RequestSyncDeliveryCacheEPNS0_21DeliveryCacheProgressEPKc", fail},
        {"_ZN2nn4bcat31EnumerateDeliveryCacheDirectoryEPiPNS0_13DirectoryNameEi", out_zero_fail},

        /* nn::album */
        {"_ZN2nn5album10InitializeEv", nop},
        {"_ZN2nn5album8FinalizeEv", nop},
        {"_ZN2nn5album14SaveScreenshotEPKvmNS0_9ImageSizeENS0_16ImageOrientationENS0_17AlbumReportOptionE", fail},
        {"_ZN2nn5album14SaveScreenshotEPKvmNS0_9ImageSizeENS0_17AlbumReportOptionE", fail},
        {"_ZN2nn5album22SaveAndShareScreenshotEPKvmNS0_9ImageSizeENS0_16ImageOrientationENS0_17AlbumReportOptionERKNS_7account3UidEPKc", fail},
        {"_ZN2nn5album22SaveAndShareScreenshotEPKvmNS0_9ImageSizeENS0_17AlbumReportOptionERKNS_7account3UidEPKc", fail},
        {"_ZN2nn5album26SaveScreenshotWithUserDataEPKvmNS0_9ImageSizeENS0_16ImageOrientationENS0_17AlbumReportOptionES2_m", fail},
        {"_ZN2nn5album14ShowAlbumFilesEv", fail},
        {"_ZN2nn5album21SaveCurrentScreenshotENS0_17AlbumReportOptionE", fail},
        {"_ZN2nn5album26GetAlbumScreenshotFileListEPiPNS0_14AlbumFileEntryEi", out_zero_fail},
        {"_ZN2nn5album21GetExtraMovieFileListEPiPNS0_14AlbumFileEntryEi", out_zero_fail},

        /* nn::ldn */
        {"_ZN2nn3ldn10InitializeEv", fail},
        {"_ZN2nn3ldn8FinalizeEv", nop},
        {"_ZN2nn3ldn8GetStateEv", ok},
        {"_ZN2nn3ldn22AttachStateChangeEventEPNS_2os15SystemEventTypeE", bind_event_arg},
        {"_ZN2nn3ldn11OpenStationEv", fail},
        {"_ZN2nn3ldn12CloseStationEv", fail},
        {"_ZN2nn3ldn15OpenAccessPointEv", fail},
        {"_ZN2nn3ldn16CloseAccessPointEv", fail},
        {"_ZN2nn3ldn10DisconnectEv", fail},
        {"_ZN2nn3ldn14DestroyNetworkEv", fail},
        {"_ZN2nn3ldn4ScanEPNS0_11NetworkInfoEPiiRKNS0_10ScanFilterEi", ldn_scan},
        {"_ZN2nn3ldn11ScanPrivateEPNS0_11NetworkInfoEPiiRKNS0_10ScanFilterEi", ldn_scan},
        {"_ZN2nn3ldn13CreateNetworkERKNS0_13NetworkConfigERKNS0_14SecurityConfigERKNS0_10UserConfigE", fail},
        {"_ZN2nn3ldn20CreateNetworkPrivateERKNS0_13NetworkConfigERKNS0_14SecurityConfigERKNS0_17SecurityParameterERKNS0_10UserConfigEiPKNS0_12AddressEntryE", fail},
        {"_ZN2nn3ldn7ConnectERKNS0_11NetworkInfoERKNS0_14SecurityConfigERKNS0_10UserConfigEiNS0_13ConnectOptionE", fail},
        {"_ZN2nn3ldn14ConnectPrivateERKNS0_13NetworkConfigERKNS0_14SecurityConfigERKNS0_17SecurityParameterERKNS0_10UserConfigEiNS0_13ConnectOptionE", fail},
        {"_ZN2nn3ldn14GetNetworkInfoEPNS0_11NetworkInfoE", fail},
        {"_ZN2nn3ldn16GetNetworkConfigEPNS0_13NetworkConfigE", fail},
        {"_ZN2nn3ldn14GetIpv4AddressEPNS0_11Ipv4AddressEPNS0_10SubnetMaskE", ldn_ip},
        {"_ZN2nn3ldn20GetSecurityParameterEPNS0_17SecurityParameterE", fail},
        {"_ZN2nn3ldn16SetAdvertiseDataEPKvm", fail},
        {"_ZN2nn3ldn19GetDisconnectReasonEv", ok},
        {"_ZN2nn3ldn20AddAcceptFilterEntryENS0_10MacAddressE", fail},
        {"_ZN2nn3ldn22SetStationAcceptPolicyENS0_12AcceptPolicyE", fail},
        {"_ZN2nn3ldn32SetWirelessControllerRestrictionENS0_29WirelessControllerRestrictionE", fail},
        {"_ZN2nn3ldn6RejectENS0_11Ipv4AddressE", fail},

        /* nn::nifm / nn::nsd */
        {"_ZN2nn4nifm10InitializeEv", ok},
        {"_ZN2nn4nifm18IsNetworkAvailableEv", ret_false},
        {"_ZN2nn4nifm20SubmitNetworkRequestEv", nifm_request},
        {"_ZN2nn4nifm27SubmitNetworkRequestAndWaitEv", nifm_request},
        {"_ZN2nn4nifm20CancelNetworkRequestEv", nop},
        {"_ZN2nn4nifm22IsNetworkRequestOnHoldEv", ret_false},
        {"_ZN2nn4nifm19SetLocalNetworkModeEb", nop},
        {"_ZN2nn4nifm31HandleNetworkRequestErrorResultEv", nifm_unavailable},
        {"_ZN2nn4nifm22GetCurrentProxySettingEPNS0_12ProxySettingE", nifm_unavailable},
        {"_ZN2nn4nifm26GetCurrentPrimaryIpAddressEPNS_6socket6InAddrE", nifm_primary_ip},
        {"_ZN2nn4nifm26GetCurrentPrimaryIpAddressEP7in_addr", nifm_primary_ip},
        {"_ZN2nn4nifm22GetCurrentIpConfigInfoEP7in_addrS2_S2_S2_S2_", nifm_ip_cfg},
        {"_ZN2nn4nifm22GetCurrentIpConfigInfoEPNS_6socket6InAddrES3_S3_S3_S3_", nifm_ip_cfg},
        {"_ZN2nn3nsd24GetEnvironmentIdentifierEPNS0_21EnvironmentIdentifierE", environment_identifier},
        {"_ZN2nn3nsd7ResolveEPNS0_4FqdnERKS1_", fail},
        {"_ZN2nn3nsd9ResolveExEPNS0_4FqdnERKS1_", fail},

        /* nn::socket & nnsocket* */
        {"_ZN2nn6socket10InitializeERKNS0_6ConfigE", ok},
        {"_ZN2nn6socket10InitializeEPvmmi", ok},
        {"_ZN2nn6socket8FinalizeEv", ok},
        {"_ZN2nn6socket12GetLastErrnoEv", sk_errno},
        {"_ZN2nn6socket12GetLastErrorEv", sk_errno},
        {"_ZN2nn6socket6SocketEiii", sk_fail},
        {"_ZN2nn6socket6SocketENS0_6FamilyENS0_4TypeENS0_8ProtocolE", sk_fail},
        {"_ZN2nn6socket4BindEiPK8sockaddrj", sk_fail},
        {"_ZN2nn6socket4BindEiPKNS0_8SockAddrEj", sk_fail},
        {"_ZN2nn6socket7ConnectEiPK8sockaddrj", sk_fail},
        {"_ZN2nn6socket7ConnectEiPKNS0_8SockAddrEj", sk_fail},
        {"_ZN2nn6socket6ListenEii", sk_fail},
        {"_ZN2nn6socket6AcceptEiP8sockaddrPj", sk_fail},
        {"_ZN2nn6socket6AcceptEiPNS0_8SockAddrEPj", sk_fail},
        {"_ZN2nn6socket5CloseEi", sk_fail},
        {"_ZN2nn6socket8ShutdownEii", sk_fail},
        {"_ZN2nn6socket11GetPeerNameEiPNS0_8SockAddrEPj", sk_fail},
        {"_ZN2nn6socket11GetSockNameEiP8sockaddrPj", sk_fail},
        {"_ZN2nn6socket11GetSockNameEiPNS0_8SockAddrEPj", sk_fail},
        {"_ZN2nn6socket10GetSockOptEiiiPvPj", sk_fail},
        {"_ZN2nn6socket10GetSockOptEiNS0_5LevelENS0_6OptionEPvPj", sk_fail},
        {"_ZN2nn6socket10SetSockOptEiiiPKvj", sk_fail},
        {"_ZN2nn6socket10SetSockOptEiNS0_5LevelENS0_6OptionEPKvj", sk_fail},
        {"_ZN2nn6socket5FcntlEiiz", sk_fail},
        {"_ZN2nn6socket5FcntlEiNS0_12FcntlCommandEz", sk_fail},
        {"_ZN2nn6socket4PollEP6pollfdmi", sk_fail},
        {"_ZN2nn6socket4PollEPNS0_6PollFdEmi", sk_fail},
        {"_ZN2nn6socket6SelectEiPNS0_5FdSetES2_S2_PNS0_7TimeValE", sk_fail},
        {"_ZN2nn6socket4RecvEiPvmi", sk_fail_l},
        {"_ZN2nn6socket4RecvEiPvmNS0_7MsgFlagE", sk_fail_l},
        {"_ZN2nn6socket4SendEiPKvmi", sk_fail_l},
        {"_ZN2nn6socket4SendEiPKvmNS0_7MsgFlagE", sk_fail_l},
        {"_ZN2nn6socket6SendToEiPKvmiPK8sockaddrj", sk_fail_l},
        {"_ZN2nn6socket6SendToEiPKvmNS0_7MsgFlagEPKNS0_8SockAddrEj", sk_fail_l},
        {"_ZN2nn6socket8RecvFromEiPvmiP8sockaddrPj", sk_fail_l},
        {"_ZN2nn6socket8RecvFromEiPvmNS0_7MsgFlagEPNS0_8SockAddrEPj", sk_fail_l},
        {"_ZN2nn6socket11GetAddrInfoEPKcS2_PK8addrinfoPPS3_", sk_gai},
        {"_ZN2nn6socket11GetAddrInfoEPKcS2_PKNS0_8AddrInfoEPPS3_", sk_gai},
        {"_ZN2nn6socket12FreeAddrInfoEP8addrinfo", nop},
        {"_ZN2nn6socket12FreeAddrInfoEPNS0_8AddrInfoE", nop},
        {"_ZN2nn6socket11GAIStrErrorENS0_7AiErrnoE", sk_gai_str},
        {"_ZN2nn6socket16GetHostEntByNameEPKcPKNS0_14ResolverOptionEm", sk_null_host},
        {"nnsocketSocket", sk_fail},
        {"nnsocketBind", sk_fail},
        {"nnsocketConnect", sk_fail},
        {"nnsocketListen", sk_fail},
        {"nnsocketAccept", sk_fail},
        {"nnsocketClose", sk_fail},
        {"nnsocketShutdown", sk_fail},
        {"nnsocketGetPeerName", sk_fail},
        {"nnsocketGetSockName", sk_fail},
        {"nnsocketGetSockOpt", sk_fail},
        {"nnsocketSetSockOpt", sk_fail},
        {"nnsocketFcntl", sk_fail},
        {"nnsocketPoll", sk_fail},
        {"nnsocketResolverGetOption", sk_fail},
        {"nnsocketResolverSetOption", sk_fail},
        {"nnsocketRecv", sk_fail_l},
        {"nnsocketSend", sk_fail_l},
        {"nnsocketRecvMsg", sk_fail},
        {"nnsocketSendMsg", sk_fail},
        {"nnsocketGetHostByNameWithOptions", sk_null_host},
        {"nnsocketGetAddrInfo", sk_gai},
        {"nnsocketFreeAddrInfo", nop},
        {"nnsocketGAIStrError", sk_gai_str},
        {"nnsocketGetLastErrno", sk_errno},
        {"nnsocketSetLastErrno", sk_set_errno},

        /* nn::ssl & nnssl* */
        {"_ZN2nn3ssl10InitializeEv", ok}, {"_ZN2nn3ssl8FinalizeEv", ok},
        {"nnsslInitialize", ok}, {"nnsslFinalize", ok},
        {"_ZN2nn3ssl7Context6CreateENS1_10SslVersionE", ssl_unavailable},
        {"_ZN2nn3ssl7Context7DestroyEv", ssl_unavailable},
        {"_ZN2nn3ssl7Context15ImportClientPkiEPmPKcS4_jj", ssl_import_pki},
        {"_ZN2nn3ssl7Context15ImportServerPkiEPmPKcjNS0_17CertificateFormatE", ssl_import_pki},
        {"_ZN2nn3ssl7Context9ImportCrlEPmPKcj", ssl_import_pki},
        {"_ZN2nn3ssl7Context19RegisterInternalPkiEPmNS1_11InternalPkiE", ssl_import_pki},
        {"_ZN2nn3ssl7Context9RemovePkiEm", ssl_unavailable},
        {"_ZN2nn3ssl14BuiltInManager22GetBuiltInCertificatesEPPNS0_26BuiltInCertificateInfoBaseEPhjPNS0_15CaCertificateIdEj", out_ptr_null_fail},
        {"_ZN2nn3ssl14BuiltInManager22GetBuiltInCertificatesEPPNS1_22BuiltInCertificateInfoEPhjPNS0_15CaCertificateIdEj", out_ptr_null_fail},
        {"_ZN2nn3ssl14BuiltInManager28GetBuiltInCertificateBufSizeEPjPNS0_15CaCertificateIdEj", out_zero_fail},
        {"nnsslConnectionCreate", ssl_unavailable}, {"nnsslConnectionDestroy", ssl_unavailable},
        {"nnsslConnectionDoHandshakeWithCertBuffer", ssl_unavailable}, {"nnsslConnectionGetConnectionId", ssl_unavailable},
        {"nnsslConnectionGetNextAlpnProto", ssl_unavailable}, {"nnsslConnectionGetVerifyCertError", ssl_unavailable},
        {"nnsslConnectionPeek", ssl_unavailable}, {"nnsslConnectionPending", ssl_unavailable}, {"nnsslConnectionRead", ssl_unavailable},
        {"nnsslConnectionSetHostName", ssl_unavailable}, {"nnsslConnectionSetIoMode", ssl_unavailable},
        {"nnsslConnectionSetNextAlpnProto", ssl_unavailable}, {"nnsslConnectionSetOption", ssl_unavailable},
        {"nnsslConnectionSetSessionCacheMode", ssl_unavailable}, {"nnsslConnectionSetSocketDescriptor", ssl_unavailable},
        {"nnsslConnectionSetVerifyOption", ssl_unavailable}, {"nnsslConnectionWrite", ssl_unavailable},
        {"nnsslContextDestroy", ssl_unavailable}, {"nnsslContextGetContextId", ssl_unavailable},

        /* nn::account online & async stubs */
        {"_ZN2nn7account36EnsureNetworkServiceAccountAvailableERKNS0_10UserHandleE", nsa_unavailable},
        {"_ZN2nn7account32IsNetworkServiceAccountAvailableEPbRKNS0_10UserHandleE", out_bool_false_ok},
        {"_ZN2nn7account26GetNetworkServiceAccountIdEPNS0_23NetworkServiceAccountIdERKNS0_10UserHandleE", nsa_unavailable},
        {"_ZN2nn7account37LoadNetworkServiceAccountIdTokenCacheEPmPcmRKNS0_10UserHandleE", out_u64_zero_fail},
        {"_ZN2nn7account44EnsureNetworkServiceAccountIdTokenCacheAsyncEPNS0_12AsyncContextERKNS0_10UserHandleE", nsa_unavailable},
        {"_ZN2nn7account40ShowLicenseRequirementsForNetworkServiceERKNS0_10UserHandleE", nsa_unavailable},
        {"_ZN2nn7account29LoadCachedNintendoAccountInfoEPNS0_25CachedNintendoAccountInfoERKNS0_10UserHandleEPvm", nsa_unavailable},
        {"_ZN2nn7account16LoadProfileImageEPmPvmRKNS0_3UidE", out_u64_zero_fail},
        {"_ZN2nn7account12AsyncContextC1Ev", nop},
        {"_ZN2nn7account12AsyncContextC1EOS1_", nop},
        {"_ZN2nn7account12AsyncContextD1Ev", nop},
        {"_ZN2nn7account12AsyncContextaSEOS1_", move_self},
        {"_ZN2nn7account12AsyncContext6CancelEv", ok},
        {"_ZN2nn7account12AsyncContext7HasDoneEPb", has_done_true},
        {"_ZN2nn7account12AsyncContext14GetSystemEventEPNS_2os11SystemEventE", signal_event_arg2},
        {"_ZN2nn7account12AsyncContext9GetResultEv", nsa_unavailable},
        {"_ZN2nn7account13PushOpenUsersEv", push_open_users},
        {"_ZN2nn7account12PopOpenUsersEPiPNS0_10UserHandleEi", pop_open_users},

        /* nn::friends */
        {"_ZN2nn7friends10InitializeEv", nop},
        {"_ZN2nn7friends12SetAllocatorEPFPvmEPFvS1_mE", nop},
        {"_ZN2nn7friends12AsyncContextC1Ev", nop},
        {"_ZN2nn7friends12AsyncContextD1Ev", nop},
        {"_ZN2nn7friends12AsyncContext14GetSystemEventEPNS_2os11SystemEventE", signal_event_arg2},
        {"_ZN2nn7friends12AsyncContext7HasDoneEPb", has_done_true},
        {"_ZNK2nn7friends12AsyncContext9GetResultEv", fail},
        {"_ZN2nn7friends13GetFriendListEPiPNS0_6FriendEiiRKNS0_12FriendFilterE", out_zero_fail},
        {"_ZN2nn7friends13GetFriendListEPiPNS0_6FriendERKNS_7account3UidEiiRKNS0_12FriendFilterE", out_zero_fail},
        {"_ZN2nn7friends18GetBlockedUserListEPiPNS_7account23NetworkServiceAccountIdERKNS2_3UidEii", fr_blocked_list},
        {"_ZN2nn7friends27CheckFriendListAvailabilityEPbRKNS_7account3UidE", out_bool_false_ok},
        {"_ZN2nn7friends25EnsureFriendListAvailableEPNS0_12AsyncContextERKNS_7account3UidE", fail},
        {"_ZN2nn7friends14GetProfileListEPNS0_12AsyncContextEPNS0_7ProfileERKNS_7account3UidEPKNS5_23NetworkServiceAccountIdEi", fail},
        {"_ZN2nn7friends16UpdateFriendInfoEPNS0_6FriendERKNS_7account3UidEPKNS3_23NetworkServiceAccountIdEi", fail},
        {"_ZN2nn7friends14AddPlayHistoryERKNS0_26PlayHistoryRegistrationKeyERKNS0_15InAppScreenNameES6_", fail},
        {"_ZN2nn7friends14AddPlayHistoryERKNS_7account3UidERKNS0_26PlayHistoryRegistrationKeyERKNS0_15InAppScreenNameESA_", fail},
        {"_ZN2nn7friends29GetPlayHistoryRegistrationKeyEPNS0_26PlayHistoryRegistrationKeyERKNS_7account3UidEb", fail},
        {"_ZN2nn7friends17NotificationQueueC1Ev", nop},
        {"_ZN2nn7friends17NotificationQueueD1Ev", nop},
        {"_ZN2nn7friends17NotificationQueue10InitializeERKNS_7account3UidE", fail},
        {"_ZN2nn7friends17NotificationQueue8FinalizeEv", nop},
        {"_ZN2nn7friends17NotificationQueue14GetSystemEventEv", quiet_notify_ev},
        {"_ZN2nn7friends17NotificationQueue3PopEPNS0_16NotificationInfoE", fail},
        {"_ZN2nn7friends36GetFriendInvitationNotificationEventEv", quiet_invite_ev},
        {"_ZN2nn7friends38TryPopFriendInvitationNotificationInfoEPNS_7account3UidEPmPvm", ok},
        {"_ZN2nn7friends21StartFriendInvitationERKNS_7account3UidEiRKNS0_35FriendInvitationGameModeDescriptionEPKvm", fail},
        {"_ZN2nn7friends28StartSendingFriendInvitationERKNS_7account3UidEPKNS1_23NetworkServiceAccountIdEiRKNS0_35FriendInvitationGameModeDescriptionEPKvm", fail},
        {"_ZN2nn7friends18ShowUserDetailInfoERKNS_7account3UidERKNS1_23NetworkServiceAccountIdERKNS0_15InAppScreenNameESA_", fail},
        {"_ZN2nn7friends14ShowFriendListERKNS_7account3UidE", fail},
        {"_ZN2nn7friends19ShowBlockedUserListERKNS_7account3UidE", fail},
        {"_ZN2nn7friends29ShowReceivedFriendRequestListERKNS_7account3UidE", fail},
        {"_ZN2nn7friends33ShowMethodsOfSendingFriendRequestERKNS_7account3UidE", fail},
        {"_ZN2nn7friends12UserPresence10InitializeERKNS_7account3UidE", ok},
        {"_ZN2nn7friends12UserPresence14SetDescriptionEPKc", ok},
        {"_ZN2nn7friends12UserPresence6CommitEv", ok},

        /* nn::ngc::ProfanityFilter */
        {"_ZN2nn3ngc15ProfanityFilterC1Ev", h_ngc_Ctor},
        {"_ZN2nn3ngc15ProfanityFilterD1Ev", ngc_v_none},
        {"_ZN2nn3ngc15ProfanityFilterD0Ev", ngc_v_none},
        {"_ZN2nn3ngc15ProfanityFilter8FinalizeEv", ngc_v_none},
        {"_ZN2nn3ngc15ProfanityFilter10InitializeEPvm", ok},
        {"_ZN2nn3ngc15ProfanityFilter10InitializeEPvmb", ok},
        {"_ZN2nn3ngc15ProfanityFilter17GetContentVersionEv", ok},
        {"_ZN2nn3ngc15ProfanityFilter11SetMaskModeENS1_8MaskModeE", nop},
        {"_ZN2nn3ngc15ProfanityFilter15SkipAtSignCheckENS1_8SkipModeE", nop},
        {"_ZN2nn3ngc15ProfanityFilter19CheckProfanityWordsEPjjPPKcm", ngc_v_check},
        {"_ZN2nn3ngc15ProfanityFilter19CheckProfanityWordsEPjjPPKDsm", ngc_v_check},
        {"_ZN2nn3ngc15ProfanityFilter19CheckProfanityWordsEPjjPPKtm", ngc_v_check},
        {"_ZN2nn3ngc15ProfanityFilter24MaskProfanityWordsInTextEPiPcj", ngc_v_mask},
        {"_ZN2nn3ngc15ProfanityFilter24MaskProfanityWordsInTextEPiPDsj", ngc_v_mask},
        {"_ZN2nn3ngc15ProfanityFilter24MaskProfanityWordsInTextEPiPtj", ngc_v_mask},

        /* nn::pctl */
        {"_ZN2nn4pctl27CheckStereoVisionPermissionEb", ret_true},
        {"_ZN2nn4pctl32CheckFreeCommunicationPermissionEb", ret_true},
        {"_ZN2nn4pctl25TryBeginFreeCommunicationEb", ret_false},
        {"_ZN2nn4pctl20EndFreeCommunicationEv", nop},
        {"_ZN2nn4pctl28IsFreeCommunicationAvailableEv", ret_false},
        {"_ZN2nn4pctl26GetStereoVisionRestrictionEv", ret_false},
        {"_ZN2nn4pctl26SetStereoVisionRestrictionEb", nop},
        {"_ZN2nn4pctl42ConfirmStereoVisionRestrictionConfigurableEv", ok},
        {"_ZN2nn4pctl53RequestStereoVisionRestrictionConfigurationPermissionEv", ok},

        /* nn::ec / nn::web / nn::aoc / nn::pdm */
        {"_ZN2nn3aoc31GetAddOnContentListChangedEventEPNS_2os11SystemEventE", bind_event_arg},
        {"_ZN2nn3aoc25ShowAddOnContentLostErrorEPKii", nop},
        {"_ZN2nn2ec24ShowShopAddOnContentListEv", nop},
        {"_ZN2nn2ec24ShowShopAddOnContentListENS_13ApplicationIdE", nop},
        {"_ZN2nn2ec24ShowShopAddOnContentListENS_13ApplicationIdERKNS_7account10UserHandleE", nop},
        {"_ZN2nn2ec24ShowShopAddOnContentListERKNS_7account10UserHandleE", nop},
        {"_ZN2nn2ec22ShowShopProductDetailsENS0_5NsUidE", nop},
        {"_ZN2nn2ec22ShowShopProductDetailsENS0_5NsUidERKNS_7account10UserHandleE", nop},
        {"_ZN2nn2ec19ShowShopProductListEPKNS0_5NsUidEiPKc", nop},
        {"_ZN2nn2ec19ShowShopProductListEPKNS0_5NsUidEiPKcRKNS_7account10UserHandleE", nop},
        {"_ZN2nn2ec33InitializeForShopServiceAccessorsEPvm", ok},
        {"_ZN2nn2ec31FinalizeForShopServiceAccessorsEv", ok},
        {"_ZN2nn2ec19ShopServiceAccessorC1Ev", nop},
        {"_ZN2nn2ec19ShopServiceAccessorD1Ev", nop},
        {"_ZN2nn2ec19ShopServiceAccessor10InitializeERKNS0_11ShopServiceE", fail},
        {"_ZN2nn2ec19ShopServiceAccessor7RequestEPNS1_13AsyncResponseERKNS_7account3UidENS0_11ShopService6MethodEPKcRKNS1_8PostDataENS_8TimeSpanE", fail},
        {"_ZN2nn2ec19ShopServiceAccessor13AsyncResponseC1Ev", nop},
        {"_ZN2nn2ec19ShopServiceAccessor13AsyncResponseD1Ev", nop},
        {"_ZN2nn2ec19ShopServiceAccessor13AsyncResponse7GetSizeEPm", out_u64_zero_fail},
        {"_ZN2nn2ec19ShopServiceAccessor13AsyncResponse3GetEPvm", fail},
        {"_ZN2nn2ec19ShopServiceAccessor13AsyncResponse7TryWaitEv", ret_true},
        {"_ZN2nn3web11ShowWebPageEPNS0_18WebPageReturnValueERKNS0_14ShowWebPageArgE", fail},
        {"_ZN2nn3web13ShowLobbyPageEPNS0_20LobbyPageReturnValueERKNS0_16ShowLobbyPageArgE", fail},
        {"_ZN2nn3web19ShowOfflineHtmlPageEPNS0_26OfflineHtmlPageReturnValueERKNS0_22ShowOfflineHtmlPageArgE", fail},
        {"_ZN2nn3web16ShowYouTubeVideoEPNS0_18WebPageReturnValueERKNS0_19ShowYouTubeVideoArgE", fail},
        {"_ZN2nn3pdm30QueryApplicationPlayStatisticsEPNS0_25ApplicationPlayStatisticsEPKNS_13ApplicationIdEi", pdm_play_stats},

        /* nn::settings / nn::time / nn::err / nn::prepo */
        {"_ZN2nn8settingseqERKNS0_8LanguageERKNS0_12LanguageCodeE", set_lang_eq},
        {"_ZN2nn8settingseqERKNS0_12LanguageCodeERKNS0_8LanguageE", set_lang_eq2},
        {"_ZN2nn8settings12LanguageCode4MakeENS0_8LanguageE", set_lang_make},
        {"_ZN2nn4time26StandardNetworkSystemClock3nowEv", network_clock_now},
        {"_ZN2nn3err21ReportMultimediaErrorENS_6ResultERKN5movie25MultimediaTelemetryReportE", nop},
        {"_ZN2nn5prepo10InitializeEv", ok},
    };
    for (size_t i = 0; i < sizeof entries / sizeof *entries; i++) if (!strcmp(name, entries[i].name)) return entries[i].fn;
    return NULL;
}

__attribute__((constructor)) static void register_system_services(void) {
    setenv("DM_POOL_BUFFER_MAX_MIB", "2048", 0);
    setenv("DM_PRESENT_HZ", "60", 0);
    setenv("TOTK_UNCAPPED", "0", 0);
    setenv("DM_PRESERVE_INVARIANCE", "1", 0);
    setenv("DM_NVN_GPU_CODE_MAX_MINOR", "31", 0);
    setenv("TOTK_GPU_ALLOW_SUBMIT", "1", 0);
    setenv("TOTK_GPU_WIDEN", "1", 0);
    setenv("TOTK_GPU_BLOCKRT", "1", 0);
    setenv("TOTK_GPU_MIDCLEAR", "1", 0);
    runtime_ipc_register("set", settings_handler, NULL, NULL);
    runtime_ipc_register("bsd:u", bsd_handler, NULL, NULL);
}

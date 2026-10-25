/* The Mac controller's haptics and motion sensors for the game's HD rumble and six-axis sensor (runtime/hid_feedback.c),
   2026-10-17. On by default (TOTK_RUMBLE=0 / TOTK_GYRO=0 turn them off), and only on macOS (iOS: stubs, never on).
   Rumble: each of the game's two vibration devices (left, right) is a Core Haptics engine on that handle of the
   controller (GCHapticsLocalityLeftHandle / RightHandle; a DualSense has both) playing a long continuous event. The
   game's value (two bands, each an amplitude 0..1 at a frequency) sets the event's intensity (TOTK_RUMBLE_GAIN, default 1,
   times the bands' combined amplitude) and sharpness (the bands' amplitude-weighted frequency, 40..1250 Hz on a log scale).
   The game sends values every few milliseconds from its own threads; those only store the latest one, and a timer on our
   own queue applies it 100 times a second. The player stops after 150 ms of silence, and the value counts as silence once
   the game has sent nothing for 250 ms (paused, frozen, window lost focus), so the controller never keeps buzzing alone.
   Motion: each GCMotion sample (a DualSense: 250 a second; acceleration in G with gravity, rotation rate in rad/s) goes
   to runtime/motion_fusion.c, which turns it into the Switch's six-axis states. The DualSense was checked lying on the
   desk 2026-10-17: acceleration (0.00, +0.15, -0.95) G, rotation under 0.004 rad/s, 751 samples in 3 s. */
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#include <TargetConditionals.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "runtime.h"

#if !TARGET_OS_OSX
void runtime_feedback_attach(GCController *c, int slot) { (void)c; (void)slot; }
void runtime_feedback_detach(GCController *c) { (void)c; }
void runtime_feedback_quiet(void) {}
void runtime_rumble_set(unsigned slot, unsigned side, float al, float fl, float ah, float fh) { (void)slot; (void)side; (void)al; (void)fl; (void)ah; (void)fh; }
#else
#import <CoreHaptics/CoreHaptics.h>

/* ---- rumble ----
   Simple pattern players (CHHapticPatternPlayer) only: on macOS 26.5.2 (25F84) the advanced player (looping) never gets
   created on a game controller -- gamecontrollerd throws while decoding the pattern ("value for key 'NS.objects' was of
   unexpected class 'AVHapticEvent'"), the client gets NSXPCConnection error 4097 and the engine is dead (later calls
   -4810). Simple players and AHAP data play fine there (2026-10-17, DualSense, intensity 0). So each handle plays one
   30-second continuous event whose intensity and sharpness follow the game through dynamic parameters, and a fresh
   player takes over after 25 s. */
enum { RUMBLE_TICK_MS = 10, RUMBLE_STALE_MS = 250, RUMBLE_HOLD_MS = 150, RUMBLE_EVENT_S = 30, RUMBLE_RENEW_MS = 25000 };
static dispatch_queue_t rumbleQueue;
static dispatch_source_t rumbleTimer;
/* Every player's controller rumbles on its own: channel = player slot * 2 + side (0 left, 1 right handle). */
enum { RUMBLE_CH = 2 * RUNTIME_GAMEPAD_SLOTS };
static GCController *rumblePads[RUNTIME_GAMEPAD_SLOTS];   /* rumbleQueue: the controller of each player slot */
static CHHapticEngine *engines[RUMBLE_CH];                  /* rumbleQueue */
static id<CHHapticPatternPlayer> players[RUMBLE_CH];        /* rumbleQueue */
static CHHapticPattern *pattern;                    /* rumbleQueue: one continuous event, full intensity, middle sharpness */
static BOOL playing[RUMBLE_CH];
static float sentIntensity[RUMBLE_CH], sentSharpness[RUMBLE_CH];
static uint64_t quietSince[RUMBLE_CH], retryAt[RUMBLE_CH], playedNs[RUMBLE_CH], playingSince[RUMBLE_CH], playerSince[RUMBLE_CH];
static pthread_mutex_t wantLock = PTHREAD_MUTEX_INITIALIZER;
static float want[RUMBLE_CH][4];
static uint64_t wantAt[RUMBLE_CH], wantCount, wantCountLogged;
static float strongest;
static float gain = 1.0f;

void runtime_rumble_set(unsigned slot, unsigned hand, float al, float fl, float ah, float fh) {
    if (slot >= RUNTIME_GAMEPAD_SLOTS || hand > 1) return;
    unsigned side = slot * 2 + hand;
    pthread_mutex_lock(&wantLock);
    want[side][0] = al; want[side][1] = fl; want[side][2] = ah; want[side][3] = fh; wantAt[side] = runtime_now_ns(); wantCount++;
    float a = al > ah ? al : ah; if (a > strongest) strongest = a;
    pthread_mutex_unlock(&wantLock);
}
void runtime_feedback_quiet(void) {
    pthread_mutex_lock(&wantLock); memset(wantAt, 0, sizeof wantAt); pthread_mutex_unlock(&wantLock);
}
static float intensity_of(const float v[4]) {
    float a = sqrtf(v[0] * v[0] + v[2] * v[2]) * gain;
    return a > 0 ? (a < 1 ? a : 1) : 0;
}
static float sharpness_of(const float v[4]) {
    float w = v[0] + v[2]; if (w <= 1e-4f) return 0.5f;
    float f = (v[0] * v[1] + v[2] * v[3]) / w; f = f < 40 ? 40 : f > 1250 ? 1250 : f;
    return log2f(f / 40.f) / log2f(1250.f / 40.f);
}
static void forget_side(int side) {   /* rumbleQueue: the engine stopped or was reset; build it again on the next value */
    players[side] = nil; engines[side] = nil; playing[side] = NO; sentIntensity[side] = sentSharpness[side] = -1;
}
static void rumble_failed(int side, const char *what, NSError *err) {
    fprintf(stderr, "[rumble] player %d %s handle: %s failed: %s (trying again in 5 s)\n", side / 2 + 1, side & 1 ? "right" : "left", what,
            err ? err.localizedDescription.UTF8String : "no reason given");
    forget_side(side); retryAt[side] = runtime_now_ns() + 5000000000ull;
}
static BOOL ensure_engine(int side) {   /* rumbleQueue */
    if (engines[side]) return YES;
    GCController *pad = rumblePads[side / 2];
    if (!pad.haptics || runtime_now_ns() < retryAt[side]) return NO;
    NSError *err = nil;
    if (!pattern) {
        CHHapticEventParameter *intensity = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:1.0f];
        CHHapticEventParameter *sharpness = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.5f];
        CHHapticEvent *event = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous parameters:@[intensity, sharpness]
                                                          relativeTime:0 duration:RUMBLE_EVENT_S];
        pattern = [[CHHapticPattern alloc] initWithEvents:@[event] parameters:@[] error:&err];
        if (!pattern) { rumble_failed(side, "building the pattern", err); return NO; }
    }
    GCHapticsLocality where = side & 1 ? GCHapticsLocalityRightHandle : GCHapticsLocalityLeftHandle;
    if (![pad.haptics.supportedLocalities containsObject:where]) where = GCHapticsLocalityDefault;   /* a pad with one motor */
    CHHapticEngine *e = [pad.haptics createEngineWithLocality:where];
    if (!e) { rumble_failed(side, "creating the haptic engine", nil); return NO; }
    e.resetHandler = ^{ dispatch_async(rumbleQueue, ^{ forget_side(side); }); };
    e.stoppedHandler = ^(CHHapticEngineStoppedReason reason) { (void)reason; dispatch_async(rumbleQueue, ^{ forget_side(side); }); };
    if (![e startAndReturnError:&err]) { rumble_failed(side, "starting the haptic engine", err); return NO; }
    engines[side] = e;
    return YES;
}
static BOOL send_params(id<CHHapticPatternPlayer> p, int side, float intensity, float sharpness) {   /* rumbleQueue */
    NSError *err = nil;
    CHHapticDynamicParameter *i = [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:intensity relativeTime:0];
    CHHapticDynamicParameter *s = [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticSharpnessControl value:sharpness - 0.5f relativeTime:0];
    if (![p sendParameters:@[i, s] atTime:CHHapticTimeImmediate error:&err]) { rumble_failed(side, "updating the player", err); return NO; }
    sentIntensity[side] = intensity; sentSharpness[side] = sharpness;
    return YES;
}
/* A new player already at the value (set before it starts, so it never starts at full strength); replaces the old one. */
static BOOL start_player(int side, float intensity, float sharpness, uint64_t now) {   /* rumbleQueue */
    NSError *err = nil;
    id<CHHapticPatternPlayer> p = [engines[side] createPlayerWithPattern:pattern error:&err];
    if (!p) { rumble_failed(side, "creating the player", err); return NO; }
    if (!send_params(p, side, intensity, sharpness)) return NO;
    if (![p startAtTime:CHHapticTimeImmediate error:&err]) { rumble_failed(side, "starting the player", err); return NO; }
    if (players[side]) [players[side] stopAtTime:CHHapticTimeImmediate error:nil];
    players[side] = p; playerSince[side] = now;
    if (!playing[side]) { playing[side] = YES; playingSince[side] = now; }
    return YES;
}
static void rumble_tick(void) {   /* rumbleQueue, every 10 ms */
    uint64_t now = runtime_now_ns();
    for (int side = 0; side < RUMBLE_CH; side++) {
        float v[4]; uint64_t at;
        pthread_mutex_lock(&wantLock); memcpy(v, want[side], sizeof v); at = wantAt[side]; pthread_mutex_unlock(&wantLock);
        float intensity = at && now - at < RUMBLE_STALE_MS * 1000000ull ? intensity_of(v) : 0, sharpness = sharpness_of(v);
        if (intensity < 0.02f) {
            if (!playing[side]) continue;
            if (sentIntensity[side] != 0 && !send_params(players[side], side, 0, sharpness)) continue;
            if (!quietSince[side]) quietSince[side] = now;
            else if (now - quietSince[side] > RUMBLE_HOLD_MS * 1000000ull) {
                [players[side] stopAtTime:CHHapticTimeImmediate error:nil]; players[side] = nil;
                playing[side] = NO; playedNs[side] += now - playingSince[side];
            }
            continue;
        }
        quietSince[side] = 0;
        if (!ensure_engine(side)) continue;
        if (!playing[side] || now - playerSince[side] > RUMBLE_RENEW_MS * 1000000ull) start_player(side, intensity, sharpness, now);
        else if (fabsf(intensity - sentIntensity[side]) > 0.01f || fabsf(sharpness - sentSharpness[side]) > 0.02f) send_params(players[side], side, intensity, sharpness);
    }
    static uint64_t lastLog; if (!lastLog) lastLog = now;
    if (now - lastLog >= 30000000000ull) {
        pthread_mutex_lock(&wantLock); uint64_t n = wantCount - wantCountLogged; float peak = strongest; wantCountLogged = wantCount; strongest = 0; pthread_mutex_unlock(&wantLock);
        for (int side = 0; side < RUMBLE_CH; side++) if (playing[side]) { playedNs[side] += now - playingSince[side]; playingSince[side] = now; }
        if (n) {
            char per[256]; size_t o = 0; per[0] = 0;
            for (int slot = 0; slot < RUNTIME_GAMEPAD_SLOTS && o < sizeof per - 48; slot++)
                if (rumblePads[slot] || playedNs[slot * 2] || playedNs[slot * 2 + 1])
                    o += (size_t)snprintf(per + o, sizeof per - o, ", player %d %.1f s / %.1f s%s", slot + 1, playedNs[slot * 2] / 1e9,
                                          playedNs[slot * 2 + 1] / 1e9, rumblePads[slot].haptics ? "" : " (no haptics)");
            fprintf(stderr, "[rumble] last 30 s: %llu values from the game, strongest amplitude %.2f, played left / right%s\n",
                    (unsigned long long)n, peak, o ? per : ": no controller");
        }
        memset(playedNs, 0, sizeof playedNs); lastLog = now;
    }
}
static void rumble_start(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *g = getenv("TOTK_RUMBLE_GAIN");
        if (g) { char *end; double v = strtod(g, &end); if (end == g || *end || !(v > 0) || v > 4) runtime_fail("TOTK_RUMBLE_GAIN must be a number in (0, 4]"); gain = (float)v; }
        rumbleQueue = dispatch_queue_create("totk.rumble", DISPATCH_QUEUE_SERIAL);
        rumbleTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, rumbleQueue);   /* kept for the life of the process */
        dispatch_source_set_timer(rumbleTimer, dispatch_time(DISPATCH_TIME_NOW, 0), RUMBLE_TICK_MS * NSEC_PER_MSEC, 2 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(rumbleTimer, ^{ @autoreleasepool { rumble_tick(); } });
        dispatch_resume(rumbleTimer);
    });
}

/* ---- motion: the math is in runtime/motion_fusion.c ---- */
static GCController *motionPad;  /* main queue */
static void hid_motion_start(void);
static void hid_motion_stop(void);
static uint64_t zeroSince;          /* the controller's handler queue */
static BOOL motionSeen, hidAsked;   /* the controller's handler queue; reset on attach */
static void motion_sample(GCMotion *m) {   /* the controller's handler queue */
    GCAcceleration a = m.acceleration;
    if (m.hasGravityAndUserAcceleration) { a.x = m.gravity.x + m.userAcceleration.x; a.y = m.gravity.y + m.userAcceleration.y; a.z = m.gravity.z + m.userAcceleration.z; }
    const double acc[3] = {a.x, a.y, a.z}, gyro[3] = {m.rotationRate.x, m.rotationRate.y, m.rotationRate.z};
    if (!motionSeen) {   /* a real sensor never reads exactly zero on all six axes; see hid_motion_start */
        if (!acc[0] && !acc[1] && !acc[2] && !gyro[0] && !gyro[1] && !gyro[2]) {
            uint64_t now = runtime_now_ns();
            if (!zeroSince) zeroSince = now;
            else if (!hidAsked && now - zeroSince > 1000000000ull) { hidAsked = YES; dispatch_async(dispatch_get_main_queue(), ^{ hid_motion_start(); }); }
            return;
        }
        motionSeen = YES;
    }
    runtime_motion_feed(acc, gyro, runtime_now_ns());
}

/* ---- motion straight from a Switch Pro Controller's HID reports (2026-10-19) ----
   An 8BitDo controller in Switch mode (057e:2009 "Pro Controller" over Bluetooth) gets a GCMotion with hasRotationRate,
   and GameController delivers its samples (33 a second) -- but every one is exactly zero, moved or not, while the same
   controller's raw 0x30 reports carry live six-axis data (gyro up to 550 deg/s, about 1 G at rest) and its SPI factory
   calibration at 0x6020 is valid. So once GameController's motion has been all zeros for a second, it is read from the
   HID reports instead, as SDL does for emulators. Input report 0x30 holds three samples, oldest first, int16 little
   endian from byte 13: acceleration x, y, z, then rotation x, y, z, on the raw axes x toward the top edge, y to the
   left, z out of the face, acceleration as the push against gravity (lying face up z = +1 G). Scales from the SPI
   calibration (the user calibration at 0x8026 when it has its 0xB2A1 magic, else the factory one at 0x6020), as SDL:
   G = raw * 4 / (sensitivity - origin), deg/s = (raw - origin) * 936 / (sensitivity - origin); until it arrives the
   sensor's nominal ranges, 8 G and 2000 deg/s over 32768. */
#import <IOKit/hid/IOHIDManager.h>
static IOHIDManagerRef hidManager;   /* main queue */
static IOHIDDeviceRef hidDevice;     /* main queue */
static uint8_t hidReport[64];
static uint8_t hidPacket;
static uint64_t hidLast;
static BOOL hidUserCalibration;
static double hidAccScale[3] = {8.0 / 32768, 8.0 / 32768, 8.0 / 32768}, hidGyroScale[3] = {2000.0 / 32768, 2000.0 / 32768, 2000.0 / 32768}, hidGyroOrigin[3];
static int16_t le16(const uint8_t *p) { return (int16_t)(p[0] | p[1] << 8); }
static void hid_subcommand(uint8_t cmd, const uint8_t *arg, int n) {   /* main queue */
    if (!hidDevice) return;
    uint8_t out[49] = {0x01, hidPacket++ & 15, 0x00, 0x01, 0x40, 0x40, 0x00, 0x01, 0x40, 0x40, cmd};   /* neutral rumble */
    memcpy(out + 11, arg, n);
    IOReturn r = IOHIDDeviceSetReport(hidDevice, kIOHIDReportTypeOutput, 0x01, out, sizeof out);
    if (r != kIOReturnSuccess) fprintf(stderr, "[gyro] HID subcommand 0x%02x failed: 0x%x\n", cmd, r);
}
static void hid_calibration(const uint8_t *c, const char *which) {
    for (int i = 0; i < 3; i++) {
        int acc = le16(c + 6 + 2 * i) - le16(c + 2 * i), gyro = le16(c + 18 + 2 * i) - le16(c + 12 + 2 * i);
        if (acc <= 0 || gyro <= 0) { fprintf(stderr, "[gyro] %s HID calibration unusable: nominal scales kept\n", which); return; }
    }
    for (int i = 0; i < 3; i++) {
        hidAccScale[i] = 4.0 / (le16(c + 6 + 2 * i) - le16(c + 2 * i));
        hidGyroOrigin[i] = le16(c + 12 + 2 * i);
        hidGyroScale[i] = 936.0 / (le16(c + 18 + 2 * i) - hidGyroOrigin[i]);
    }
    fprintf(stderr, "[gyro] %s HID calibration: acc %.6f G, gyro %.4f deg/s per step\n", which, hidAccScale[0], hidGyroScale[0]);
}
static void hid_report(void *ctx, IOReturn result, void *sender, IOHIDReportType type, uint32_t id, uint8_t *p, CFIndex len) {   /* main run loop */
    (void)ctx; (void)sender; (void)type;
    if (result != kIOReturnSuccess || len < 49) return;
    if (id == 0x21 && (p[13] & 0x80) && p[14] == 0x10) {   /* an SPI read's reply: address at 15, size at 19, data at 20 */
        uint32_t at = p[15] | p[16] << 8 | p[17] << 16 | (uint32_t)p[18] << 24;
        if (at == 0x8026 && p[19] >= 26 && p[20] == 0xB2 && p[21] == 0xA1) { hidUserCalibration = YES; hid_calibration(p + 22, "user"); }
        else if (at == 0x6020 && p[19] >= 24 && !hidUserCalibration) hid_calibration(p + 20, "factory");
        return;
    }
    if (id != 0x30) return;
    uint64_t now = runtime_now_ns(), step = hidLast && now - hidLast < 50000000ull ? (now - hidLast) / 3 : 5000000ull;
    hidLast = now;
    for (int k = 0; k < 3; k++) {
        const uint8_t *s = p + 13 + 12 * k;
        double raw[6];
        for (int i = 0; i < 6; i++) raw[i] = le16(s + 2 * i);
        for (int i = 0; i < 3; i++) { raw[i] *= hidAccScale[i]; raw[3 + i] = (raw[3 + i] - hidGyroOrigin[i]) * hidGyroScale[i] * (M_PI / 180); }
        /* to GCMotion's frame (x right, y top edge, z out of the face; acceleration as gravity: face up z = -1 G) */
        const double acc[3] = {raw[1], -raw[0], -raw[2]}, gyro[3] = {-raw[4], raw[3], raw[5]};
        runtime_motion_feed(acc, gyro, now - (uint64_t)(2 - k) * step);
    }
}
static void hid_motion_start(void) {   /* main queue */
    if (!motionPad || hidDevice) return;
    const char *name = (motionPad.vendorName ?: @"controller").UTF8String;
    hidManager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    IOHIDManagerSetDeviceMatching(hidManager, (__bridge CFDictionaryRef)@{@kIOHIDVendorIDKey: @0x057e, @kIOHIDProductIDKey: @0x2009});
    NSSet *devices = (__bridge_transfer NSSet *)IOHIDManagerCopyDevices(hidManager);
    IOHIDDeviceRef d = (__bridge IOHIDDeviceRef)devices.anyObject;
    IOReturn r = d ? IOHIDDeviceOpen(d, kIOHIDOptionsTypeNone) : kIOReturnNotFound;
    if (r != kIOReturnSuccess) {
        fprintf(stderr, "[gyro] %s: GameController's motion is all zeros and no Switch Pro HID device could be opened (0x%x): no motion from it\n", name, r);
        CFRelease(hidManager); hidManager = NULL; return;
    }
    hidDevice = (IOHIDDeviceRef)CFRetain(d); hidLast = 0; hidUserCalibration = NO;
    motionPad.motion.valueChangedHandler = nil;   /* sensors stay active: GameController keeps the IMU reporting */
    IOHIDDeviceScheduleWithRunLoop(hidDevice, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    IOHIDDeviceRegisterInputReportCallback(hidDevice, hidReport, sizeof hidReport, hid_report, NULL);
    runtime_motion_deadzone_default(1.2); runtime_motion_live(1);
    fprintf(stderr, "[gyro] %s: GameController's motion is all zeros; reading the six-axis sensor from its HID reports\n", name);
    /* IMU on, then the calibrations; spaced out, as the controller drops subcommands sent back to back */
    static const uint8_t imuOn[1] = {0x01}, factory[5] = {0x20, 0x60, 0, 0, 24}, user[5] = {0x26, 0x80, 0, 0, 26};
    hid_subcommand(0x40, imuOn, sizeof imuOn);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ hid_subcommand(0x10, factory, sizeof factory); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ hid_subcommand(0x10, user, sizeof user); });
}
static void hid_motion_stop(void) {   /* main queue */
    if (!hidDevice) return;
    IOHIDDeviceRegisterInputReportCallback(hidDevice, hidReport, sizeof hidReport, NULL, NULL);
    IOHIDDeviceUnscheduleFromRunLoop(hidDevice, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    IOHIDDeviceClose(hidDevice, kIOHIDOptionsTypeNone);
    CFRelease(hidDevice); hidDevice = NULL;
    CFRelease(hidManager); hidManager = NULL;
}

/* ---- controllers ---- */
void runtime_feedback_attach(GCController *c, int slot) {   /* main queue; slot: the player it is */
    const char *name = (c.vendorName ?: @"controller").UTF8String;
    if (runtime_rumble_enabled()) {
        rumble_start();
        if (c.haptics) {
            dispatch_async(rumbleQueue, ^{ for (int s = slot * 2; s < slot * 2 + 2; s++) { if (players[s]) [players[s] stopAtTime:CHHapticTimeImmediate error:nil]; forget_side(s); retryAt[s] = 0; } rumblePads[slot] = c; });
            NSMutableArray *where = [NSMutableArray array]; for (NSString *l in c.haptics.supportedLocalities) [where addObject:l];
            fprintf(stderr, "[rumble] %s: haptics for player %d (%s)\n", name, slot + 1, [where componentsJoinedByString:@", "].UTF8String);
        } else fprintf(stderr, "[rumble] %s has no haptics: no rumble from it\n", name);
    }
    /* The game has one six-axis sensor stream here: player 1's controller. */
    if (runtime_gyro_enabled() && slot == 0) {
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            const char *axes = getenv("TOTK_GYRO_AXES"); int r = runtime_motion_axes(axes);
            if (r < 0) runtime_fail("TOTK_GYRO_AXES must name x, y and z once each, e.g. \"-x,y,-z\"");
            if (r > 0) fprintf(stderr, "[gyro] axes remapped by TOTK_GYRO_AXES=%s\n", axes);
        });
        GCMotion *m = c.motion;
        if (!m || !m.hasRotationRate) { fprintf(stderr, "[gyro] %s has no gyro: no motion from it\n", name); return; }
        if (m.sensorsRequireManualActivation) m.sensorsActive = YES;
        hid_motion_stop(); zeroSince = 0; motionSeen = hidAsked = NO; runtime_motion_deadzone_default(0);
        m.valueChangedHandler = ^(GCMotion *changed) { motion_sample(changed); };
        motionPad = c; runtime_motion_live(1);
        fprintf(stderr, "[gyro] %s: motion sensors on (gyro%s)\n", name, m.hasGravityAndUserAcceleration ? ", gravity" : ", acceleration");
    }
}
void runtime_feedback_detach(GCController *c) {   /* main queue */
    if (runtime_rumble_enabled() && rumbleQueue)
        dispatch_async(rumbleQueue, ^{
            for (int slot = 0; slot < RUNTIME_GAMEPAD_SLOTS; slot++) if (rumblePads[slot] == c) {
                for (int s = slot * 2; s < slot * 2 + 2; s++) { if (players[s]) [players[s] stopAtTime:CHHapticTimeImmediate error:nil]; forget_side(s); }
                rumblePads[slot] = nil;
            }
        });
    if (motionPad == c) {
        c.motion.valueChangedHandler = nil; hid_motion_stop(); motionPad = nil; runtime_motion_live(0);
    }
}
#endif

/* Native macOS controllers feed the same FullKey state as the keyboard. */
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include "runtime.h"
#include "gamepad_layout.h"   // face buttons by position (PlayStation, Xbox) or label (Nintendo)
#include "controller_map.h"   // the player's button layout (controls.txt)

static pthread_mutex_t gamepadLock = PTHREAD_MUTEX_INITIALIZER;
static BOOL started;
static uint16_t controllerMap[CONTROLLER_BUTTONS];
static uint8_t controllerModes[CONTROLLER_BUTTONS];
/* Each controller is its own player: slot s is Npad id s (player s + 1), the lowest free slot when it connects, and
   keeps it until it goes away. SSBU_MERGE_PADS=1: every controller is slot 0, OR-ed together (one player). */
typedef struct {
    RuntimeGamepadState state;
    uint64_t pressedEdges;
    uint64_t physicalPrev;
    uint64_t tapUntil[CONTROLLER_BUTTONS];   /* ns, for tap */
    int toggleOn[CONTROLLER_BUTTONS];        /* for toggle */
    int toggleMoved[CONTROLLER_BUTTONS];     /* the stick moved since the toggle went on */
    int mute;                                /* the controller screen closed: nothing for the game until all is let go */
} PadSlot;
static PadSlot slots[RUNTIME_GAMEPAD_SLOTS];             /* gamepadLock */
static __weak GCController *slotOwner[RUNTIME_GAMEPAD_SLOTS];   /* written on the main queue */
/* Who had each slot last and when it left: a controller that drops out (sleep, battery, Bluetooth) comes back as the
   same player, and for two minutes a different new controller does not take that player's place. */
static char slotLast[RUNTIME_GAMEPAD_SLOTS][128];        /* main queue */
static uint64_t slotLeftAt[RUNTIME_GAMEPAD_SLOTS];       /* main queue, ns */
/* Controller events arrive on their own queue, not the main thread: window resizing, the full-screen animation or a
   manual page there no longer hold back or bunch up the buttons. */
static dispatch_queue_t padQueue;
static int mergePads, backgroundPads;
static _Atomic int screenOpen;   /* the controller screen (pad_screen.m) has the controllers: the game gets nothing */
static void refresh_slot(int slot);

/* The player's button layout (controller_map.h): TOTK_CONTROLS names the file (the launcher: <data>/controls.txt and
   checks it first). No file: the default layout. */
static void load_controller_map(void) {
    controller_map_default(controllerMap, controllerModes);
    const char *path = getenv("TOTK_CONTROLS");
    FILE *f = path && *path ? fopen(path, "rb") : NULL;
    if (!f) { fprintf(stderr, "[ssbu-input] controller layout: default\n"); return; }
    char text[16384]; size_t n = fread(text, 1, sizeof text - 1, f); int whole = feof(f); fclose(f);
    if (!whole) runtime_fail("controller layout file too large");
    text[n] = 0;
    const char *error = NULL; int line = controller_map_parse(text, controllerMap, controllerModes, &error);
    if (line) { fprintf(stderr, "[ssbu-input] %s line %d: %s\n", path, line, error); runtime_fail("controller layout file"); }
    uint16_t defaults[CONTROLLER_BUTTONS]; uint8_t defaultModes[CONTROLLER_BUTTONS]; controller_map_default(defaults, defaultModes);
    int changed = 0; for (int i = 0; i < CONTROLLER_BUTTONS; i++) changed += controllerMap[i] != defaults[i];
    fprintf(stderr, "[ssbu-input] controller layout: %s (%d buttons changed)\n", path, changed);
}

/* A stick as one vector: the dead zone is a circle and the direction is kept (a per-axis dead zone pulled
   near-diagonals onto the axes, and Smash reads the angle), and square-gated controllers that report diagonals past
   the rim are brought back onto the circle. */
static void stick_pair(float x, float y, int32_t *ox, int32_t *oy) {
    const float deadzone = 0.12f;
    float magnitude = sqrtf(x * x + y * y);
    if (!(magnitude > deadzone)) { *ox = *oy = 0; return; }
    float scaled = (magnitude - deadzone) / (1.0f - deadzone);
    if (scaled > 1.0f) scaled = 1.0f;
    float k = scaled / magnitude * 32767.0f;
    *ox = (int32_t)lrintf(x * k); *oy = (int32_t)lrintf(y * k);
}

static int32_t stronger_axis(int32_t a, int32_t b) {
    return abs(b) > abs(a) ? b : a;
}

static int face_by_position(GCController *controller) {
    return gamepad_face_by_position(controller.productCategory.UTF8String, controller.vendorName.UTF8String);
}

/* The physical buttons held, bit i = controller_physical_names[i]; the face buttons by where they sit
   (gamepad_face_positions), so one layout file means the same buttons on every controller. */
static uint64_t gamepad_buttons(GCExtendedGamepad *pad, int by_position) {
    uint64_t buttons = gamepad_face_positions(pad.buttonA.isPressed, pad.buttonB.isPressed, pad.buttonX.isPressed, pad.buttonY.isPressed, by_position);
    if (pad.leftThumbstickButton.isPressed) buttons |= 1ULL << 4;
    if (pad.rightThumbstickButton.isPressed) buttons |= 1ULL << 5;
    if (pad.leftShoulder.isPressed) buttons |= 1ULL << 6;
    if (pad.rightShoulder.isPressed) buttons |= 1ULL << 7;
    if (pad.leftTrigger.isPressed) buttons |= 1ULL << 8;
    if (pad.rightTrigger.isPressed) buttons |= 1ULL << 9;
    if (pad.buttonMenu.isPressed) buttons |= 1ULL << 10;
    if (pad.buttonOptions.isPressed) buttons |= 1ULL << 11;
    if (pad.dpad.left.isPressed) buttons |= 1ULL << 12;
    if (pad.dpad.up.isPressed) buttons |= 1ULL << 13;
    if (pad.dpad.right.isPressed) buttons |= 1ULL << 14;
    if (pad.dpad.down.isPressed) buttons |= 1ULL << 15;
    if ([pad isKindOfClass:GCDualSenseGamepad.class] && ((GCDualSenseGamepad *)pad).touchpadButton.isPressed) buttons |= 1ULL << 16;
    if ([pad isKindOfClass:GCDualShockGamepad.class] && ((GCDualShockGamepad *)pad).touchpadButton.isPressed) buttons |= 1ULL << 16;
    return buttons;
}

static int slot_of(GCController *controller) {
    if (mergePads) return 0;
    for (int i = 0; i < RUNTIME_GAMEPAD_SLOTS; i++) if (slotOwner[i] == controller) return i;
    return -1;
}

static void refresh_slot(int slot) {
    PadSlot *p = &slots[slot];
    RuntimeGamepadState next = {0};
    uint64_t physical = 0;
    for (GCController *controller in GCController.controllers) {
        if (slot_of(controller) != slot) continue;
        GCExtendedGamepad *pad = controller.extendedGamepad;
        GCMicroGamepad *micro = pad ? nil : controller.microGamepad;
        int32_t lx = 0, ly = 0, rx = 0, ry = 0;
        if (pad) {
            physical |= gamepad_buttons(pad, face_by_position(controller));
            stick_pair(pad.leftThumbstick.xAxis.value, pad.leftThumbstick.yAxis.value, &lx, &ly);
            stick_pair(pad.rightThumbstick.xAxis.value, pad.rightThumbstick.yAxis.value, &rx, &ry);
        } else if (micro) {   /* a controller with only a pad and two buttons (a single Joy-Con held sideways, a remote):
            the pad is the stick, its main button A, the other B, its menu button + */
            physical |= (micro.buttonA.isPressed ? 2ULL : 0) | (micro.buttonX.isPressed ? 1ULL : 0) | (micro.buttonMenu.isPressed ? 1ULL << 10 : 0);
            stick_pair(micro.dpad.xAxis.value, micro.dpad.yAxis.value, &lx, &ly);
        } else continue;
        next.connected = 1;
        next.lx = stronger_axis(next.lx, lx); next.ly = stronger_axis(next.ly, ly);
        next.rx = stronger_axis(next.rx, rx); next.ry = stronger_axis(next.ry, ry);
    }
    pthread_mutex_lock(&gamepadLock);   /* the mode state below is also reset by runtime_gamepad_clear */
    if (screenOpen || p->mute) {
        if (!physical) p->mute = 0;
        p->physicalPrev = physical;
        p->state = (RuntimeGamepadState){.connected = next.connected};
        pthread_mutex_unlock(&gamepadLock);
        return;
    }
    /* Modes work on the physical buttons, not on the mapped ones: two physical buttons may share a Switch button
       (X and L3 both running), and a mapped edge would be lost while the other one is held. */
    uint64_t now = runtime_now_ns(), edges = physical & ~p->physicalPrev, synthetic = 0, suppressed = 0;
    int moving = next.lx || next.ly;
    p->physicalPrev = physical;
    for (int i = 0; i < CONTROLLER_BUTTONS; i++) {
        uint64_t bit = 1ULL << i;
        int kind = controller_mode_kind(controllerModes[i]);
        if (kind == CONTROLLER_TAP && (edges & bit)) {
            p->tapUntil[i] = now + 400000000ULL;
            /* Release the pulse even if the controller sends no further event. */
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(400 * NSEC_PER_MSEC)), padQueue, ^{ refresh_slot(slot); });
        }
        if (kind == CONTROLLER_TOGGLE) {
            if (edges & bit) { p->toggleOn[i] = !p->toggleOn[i]; p->toggleMoved[i] = moving; }
            if (p->toggleOn[i] && moving) p->toggleMoved[i] = 1;
            /* A toggle ends when the stick returns to center after moving, or the controller goes away; clicking at rest
               waits for the first move, and attacking while running does not stop it. */
            if (p->toggleOn[i] && ((p->toggleMoved[i] && !moving) || !next.connected)) p->toggleOn[i] = 0;
        }
        if (kind == CONTROLLER_AIM && (physical & bit)) {
            /* Aim: the Switch button is held while drawing, released while the fire button is down (the shot), and its
               fire button does nothing else meanwhile. */
            uint64_t fire = 1ULL << controller_mode_fire(controllerModes[i]);
            suppressed |= fire;
            if (!(physical & fire)) synthetic |= controllerMap[i];
        }
        int active = kind == CONTROLLER_TAP ? now < p->tapUntil[i] : kind == CONTROLLER_TOGGLE ? p->toggleOn[i] : 0;
        if (active) synthetic |= controllerMap[i];
    }
    uint64_t held = physical & ~suppressed;
    for (int i = 0; i < CONTROLLER_BUTTONS; i++) if (controllerModes[i] != CONTROLLER_HOLD) held &= ~(1ULL << i);
    next.buttons |= controller_map_apply(controllerMap, held) | synthetic;
    p->pressedEdges |= next.buttons & ~p->state.buttons;
    p->state = next;
    pthread_mutex_unlock(&gamepadLock);
}

/* The player lights show the slot (GameController numbers four players; slots 4-7 leave the light unset). */
static void show_player(GCController *controller, int slot) {
    controller.playerIndex = slot >= 0 && slot < 4 ? (GCControllerPlayerIndex)(GCControllerPlayerIndex1 + slot) : GCControllerPlayerIndexUnset;
}

static void signature(GCController *controller, char out[128]) {
    snprintf(out, 128, "%s|%s", (controller.vendorName ?: @"").UTF8String, (controller.productCategory ?: @"").UTF8String);
}

/* The slot for a controller that connects: the one it had before, else the lowest free one nobody left within two
   minutes, else the lowest free one. */
static int choose_slot(GCController *controller) {
    char sig[128]; signature(controller, sig);
    uint64_t now = runtime_now_ns(), hold = 120ULL * 1000000000ULL;
    for (int i = 0; i < RUNTIME_GAMEPAD_SLOTS; i++) if (!slotOwner[i] && slotLeftAt[i] && !strcmp(slotLast[i], sig)) return i;
    for (int i = 0; i < RUNTIME_GAMEPAD_SLOTS; i++) if (!slotOwner[i] && (!slotLeftAt[i] || now - slotLeftAt[i] > hold)) return i;
    for (int i = 0; i < RUNTIME_GAMEPAD_SLOTS; i++) if (!slotOwner[i]) return i;
    return -1;
}

/* macOS binds Home (and Share, Options) to its own gestures: Home opens the Game Overlay. The game asks for Home
   (GCSystemGestureStateDisabled) when a controller connects and again whenever its window becomes active, since a
   request made before the app is frontmost (the controllers already connected at start) may not be kept. */
static void claim_home(GCController *controller) {
    GCControllerButtonInput *home = controller.physicalInputProfile.buttons[GCInputButtonHome];
    if (!home) return;
    home.preferredSystemGestureState = GCSystemGestureStateDisabled;
    fprintf(stderr, "[ssbu-input] %s: Home asked for (state %ld, %s)\n", (controller.vendorName ?: @"controller").UTF8String,
            (long)home.preferredSystemGestureState, home.boundToSystemGesture ? "macOS still binds it to a gesture" : "not bound to a gesture");
}
void runtime_pads_claim_home(void) {   /* main queue: the window became active */
    for (GCController *c in GCController.controllers) claim_home(c);
}

static void attach_gamepad(GCController *controller) {   /* main queue */
    GCExtendedGamepad *pad = controller.extendedGamepad;
    GCMicroGamepad *micro = pad ? nil : controller.microGamepad;
    if (!pad && !micro) return;
    int slot = slot_of(controller);
    if (slot < 0 && (slot = choose_slot(controller)) >= 0) { slotOwner[slot] = controller; signature(controller, slotLast[slot]); slotLeftAt[slot] = 0; }
    if (slot < 0) {
        fprintf(stderr, "[ssbu-input] native gamepad ignored, all %d players taken: %s\n", RUNTIME_GAMEPAD_SLOTS,
                (controller.vendorName ?: @"unknown").UTF8String);
        return;
    }
    show_player(controller, slot);
    /* The Home button (8BitDo's heart, the PS and Xbox buttons) opens the controller screen (pad_screen.m): taken from
       macOS, which otherwise keeps it for its own controller overlay. */
    claim_home(controller);
    controller.handlerQueue = padQueue;
    __weak GCController *weak = controller;
    void (^changed)(void) = ^{ GCController *c = weak; int now = c ? slot_of(c) : -1; if (now >= 0) refresh_slot(now); if (c) runtime_pad_screen_input(c); };
    if (pad) pad.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *e) { (void)g; (void)e; changed(); };
    else micro.valueChangedHandler = ^(GCMicroGamepad *g, GCControllerElement *e) { (void)g; (void)e; changed(); };
    fprintf(stderr, "[ssbu-input] native gamepad connected as player %d: %s (%s), face buttons by %s\n", slot + 1,
            (controller.vendorName ?: @"unknown").UTF8String,
            (controller.productCategory ?: @"unknown").UTF8String, micro ? "a pad and two buttons only" : face_by_position(controller) ? "position" : "label");
    runtime_feedback_attach(controller, slot);
    dispatch_async(padQueue, ^{ refresh_slot(slot); });
}

static void detach_gamepad(GCController *controller) {   /* main queue */
    int slot = slot_of(controller);
    fprintf(stderr, "[ssbu-input] native gamepad disconnected (player %d): %s\n", slot + 1,
            (controller.vendorName ?: @"unknown").UTF8String);
    controller.extendedGamepad.valueChangedHandler = nil;
    controller.microGamepad.valueChangedHandler = nil;
    runtime_feedback_detach(controller);
    if (slot < 0) return;
    if (!mergePads) { slotOwner[slot] = nil; slotLeftAt[slot] = runtime_now_ns() | 1; }
    dispatch_async(padQueue, ^{ refresh_slot(slot); });
}

void runtime_gamepad_start(void) {
    if (started) return;
    started = YES;
    mergePads = getenv("SSBU_MERGE_PADS") && atoi(getenv("SSBU_MERGE_PADS"));
    if (mergePads) fprintf(stderr, "[ssbu-input] SSBU_MERGE_PADS: every controller is player 1\n");
    load_controller_map();
    padQueue = dispatch_queue_create("ssbu.gamepad", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
#if TARGET_OS_OSX
    /* Controllers keep playing while another window has the keyboard (the game on a TV, the Mac's own screen in use):
       macOS otherwise sends their events only to the frontmost app. SSBU_BACKGROUND_PADS=0: frontmost only. */
    const char *bg = getenv("SSBU_BACKGROUND_PADS");
    backgroundPads = !(bg && !strcmp(bg, "0"));
    if (@available(macOS 11.3, *)) GCController.shouldMonitorBackgroundEvents = backgroundPads;
    fprintf(stderr, "[ssbu-input] controllers %s\n", backgroundPads ? "also play while another app is in front" : "play only while the game is in front");
#endif
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:GCControllerDidConnectNotification object:nil queue:NSOperationQueue.mainQueue
                   usingBlock:^(NSNotification *notification) { attach_gamepad(notification.object); }];
    [center addObserverForName:GCControllerDidDisconnectNotification object:nil queue:NSOperationQueue.mainQueue
                   usingBlock:^(NSNotification *notification) { detach_gamepad(notification.object); }];
    for (GCController *controller in GCController.controllers) attach_gamepad(controller);
    [GCController startWirelessControllerDiscoveryWithCompletionHandler:nil];
}

/* ---- the controller screen (runtime/pad_screen.m) ---- */
void runtime_pads_hold(int on) {   /* main queue */
    screenOpen = on;
    if (!on) { pthread_mutex_lock(&gamepadLock); for (int s = 0; s < RUNTIME_GAMEPAD_SLOTS; s++) slots[s].mute = 1; pthread_mutex_unlock(&gamepadLock); }
    dispatch_async(padQueue, ^{ for (int s = 0; s < RUNTIME_GAMEPAD_SLOTS; s++) refresh_slot(s); });
}
uint64_t runtime_pads_buttons(GCController *controller) {   /* gamepad queue: the Switch buttons it holds, after the layout */
    GCExtendedGamepad *pad = controller.extendedGamepad;
    GCMicroGamepad *micro = pad ? nil : controller.microGamepad;
    uint64_t physical = pad ? gamepad_buttons(pad, face_by_position(controller))
                      : micro ? (micro.buttonA.isPressed ? 2ULL : 0) | (micro.buttonX.isPressed ? 1ULL : 0) | (micro.buttonMenu.isPressed ? 1ULL << 10 : 0) : 0;
    return controller_map_apply(controllerMap, physical);
}
int runtime_pads_slot_of(GCController *controller) { return slot_of(controller); }   /* main queue */
NSArray<GCController *> *runtime_pads_connected(void) {   /* main queue: by player */
    NSMutableArray *out = [NSMutableArray array];
    for (int i = 0; i < RUNTIME_GAMEPAD_SLOTS; i++) if (slotOwner[i]) [out addObject:slotOwner[i]];
    for (GCController *c in GCController.controllers) if ((c.extendedGamepad || c.microGamepad) && ![out containsObject:c]) [out addObject:c];
    return out;
}
/* The players in the order the screen made: order[i] is player i + 1, the controllers that did not join follow. */
void runtime_pads_reorder(NSArray<GCController *> *order) {   /* main queue */
    if (mergePads) return;
    NSMutableArray<GCController *> *all = [order mutableCopy];
    for (int i = 0; i < RUNTIME_GAMEPAD_SLOTS; i++) if (slotOwner[i] && ![all containsObject:slotOwner[i]]) [all addObject:slotOwner[i]];
    for (GCController *c in all) runtime_feedback_detach(c);
    for (int i = 0; i < RUNTIME_GAMEPAD_SLOTS; i++) slotOwner[i] = nil;
    for (NSUInteger i = 0; i < all.count && i < RUNTIME_GAMEPAD_SLOTS; i++) {
        GCController *c = all[i]; int slot = (int)i;
        slotOwner[slot] = c; signature(c, slotLast[slot]); slotLeftAt[slot] = 0;
        show_player(c, slot); runtime_feedback_attach(c, slot);
        fprintf(stderr, "[ssbu-input] controller screen: player %d is %s\n", slot + 1, (c.vendorName ?: @"unknown").UTF8String);
    }
    dispatch_async(padQueue, ^{ for (int s = 0; s < RUNTIME_GAMEPAD_SLOTS; s++) refresh_slot(s); });
}
void runtime_pads_show_lights(void) {   /* main queue: every controller's lights back to its player */
    for (int i = 0; i < RUNTIME_GAMEPAD_SLOTS; i++) if (slotOwner[i]) show_player(slotOwner[i], i);
}

void runtime_gamepad_clear(void) {
    runtime_feedback_quiet();
    pthread_mutex_lock(&gamepadLock);
    for (int s = 0; s < RUNTIME_GAMEPAD_SLOTS; s++) {
        PadSlot *p = &slots[s];
        p->physicalPrev = 0;
        memset(p->tapUntil, 0, sizeof p->tapUntil);
        memset(p->toggleOn, 0, sizeof p->toggleOn);
        memset(p->toggleMoved, 0, sizeof p->toggleMoved);
        int connected = p->state.connected;
        p->state = (RuntimeGamepadState){.connected = connected};
        p->pressedEdges = 0;
    }
    pthread_mutex_unlock(&gamepadLock);
}

int runtime_gamepad_background(void) { return backgroundPads; }

/* On-screen touch controls (iPhone, ios/app/Sources/touch_controls.m) feed a second state merged with the physical
   controllers: buttons are OR-ed (a tap shorter than one game frame is latched like a controller press), each stick
   axis takes the stronger value. */
static RuntimeGamepadState touchState;
static uint64_t touchEdges;
void runtime_touch_pad_set(const RuntimeGamepadState *s) {
    pthread_mutex_lock(&gamepadLock);
    touchEdges |= s->buttons & ~touchState.buttons;
    touchState = *s;
    pthread_mutex_unlock(&gamepadLock);
}

/* Slot 0 (player 1) also carries the touch controls. */
void runtime_gamepad_read_slot(int slot, RuntimeGamepadState *out) {
    if (slot < 0 || slot >= RUNTIME_GAMEPAD_SLOTS) { *out = (RuntimeGamepadState){0}; return; }
    pthread_mutex_lock(&gamepadLock);
    PadSlot *p = &slots[slot];
    *out = p->state;
    out->buttons |= p->pressedEdges;
    p->pressedEdges = 0;
    if (slot == 0) {
        out->buttons |= touchState.buttons | touchEdges;
        out->lx = stronger_axis(out->lx, touchState.lx); out->ly = stronger_axis(out->ly, touchState.ly);
        out->rx = stronger_axis(out->rx, touchState.rx); out->ry = stronger_axis(out->ry, touchState.ry);
        if (touchState.connected) out->connected = 1;
        touchEdges = 0;
    }
    pthread_mutex_unlock(&gamepadLock);
}

void runtime_gamepad_read(RuntimeGamepadState *out) { runtime_gamepad_read_slot(0, out); }

uint32_t runtime_gamepad_connected_mask(void) {
    uint32_t mask = 0;
    pthread_mutex_lock(&gamepadLock);
    for (int s = 0; s < RUNTIME_GAMEPAD_SLOTS; s++) if (slots[s].state.connected) mask |= 1u << s;
    if (touchState.connected) mask |= 1;
    pthread_mutex_unlock(&gamepadLock);
    return mask;
}

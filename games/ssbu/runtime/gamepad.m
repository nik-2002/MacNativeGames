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
} PadSlot;
static PadSlot slots[RUNTIME_GAMEPAD_SLOTS];             /* state: gamepadLock; the mode state: main queue */
static __weak GCController *slotOwner[RUNTIME_GAMEPAD_SLOTS];   /* main queue */
static int mergePads;
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

static int32_t stick_axis(float value) {
    const float deadzone = 0.12f;
    float magnitude = fabsf(value);
    if (magnitude <= deadzone) return 0;
    if (magnitude > 1.0f) magnitude = 1.0f;
    int32_t result = (int32_t)((magnitude - deadzone) / (1.0f - deadzone) * 32767.0f);
    return value < 0 ? -result : result;
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
        GCExtendedGamepad *pad = controller.extendedGamepad;
        if (!pad || slot_of(controller) != slot) continue;
        next.connected = 1;
        physical |= gamepad_buttons(pad, face_by_position(controller));
        next.lx = stronger_axis(next.lx, stick_axis(pad.leftThumbstick.xAxis.value));
        next.ly = stronger_axis(next.ly, stick_axis(pad.leftThumbstick.yAxis.value));
        next.rx = stronger_axis(next.rx, stick_axis(pad.rightThumbstick.xAxis.value));
        next.ry = stronger_axis(next.ry, stick_axis(pad.rightThumbstick.yAxis.value));
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
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(400 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{ refresh_slot(slot); });
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
    pthread_mutex_lock(&gamepadLock);
    p->pressedEdges |= next.buttons & ~p->state.buttons;
    p->state = next;
    pthread_mutex_unlock(&gamepadLock);
}

/* The player lights show the slot (GameController numbers four players; slots 4-7 leave the light unset). */
static void show_player(GCController *controller, int slot) {
    controller.playerIndex = slot >= 0 && slot < 4 ? (GCControllerPlayerIndex)(GCControllerPlayerIndex1 + slot) : GCControllerPlayerIndexUnset;
}

static void attach_gamepad(GCController *controller) {
    GCExtendedGamepad *pad = controller.extendedGamepad;
    if (!pad) return;
    int slot = slot_of(controller);
    if (slot < 0) for (int i = 0; i < RUNTIME_GAMEPAD_SLOTS && slot < 0; i++) if (!slotOwner[i]) { slotOwner[i] = controller; slot = i; }
    if (slot < 0) {
        fprintf(stderr, "[ssbu-input] native gamepad ignored, all %d players taken: %s\n", RUNTIME_GAMEPAD_SLOTS,
                (controller.vendorName ?: @"unknown").UTF8String);
        return;
    }
    show_player(controller, slot);
    pad.valueChangedHandler = ^(GCExtendedGamepad *changed, GCControllerElement *element) {
        (void)changed; (void)element;
        int now = slot_of(controller);
        if (now >= 0) refresh_slot(now);
    };
    fprintf(stderr, "[ssbu-input] native gamepad connected as player %d: %s (%s), face buttons by %s\n", slot + 1,
            (controller.vendorName ?: @"unknown").UTF8String,
            (controller.productCategory ?: @"unknown").UTF8String, face_by_position(controller) ? "position" : "label");
    runtime_feedback_attach(controller);
    refresh_slot(slot);
}

static void detach_gamepad(GCController *controller) {
    int slot = slot_of(controller);
    fprintf(stderr, "[ssbu-input] native gamepad disconnected (player %d): %s\n", slot + 1,
            (controller.vendorName ?: @"unknown").UTF8String);
    controller.extendedGamepad.valueChangedHandler = nil;
    runtime_feedback_detach(controller);
    if (slot < 0) return;
    if (!mergePads) slotOwner[slot] = nil;
    refresh_slot(slot);
}

void runtime_gamepad_start(void) {
    if (started) return;
    started = YES;
    mergePads = getenv("SSBU_MERGE_PADS") && atoi(getenv("SSBU_MERGE_PADS"));
    if (mergePads) fprintf(stderr, "[ssbu-input] SSBU_MERGE_PADS: every controller is player 1\n");
    load_controller_map();
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:GCControllerDidConnectNotification object:nil queue:NSOperationQueue.mainQueue
                   usingBlock:^(NSNotification *notification) { attach_gamepad(notification.object); }];
    [center addObserverForName:GCControllerDidDisconnectNotification object:nil queue:NSOperationQueue.mainQueue
                   usingBlock:^(NSNotification *notification) { detach_gamepad(notification.object); }];
    for (GCController *controller in GCController.controllers) attach_gamepad(controller);
    [GCController startWirelessControllerDiscoveryWithCompletionHandler:nil];
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

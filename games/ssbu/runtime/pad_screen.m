/* The controller screen: the Switch's Change Grip/Order over the game. Each controller that presses L + R (or ZL + ZR;
   a single Joy-Con held sideways: its two buttons together) takes the next player, its lights show which, A on a joined
   controller is done, B leaves (B with nobody joined cancels). Return is done and Esc cancels on the keyboard, which stays
   with player 1. The game opens it through nn::hid::ShowControllerSupport and waits for it, as on the console; ⌘K or
   holding − and + on a controller for a second opens it any time. Done gives the players in the order they joined,
   the controllers that did not join after them; cancel leaves the players as they were. */
#import <Cocoa/Cocoa.h>
#import <GameController/GameController.h>
#include <stdio.h>
#include <pthread.h>
#include <stdlib.h>
#include "runtime.h"
#include "totk_ui_lang.h"

void *runtime_front_content_view(void);   /* frontend.m */
uint64_t runtime_pads_buttons(GCController *controller);   /* gamepad.m: the Switch buttons it holds */

enum { B_A = 1 << 0, B_B = 1 << 1, B_L = 1 << 6, B_R = 1 << 7, B_ZL = 1 << 8, B_ZR = 1 << 9, B_PLUS = 1 << 10, B_MINUS = 1 << 11 };

/* Smash's player colours, P1-P8. */
static NSColor *player_color(int i) {
    static const uint32_t rgb[8] = {0xe8383d, 0x3d7cf0, 0xf2c522, 0x35b04a, 0xf28a1e, 0x2ec4d6, 0xf06aa8, 0x8c5ad8};
    uint32_t c = rgb[i & 7];
    return [NSColor colorWithSRGBRed:(c >> 16 & 255) / 255.0 green:(c >> 8 & 255) / 255.0 blue:(c & 255) / 255.0 alpha:1];
}
/* The Switch's player lights, bit 0 the leftmost lamp (input.c led_pattern). */
static const uint8_t lamps[8] = {0x1, 0x3, 0x7, 0xf, 0x9, 0x5, 0xd, 0x6};

@interface SSBUPadScreen : NSView
@property(strong) NSMutableArray<GCController *> *joined;
@property int minPlayers, maxPlayers;
@end

static SSBUPadScreen *screen;
static id keyMonitor;
static NSMapTable<GCController *, NSNumber *> *held;     /* main queue: each controller's buttons last seen */
static NSMutableArray<dispatch_semaphore_t> *waiting;    /* the game's ShowControllerSupport calls */
static int result;                                        /* players after the screen closed */

@implementation SSBUPadScreen
- (BOOL)isFlipped { return YES; }
- (NSView *)hitTest:(NSPoint)p { (void)p; return self; }
- (void)mouseDown:(NSEvent *)e { (void)e; }
static void text(NSString *s, CGFloat size, NSFontWeight weight, NSColor *color, NSRect r, NSTextAlignment align) {
    NSMutableParagraphStyle *p = [NSMutableParagraphStyle new]; p.alignment = align; p.lineBreakMode = NSLineBreakByTruncatingTail;
    [s drawInRect:r withAttributes:@{NSFontAttributeName: [NSFont systemFontOfSize:size weight:weight], NSForegroundColorAttributeName: color, NSParagraphStyleAttributeName: p}];
}
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSRect b = self.bounds; CGFloat W = b.size.width, H = b.size.height, u = fmin(W / 1280, H / 720);
    [[NSColor colorWithCalibratedRed:0.06 green:0.065 blue:0.075 alpha:0.94] setFill]; NSRectFill(b);

    text(@(TOTK_UI("在手柄上按 L + R", "Press L + R on the controller")), 34 * u, NSFontWeightBold, NSColor.whiteColor, NSMakeRect(0, H * 0.13, W, 48 * u), NSTextAlignmentCenter);
    text(@(TOTK_UI("横握单只 Joy-Con：同时按下它的两个按键", "A single Joy-Con held sideways: press its two buttons together")), 15 * u, NSFontWeightRegular,
         [NSColor colorWithCalibratedWhite:0.68 alpha:1], NSMakeRect(0, H * 0.13 + 52 * u, W, 24 * u), NSTextAlignmentCenter);

    int n = self.maxPlayers; if (n < (int)self.joined.count) n = (int)self.joined.count;
    CGFloat gap = 16 * u, cw = fmin(190 * u, (W - 120 * u - gap * (n - 1)) / n), ch = cw * 1.32;
    CGFloat x0 = (W - (cw * n + gap * (n - 1))) / 2, y0 = H * 0.30 + (H * 0.42 - ch) / 2;
    for (int i = 0; i < n; i++) {
        NSRect card = NSMakeRect(x0 + i * (cw + gap), y0, cw, ch);
        GCController *c = i < (int)self.joined.count ? self.joined[i] : nil;
        NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:card xRadius:12 * u yRadius:12 * u];
        if (!c) {
            [[NSColor colorWithCalibratedWhite:1 alpha:0.04] setFill]; [shape fill];
            CGFloat dash[2] = {7 * u, 6 * u}; [shape setLineDash:dash count:2 phase:0]; shape.lineWidth = 2 * u;
            [[NSColor colorWithCalibratedWhite:1 alpha:0.22] setStroke]; [shape stroke];
            text([NSString stringWithFormat:@"P%d", i + 1], 22 * u, NSFontWeightBold, [NSColor colorWithCalibratedWhite:1 alpha:0.25],
                 NSMakeRect(card.origin.x, NSMidY(card) - 16 * u, cw, 32 * u), NSTextAlignmentCenter);
            continue;
        }
        NSColor *pc = player_color(i);
        [[NSColor colorWithCalibratedWhite:0.16 alpha:1] setFill]; [shape fill];
        shape.lineWidth = 3 * u; [pc setStroke]; [shape stroke];
        text([NSString stringWithFormat:@"P%d", i + 1], 30 * u, NSFontWeightHeavy, pc, NSMakeRect(card.origin.x, card.origin.y + 12 * u, cw, 40 * u), NSTextAlignmentCenter);
        NSImage *icon = [NSImage imageWithSystemSymbolName:c.extendedGamepad ? @"gamecontroller.fill" : @"rectangle.portrait.fill" accessibilityDescription:nil];
        if (@available(macOS 12.0, *)) icon = [icon imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[NSColor.whiteColor]]];
        CGFloat is = cw * 0.46; NSSize sz = icon.size; CGFloat k = sz.width > 0 ? fmin(is / sz.width, is / sz.height) : 1;
        NSRect ir = NSMakeRect(NSMidX(card) - sz.width * k / 2, NSMidY(card) - sz.height * k / 2 - 2 * u, sz.width * k, sz.height * k);
        [icon drawInRect:ir fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
        text(c.vendorName ?: @"Controller", 13 * u, NSFontWeightMedium, [NSColor colorWithCalibratedWhite:0.85 alpha:1],
             NSMakeRect(card.origin.x + 8 * u, NSMaxY(card) - 58 * u, cw - 16 * u, 20 * u), NSTextAlignmentCenter);
        CGFloat lw = 14 * u, lh = 5 * u, lg = 6 * u, lx = NSMidX(card) - (4 * lw + 3 * lg) / 2, ly = NSMaxY(card) - 26 * u;
        for (int k2 = 0; k2 < 4; k2++) {
            NSBezierPath *lamp = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(lx + k2 * (lw + lg), ly, lw, lh) xRadius:lh / 2 yRadius:lh / 2];
            [(lamps[i & 7] >> k2 & 1 ? [NSColor colorWithSRGBRed:0.45 green:1 blue:0.35 alpha:1] : [NSColor colorWithCalibratedWhite:1 alpha:0.15]) setFill]; [lamp fill];
        }
    }

    NSUInteger connected = runtime_pads_connected().count;
    NSString *status = connected ? [NSString stringWithFormat:@(TOTK_UI("已连接 %lu 个手柄", "%lu controller(s) connected")), (unsigned long)connected]
                                 : @(TOTK_UI("没有连接手柄：先在 系统设置 › 蓝牙 中配对", "No controllers connected: pair one in System Settings › Bluetooth"));
    text(status, 14 * u, NSFontWeightRegular, [NSColor colorWithCalibratedWhite:0.6 alpha:1], NSMakeRect(40 * u, H - 64 * u, W / 2, 22 * u), NSTextAlignmentLeft);
    BOOL can = (int)self.joined.count >= self.minPlayers;
    NSString *keys = [NSString stringWithFormat:@"%@      %@", @(TOTK_UI("Ⓐ 完成   Ⓑ 退出 / 取消", "Ⓐ Done   Ⓑ Leave / Cancel")), @(TOTK_UI("Return 完成   Esc 取消", "Return Done   Esc Cancel"))];
    text(keys, 15 * u, NSFontWeightMedium, [NSColor colorWithCalibratedWhite:can ? 0.92 : 0.5 alpha:1], NSMakeRect(W / 2, H - 64 * u, W / 2 - 40 * u, 22 * u), NSTextAlignmentRight);
}
@end

static void finish(BOOL done) {   /* main queue */
    if (!screen) return;
    if (done && screen.joined.count) runtime_pads_reorder(screen.joined); else runtime_pads_show_lights();
    fprintf(stderr, "[ssbu-input] controller screen %s: %lu joined\n", done ? "done" : "cancelled", (unsigned long)screen.joined.count);
    if (keyMonitor) { [NSEvent removeMonitor:keyMonitor]; keyMonitor = nil; }
    SSBUPadScreen *s = screen; screen = nil;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) { ctx.duration = 0.15; s.animator.alphaValue = 0; } completionHandler:^{ [s removeFromSuperview]; }];
    runtime_input_clear();
    runtime_pads_hold(0);
    int players = 1; for (GCController *c in runtime_pads_connected()) { int slot = runtime_pads_slot_of(c); if (slot > 0) players++; }
    result = players;
    for (dispatch_semaphore_t w in waiting) dispatch_semaphore_signal(w);
    [waiting removeAllObjects];
}

static void open_screen(int min_players, int max_players) {   /* main queue */
    if (screen) return;
    NSView *content = (__bridge NSView *)runtime_front_content_view();
    if (!content) return;
    if (max_players < 1 || max_players > RUNTIME_GAMEPAD_SLOTS) max_players = RUNTIME_GAMEPAD_SLOTS;
    if (min_players < 0) min_players = 0;
    if (min_players > max_players) min_players = max_players;
    runtime_pads_hold(1);
    runtime_input_clear();
    if (!held) held = [NSMapTable weakToStrongObjectsMapTable];
    for (GCController *c in runtime_pads_connected()) { c.playerIndex = GCControllerPlayerIndexUnset; }
    screen = [[SSBUPadScreen alloc] initWithFrame:content.bounds];
    screen.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    screen.joined = [NSMutableArray array]; screen.minPlayers = min_players; screen.maxPlayers = max_players;
    screen.alphaValue = 0; [content addSubview:screen];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) { ctx.duration = 0.15; screen.animator.alphaValue = 1; } completionHandler:nil];
    keyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown | NSEventMaskKeyUp handler:^NSEvent *(NSEvent *e) {
        if (e.modifierFlags & NSEventModifierFlagCommand) return e;
        if (e.type == NSEventTypeKeyDown && !e.ARepeat) {
            if (e.keyCode == 36 || e.keyCode == 76) finish(YES);
            else if (e.keyCode == 53) finish(NO);
        }
        return nil;
    }];
    fprintf(stderr, "[ssbu-input] controller screen open: %d-%d players, %lu controller(s) connected\n", min_players, max_players, (unsigned long)runtime_pads_connected().count);
}

static void screen_input(GCController *c, uint64_t b) {   /* main queue */
    if (!held) held = [NSMapTable weakToStrongObjectsMapTable];
    uint64_t prev = [held objectForKey:c].unsignedLongLongValue, edge = b & ~prev;
    [held setObject:@(b) forKey:c];
    if (!screen) {
        /* − and + held together for a second open the screen. */
        const uint64_t pm = B_PLUS | B_MINUS;
        if ((b & pm) == pm && (edge & pm)) {
            __weak GCController *weak = c;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                GCController *s = weak; if (s && !screen && ([held objectForKey:s].unsignedLongLongValue & pm) == pm) open_screen(0, RUNTIME_GAMEPAD_SLOTS); });
        }
        return;
    }
    BOOL in = [screen.joined containsObject:c];
    BOOL micro = !c.extendedGamepad;
    BOOL join = ((b & B_L) && (b & B_R) && (edge & (B_L | B_R))) || ((b & B_ZL) && (b & B_ZR) && (edge & (B_ZL | B_ZR)))
             || (micro && (b & B_A) && (b & B_B) && (edge & (B_A | B_B)));
    if (!in && join) {
        if ((int)screen.joined.count >= screen.maxPlayers) return;
        [screen.joined addObject:c];
        int i = (int)screen.joined.count - 1;
        c.playerIndex = i < 4 ? (GCControllerPlayerIndex)(GCControllerPlayerIndex1 + i) : GCControllerPlayerIndexUnset;
        fprintf(stderr, "[ssbu-input] controller screen: %s joined as player %d\n", (c.vendorName ?: @"unknown").UTF8String, i + 1);
        screen.needsDisplay = YES;
        return;
    }
    if (in && (edge & B_A) && !(micro && (b & B_B)) && (int)screen.joined.count >= screen.minPlayers) { finish(YES); return; }
    if (edge & B_B && !(micro && (b & B_A))) {
        if (in) {
            [screen.joined removeObject:c]; c.playerIndex = GCControllerPlayerIndexUnset;
            for (NSUInteger i = 0; i < screen.joined.count; i++) screen.joined[i].playerIndex = i < 4 ? (GCControllerPlayerIndex)(GCControllerPlayerIndex1 + i) : GCControllerPlayerIndexUnset;
            screen.needsDisplay = YES;
        } else if (!screen.joined.count) finish(NO);
    }
}

void runtime_pad_screen_input(GCController *c) {   /* gamepad queue */
    uint64_t b = runtime_pads_buttons(c);
    dispatch_async(dispatch_get_main_queue(), ^{ screen_input(c, b); });
}

void runtime_pad_screen_open(void) { dispatch_async(dispatch_get_main_queue(), ^{ if (screen) finish(NO); else open_screen(0, RUNTIME_GAMEPAD_SLOTS); }); }

/* The game's nn::hid::ShowControllerSupport (a guest thread): the screen, and the players once it closes. With no
   controller connected it returns at once (the keyboard is player 1), as before. SSBU_PAD_SCREEN=0: never shown for it. */
int runtime_pad_screen_run(int min_players, int max_players) {
    const char *e = getenv("SSBU_PAD_SCREEN");
    if ((e && !strcmp(e, "0")) || !runtime_gamepad_connected_mask()) return -1;
    dispatch_semaphore_t w = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!waiting) waiting = [NSMutableArray array];
        [waiting addObject:w];
        open_screen(min_players, max_players);
        if (!screen) { [waiting removeObject:w]; result = -1; dispatch_semaphore_signal(w); }
    });
    dispatch_semaphore_wait(w, DISPATCH_TIME_FOREVER);
    return result;
}

static void *applet_test(void *arg) {
    int *mm = arg; int n = runtime_pad_screen_run(mm[0], mm[1]);
    fprintf(stderr, "[ssbu-input] controller screen test: the game would get %d player(s)\n", n); free(mm); return NULL;
}
void runtime_pad_screen_test(const char *op) {
    int lo, hi;
    if (!strcmp(op, "open")) dispatch_async(dispatch_get_main_queue(), ^{ open_screen(0, RUNTIME_GAMEPAD_SLOTS); });
    else if (!strcmp(op, "done") || !strcmp(op, "cancel")) { BOOL done = op[0] == 'd'; dispatch_async(dispatch_get_main_queue(), ^{ finish(done); }); }
    else if (sscanf(op, "applet %d %d", &lo, &hi) == 2) { int *mm = malloc(2 * sizeof *mm); mm[0] = lo; mm[1] = hi; pthread_t t; pthread_create(&t, NULL, applet_test, mm); pthread_detach(t); }
    else if (!strncmp(op, "press ", 6)) {   /* "pads press <switch button bits>": as if the first controller held them */
        uint64_t bits = strtoull(op + 6, NULL, 0);
        dispatch_async(dispatch_get_main_queue(), ^{ GCController *c = runtime_pads_connected().firstObject; if (c) screen_input(c, bits); });
    }
    else if (!strncmp(op, "shot ", 5)) {   /* "pads shot <path>": the open screen as a PNG */
        NSString *path = @(op + 5);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!screen) { fprintf(stderr, "[ssbu-input] pads shot: the screen is not open\n"); return; }
            NSBitmapImageRep *rep = [screen bitmapImageRepForCachingDisplayInRect:screen.bounds];
            [screen cacheDisplayInRect:screen.bounds toBitmapImageRep:rep];
            [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
        });
    }
    else fprintf(stderr, "[ssbu-input] pads: open, done, cancel, shot <path> or applet <min> <max>\n");
}

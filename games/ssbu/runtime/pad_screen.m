/* The controller screen: the Switch's Change Grip/Order over the game. Each controller that presses L + R (or ZL + ZR;
   a single Joy-Con held sideways: its two buttons together) takes the next player, its lights show which, A on a joined
   controller is done, B leaves (B with nobody joined cancels). Return is done and Esc cancels on the keyboard, which stays
   with player 1. The game opens it through nn::hid::ShowControllerSupport and waits for it, as on the console; ⌘K or
   holding − and + on a controller for a second opens it any time. Done gives the players in the order they joined,
   the controllers that did not join after them; cancel leaves the players as they were. */
#import <Cocoa/Cocoa.h>
#import <GameController/GameController.h>
#import <IOBluetooth/IOBluetooth.h>
#import <CoreBluetooth/CoreBluetooth.h>
#include <stdio.h>
#include <pthread.h>
#include <stdlib.h>
#include "runtime.h"
#include "totk_ui_lang.h"

void *runtime_front_content_view(void);   /* frontend.m */
uint64_t runtime_pads_buttons(GCController *controller);   /* gamepad.m: the Switch buttons it holds */

enum { B_A = 1 << 0, B_B = 1 << 1, B_Y = 1 << 3, B_L = 1 << 6, B_R = 1 << 7, B_ZL = 1 << 8, B_ZR = 1 << 9, B_PLUS = 1 << 10, B_MINUS = 1 << 11 };

/* Smash's player colours, P1-P8. */
static NSColor *player_color(int i) {
    static const uint32_t rgb[8] = {0xe8383d, 0x3d7cf0, 0xf2c522, 0x35b04a, 0xf28a1e, 0x2ec4d6, 0xf06aa8, 0x8c5ad8};
    uint32_t c = rgb[i & 7];
    return [NSColor colorWithSRGBRed:(c >> 16 & 255) / 255.0 green:(c >> 8 & 255) / 255.0 blue:(c & 255) / 255.0 alpha:1];
}
/* The Switch's player lights, bit 0 the leftmost lamp (input.c led_pattern). */
static const uint8_t lamps[8] = {0x1, 0x3, 0x7, 0xf, 0x9, 0x5, 0xd, 0x6};

/* ---- Pair new controller: Bluetooth Classic search and pairing (IOBluetooth) ----
   Switch controllers (Pro Controller, Joy-Con) and PlayStation ones (DualShock 4, DualSense) pair over Bluetooth Classic,
   so a controller held in pairing mode is found, paired and connected without System Settings; GameController then
   reports it as usual. Xbox controllers use Bluetooth LE, which macOS pairs only in System Settings › Bluetooth.
   The search runs until the player says pairing is done (A or Return; B or Esc also stops it), ten minutes at most, so
   several controllers can be paired one after another; anything that looks like a controller is paired at once, as on
   the Switch. Ending the search goes back to the join screen and never closes it. */
typedef NS_ENUM(int, PairState) { PairFound, PairPairing, PairConnecting, PairDone, PairFailed };
@interface SSBUPairRow : NSObject
@property(strong) IOBluetoothDevice *device;
@property PairState state;
@end
@implementation SSBUPairRow
@end
@interface SSBUPairer : NSObject <IOBluetoothDeviceInquiryDelegate, IOBluetoothDevicePairDelegate>
@property(strong) IOBluetoothDeviceInquiry *inquiry;
@property(strong) NSMutableArray<SSBUPairRow *> *rows;
@property(strong) NSMutableArray<IOBluetoothDevicePair *> *pairs;
@property(copy) NSString *problem;
@property BOOL searching;
@property uint64_t until;
@end
static SSBUPairer *pairer;
static void redraw(void);
static BOOL looks_like_controller(IOBluetoothDevice *d) {
    BluetoothClassOfDevice cod = d.classOfDevice;
    unsigned major = cod >> 8 & 0x1f, minor = cod >> 2 & 0x3f;
    if (major == 5 && ((minor & 0xf) == 1 || (minor & 0xf) == 2)) return YES;   /* peripheral: joystick or gamepad */
    NSString *n = d.name.lowercaseString ?: @"";
    for (NSString *k in @[@"pro controller", @"joy-con", @"wireless controller", @"dualsense", @"dualshock", @"controller", @"gamepad"])
        if ([n containsString:k]) return YES;
    return NO;
}
@implementation SSBUPairer
- (void)start {
    self.problem = nil;
    if (@available(macOS 10.15, *)) {
        CBManagerAuthorization a = CBManager.authorization;
        if (a == CBManagerAuthorizationDenied || a == CBManagerAuthorizationRestricted) {
            self.problem = @(TOTK_UI("蓝牙权限已关闭：在 系统设置 › 隐私与安全性 › 蓝牙 中允许本游戏",
                                     "Bluetooth access is off: allow the game in System Settings › Privacy & Security › Bluetooth"));
            redraw(); return;
        }
    }
    if (IOBluetoothHostController.defaultController.powerState != kBluetoothHCIPowerStateON) {
        self.problem = @(TOTK_UI("蓝牙已关闭：在 系统设置 › 蓝牙 中打开", "Bluetooth is off: turn it on in System Settings › Bluetooth"));
        redraw(); return;
    }
    if (!self.rows) self.rows = [NSMutableArray array];
    if (!self.pairs) self.pairs = [NSMutableArray array];
    self.until = runtime_now_ns() + 600ULL * 1000000000ULL;
    [self search];
}
- (void)search {
    if (self.searching) return;
    self.inquiry = [IOBluetoothDeviceInquiry inquiryWithDelegate:self];
    self.inquiry.inquiryLength = 8; self.inquiry.updateNewDeviceNames = YES;
    IOReturn r = [self.inquiry start];
    self.searching = r == kIOReturnSuccess;
    if (!self.searching) self.problem = [NSString stringWithFormat:@(TOTK_UI("无法搜索蓝牙设备（%#x）", "Bluetooth search failed (%#x)")), r];
    fprintf(stderr, "[ssbu-input] pairing: searching for controllers (%#x)\n", r);
    redraw();
}
- (void)stop {
    self.until = 0; [self.inquiry stop]; self.inquiry.delegate = nil; self.inquiry = nil; self.searching = NO;
    for (IOBluetoothDevicePair *p in self.pairs) { [p stop]; p.delegate = nil; }
    [self.pairs removeAllObjects]; [self.rows removeAllObjects]; self.problem = nil;
}
- (SSBUPairRow *)row:(IOBluetoothDevice *)d {
    for (SSBUPairRow *r in self.rows) if ([r.device.addressString isEqualToString:d.addressString]) return r;
    return nil;
}
- (void)consider:(IOBluetoothDevice *)d {
    if (!looks_like_controller(d)) return;
    SSBUPairRow *r = [self row:d];
    if (r) { r.device = d; redraw(); return; }
    if (d.isPaired && d.isConnected) return;
    r = [SSBUPairRow new]; r.device = d; r.state = PairFound; [self.rows addObject:r];
    fprintf(stderr, "[ssbu-input] pairing: found %s (%s), %s\n", (d.name ?: @"?").UTF8String, d.addressString.UTF8String, d.isPaired ? "paired before: connecting" : "pairing");
    if (d.isPaired) [self connect:r];
    else {
        IOBluetoothDevicePair *p = [IOBluetoothDevicePair pairWithDevice:d]; p.delegate = self; [self.pairs addObject:p];
        r.state = PairPairing;
        if ([p start] != kIOReturnSuccess) r.state = PairFailed;
    }
    redraw();
}
- (void)connect:(SSBUPairRow *)r {
    r.state = PairConnecting;
    IOReturn e = [r.device openConnection:self];
    if (e != kIOReturnSuccess) { r.state = PairFailed; fprintf(stderr, "[ssbu-input] pairing: %s did not connect (%#x)\n", (r.device.name ?: @"?").UTF8String, e); }
    redraw();
}
- (void)connectionComplete:(IOBluetoothDevice *)d status:(IOReturn)status {
    SSBUPairRow *r = [self row:d]; if (!r) return;
    r.state = status == kIOReturnSuccess ? PairDone : PairFailed;
    fprintf(stderr, "[ssbu-input] pairing: %s %s (%#x)\n", (d.name ?: @"?").UTF8String, status ? "did not connect" : "connected", status);
    redraw();
}
- (void)deviceInquiryDeviceFound:(IOBluetoothDeviceInquiry *)sender device:(IOBluetoothDevice *)d { (void)sender; [self consider:d]; }
- (void)deviceInquiryDeviceNameUpdated:(IOBluetoothDeviceInquiry *)sender device:(IOBluetoothDevice *)d devicesRemaining:(uint32_t)n { (void)sender; (void)n; [self consider:d]; }
- (void)deviceInquiryComplete:(IOBluetoothDeviceInquiry *)sender error:(IOReturn)error aborted:(BOOL)aborted {
    (void)sender; self.searching = NO;
    if (error) fprintf(stderr, "[ssbu-input] pairing: search ended with %#x\n", error);
    if (!aborted && self.until && runtime_now_ns() < self.until) { [self search]; return; }
    redraw();
}
- (void)devicePairingPINCodeRequest:(id)sender { [sender replyPINCode:4 PINCode:&(BluetoothPINCode){.data = {'0', '0', '0', '0'}}]; }
- (void)devicePairingUserConfirmationRequest:(id)sender numericValue:(BluetoothNumericValue)v { (void)v; [sender replyUserConfirmation:YES]; }
- (void)devicePairingFinished:(id)sender error:(IOReturn)error {
    IOBluetoothDevicePair *p = sender; SSBUPairRow *r = [self row:p.device];
    fprintf(stderr, "[ssbu-input] pairing: %s %s (%#x)\n", (p.device.name ?: @"?").UTF8String, error ? "not paired" : "paired", error);
    [self.pairs removeObject:p];
    if (!r) return;
    if (error) { r.state = PairFailed; redraw(); } else [self connect:r];
}
@end

@interface SSBUPadScreen : NSView
@property(strong) NSMutableArray<GCController *> *joined;
@property int minPlayers, maxPlayers;
@property NSRect pairButton;
@property(copy) NSString *note;   /* after pairing: what was paired */
@end

static SSBUPadScreen *screen;
static id keyMonitor;
static NSMapTable<GCController *, NSNumber *> *held;     /* main queue: each controller's buttons last seen */
static NSMutableArray<dispatch_semaphore_t> *waiting;    /* the game's ShowControllerSupport calls */
static int result;                                        /* players after the screen closed */

@implementation SSBUPadScreen
- (BOOL)isFlipped { return YES; }
- (NSView *)hitTest:(NSPoint)p { (void)p; return self; }
static void pair_toggle(void);
- (void)mouseDown:(NSEvent *)e { if (NSPointInRect([self convertPoint:e.locationInWindow fromView:nil], self.pairButton)) pair_toggle(); }
static void text(NSString *s, CGFloat size, NSFontWeight weight, NSColor *color, NSRect r, NSTextAlignment align) {
    NSMutableParagraphStyle *p = [NSMutableParagraphStyle new]; p.alignment = align; p.lineBreakMode = NSLineBreakByTruncatingTail;
    [s drawInRect:r withAttributes:@{NSFontAttributeName: [NSFont systemFontOfSize:size weight:weight], NSForegroundColorAttributeName: color, NSParagraphStyleAttributeName: p}];
}
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSRect b = self.bounds; CGFloat W = b.size.width, H = b.size.height, u = fmin(W / 1280, H / 720);
    [[NSColor colorWithCalibratedRed:0.06 green:0.065 blue:0.075 alpha:0.94] setFill]; NSRectFill(b);

    text(@(TOTK_UI("在手柄上按 L + R", "Press L + R on the controller")), 34 * u, NSFontWeightBold, NSColor.whiteColor, NSMakeRect(0, H * 0.13, W, 48 * u), NSTextAlignmentCenter);
    text(@(TOTK_UI("PlayStation：L1 + R1　·　Xbox：LB + RB　·　横握单只 Joy-Con：同时按下它的两个按键", "PlayStation: L1 + R1   ·   Xbox: LB + RB   ·   A single Joy-Con held sideways: press its two buttons together")), 15 * u, NSFontWeightRegular,
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

    /* Pairing panel, under the cards. */
    CGFloat py = y0 + ch + 34 * u;
    NSRect button = NSMakeRect(W / 2 - 150 * u, py, 300 * u, 40 * u);
    self.pairButton = button;
    if (!pairer.until && !pairer.problem) {
        if (self.note) text(self.note, 15 * u, NSFontWeightMedium, [NSColor colorWithSRGBRed:0.45 green:1 blue:0.35 alpha:1],
                            NSMakeRect(0, py + 52 * u, W, 22 * u), NSTextAlignmentCenter);
        NSBezierPath *bp = [NSBezierPath bezierPathWithRoundedRect:button xRadius:20 * u yRadius:20 * u];
        [[NSColor colorWithCalibratedWhite:1 alpha:0.1] setFill]; [bp fill];
        [[NSColor colorWithCalibratedWhite:1 alpha:0.3] setStroke]; bp.lineWidth = 1.5 * u; [bp stroke];
        text(@(TOTK_UI("Ⓨ  配对新手柄", "Ⓨ  Pair new controller")), 17 * u, NSFontWeightSemibold, NSColor.whiteColor,
             NSMakeRect(button.origin.x, button.origin.y + 9 * u, button.size.width, 24 * u), NSTextAlignmentCenter);
    } else {
        NSColor *dim = [NSColor colorWithCalibratedWhite:0.7 alpha:1];
        if (pairer.problem) text(pairer.problem, 16 * u, NSFontWeightMedium, [NSColor colorWithSRGBRed:1 green:0.6 blue:0.4 alpha:1], NSMakeRect(0, py, W, 24 * u), NSTextAlignmentCenter);
        else {
            int dots = (int)(runtime_now_ns() / 400000000ULL % 4);
            text([NSString stringWithFormat:@"%@%@", @(TOTK_UI("正在寻找处于配对模式的手柄", "Looking for controllers in pairing mode")), [@"..." substringToIndex:dots]],
                 18 * u, NSFontWeightSemibold, NSColor.whiteColor, NSMakeRect(0, py, W, 26 * u), NSTextAlignmentCenter);
            text(@(TOTK_UI("Switch Pro 手柄 / Joy-Con：按住顶部的小同步键　·　PS4：按住 Share + PS　·　PS5：按住 Create + PS，直到灯光快闪",
                           "Switch Pro Controller / Joy-Con: hold the small sync button   ·   PS4: hold Share + PS   ·   PS5: hold Create + PS, until the light flashes")),
                 14 * u, NSFontWeightRegular, dim, NSMakeRect(0, py + 30 * u, W, 20 * u), NSTextAlignmentCenter);
            text(@(TOTK_UI("Xbox 手柄请在 系统设置 › 蓝牙 中配对", "Xbox controllers pair in System Settings › Bluetooth")),
                 13 * u, NSFontWeightRegular, [NSColor colorWithCalibratedWhite:0.5 alpha:1], NSMakeRect(0, py + 52 * u, W, 20 * u), NSTextAlignmentCenter);
            /* The confirmation: the search goes on until the player says every controller is paired. */
            NSString *ask = @(TOTK_UI("还有手柄要配对就让它进入配对模式；全部配对完成后按 Ⓐ（或 Return）",
                                      "Put any other controller in pairing mode now. When every controller you want is paired, press Ⓐ (or Return)"));
            CGFloat ay = py + 80 * u + 24 * u * pairer.rows.count + 10 * u;
            NSRect box = NSMakeRect(W / 2 - 420 * u, ay, 840 * u, 36 * u);
            NSBezierPath *bp = [NSBezierPath bezierPathWithRoundedRect:box xRadius:18 * u yRadius:18 * u];
            [[NSColor colorWithCalibratedWhite:1 alpha:0.1] setFill]; [bp fill];
            text(ask, 15 * u, NSFontWeightSemibold, NSColor.whiteColor, NSMakeRect(box.origin.x, ay + 8 * u, box.size.width, 22 * u), NSTextAlignmentCenter);
        }
        CGFloat ry = py + 80 * u;
        for (SSBUPairRow *r in pairer.rows) {
            static NSString *const states[] = {@"…", @"pairing…", @"connecting…", @"✓ connected", @"✕ failed: hold the sync button again"};
            NSString *st = states[r.state];
            text([NSString stringWithFormat:@"%@   %@", r.device.name ?: r.device.addressString, st], 15 * u, NSFontWeightMedium,
                 r.state == PairDone ? [NSColor colorWithSRGBRed:0.45 green:1 blue:0.35 alpha:1] : r.state == PairFailed ? [NSColor colorWithSRGBRed:1 green:0.5 blue:0.45 alpha:1] : NSColor.whiteColor,
                 NSMakeRect(0, ry, W, 22 * u), NSTextAlignmentCenter);
            ry += 24 * u;
        }
    }

    NSUInteger connected = runtime_pads_connected().count;
    NSString *status = connected ? [NSString stringWithFormat:@(TOTK_UI("已连接 %lu 个手柄", "%lu controller(s) connected")), (unsigned long)connected]
                                 : @(TOTK_UI("没有连接手柄：先在 系统设置 › 蓝牙 中配对", "No controllers connected: pair one in System Settings › Bluetooth"));
    text(status, 14 * u, NSFontWeightRegular, [NSColor colorWithCalibratedWhite:0.6 alpha:1], NSMakeRect(40 * u, H - 64 * u, W / 2, 22 * u), NSTextAlignmentLeft);
    BOOL can = (int)self.joined.count >= self.minPlayers;
    NSString *keys = pairer.until || pairer.problem
        ? [NSString stringWithFormat:@"%@      %@", @(TOTK_UI("Ⓐ/○ 配对完成   Ⓑ/✕ 停止配对", "Ⓐ/○ Done pairing   Ⓑ/✕ Stop pairing")), @(TOTK_UI("Return 配对完成   Esc 停止", "Return Done pairing   Esc Stop"))]
        : [NSString stringWithFormat:@"%@      %@", @(TOTK_UI("Ⓐ/○ 完成   Ⓑ/✕ 退出 / 取消   Ⓨ/□ 配对", "Ⓐ/○ Done   Ⓑ/✕ Leave / Cancel   Ⓨ/□ Pair")), @(TOTK_UI("Return 完成   Esc 取消   P 配对", "Return Done   Esc Cancel   P Pair"))];
    text(keys, 15 * u, NSFontWeightMedium, [NSColor colorWithCalibratedWhite:can ? 0.92 : 0.5 alpha:1], NSMakeRect(W / 2, H - 64 * u, W / 2 - 40 * u, 22 * u), NSTextAlignmentRight);
}
@end

static NSTimer *ticker;
static void redraw(void) { screen.needsDisplay = YES; }
static BOOL pairing(void) { return pairer.until || pairer.problem; }
static void pair_toggle(void) {   /* main queue */
    if (!screen) return;
    if (!pairer) pairer = [SSBUPairer new];
    if (pairing()) {
        int n = 0; for (SSBUPairRow *r in pairer.rows) n += r.state == PairDone;
        screen.note = n ? [NSString stringWithFormat:@(TOTK_UI("已配对 %d 个手柄：在每个手柄上按 L + R 加入", "%d controller(s) paired: press L + R on each to join")), n] : nil;
        fprintf(stderr, "[ssbu-input] pairing done: %d controller(s) paired\n", n);
        [pairer stop];
    } else { screen.note = nil; [pairer start]; }
    if (pairer.until && !ticker) ticker = [NSTimer scheduledTimerWithTimeInterval:0.4 repeats:YES block:^(NSTimer *t) {
        if (!screen || (!pairer.until && !pairer.searching)) { [t invalidate]; ticker = nil; }
        else if (pairer.until && runtime_now_ns() > pairer.until && !pairer.searching) { pairer.until = 0; }
        redraw(); }];
    redraw();
}

static void finish(BOOL done) {   /* main queue */
    if (!screen) return;
    [pairer stop]; [ticker invalidate]; ticker = nil;
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
            if (pairing() && (e.keyCode == 36 || e.keyCode == 76 || e.keyCode == 53)) pair_toggle();   /* done / stop pairing */
            else if (e.keyCode == 36 || e.keyCode == 76) finish(YES);
            else if (e.keyCode == 53) finish(NO);
            else if (e.keyCode == 35) pair_toggle();   /* P */
        }
        return nil;
    }];
    fprintf(stderr, "[ssbu-input] controller screen open: %d-%d players, %lu controller(s) connected\n", min_players, max_players, (unsigned long)runtime_pads_connected().count);
}

static void screen_input(GCController *c, uint64_t b) {   /* main queue */
    if (!held) held = [NSMapTable weakToStrongObjectsMapTable];
    NSNumber *seen = [held objectForKey:c];
    uint64_t prev = seen.unsignedLongLongValue, edge = seen ? b & ~prev : 0;   /* a controller's first report is no press:
        one that just connected may still hold its pairing buttons (Share + PS, the sync button's neighbours) */
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
    if (pairing()) {   /* A says pairing is done, B stops it: back to the join screen, never closing it */
        if (edge & (B_A | B_B) && !join) pair_toggle();
        return;
    }
    if (!micro && (edge & B_Y)) { pair_toggle(); return; }
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
    else if (!strcmp(op, "pair")) dispatch_async(dispatch_get_main_queue(), ^{ pair_toggle(); });
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

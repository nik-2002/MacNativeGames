// Players (user 2026-10-30: "my sister would like to play also on my laptop ... different save states"). The game has one
// user; each player here is a profile folder of their own (account, saves, playtime: TOTK_PROFILE_DIR), chosen before the
// game starts. Settings, controls, mods and the shader cache stay shared.
//   <data>/players.txt        one line per player: <folder relative to data> TAB <name>; the first is the original
//                             profile/ (its saves never move); missing = that one player alone
//   <data>/player-last.txt    the folder picked last, picked again by default
//   <data>/players/<id>/      a player added here
// The picker shows when there is more than one player, or when Option is held at launch (to add the first). Removing a
// player moves its folder to the Trash; the original player can be renamed, not removed.
#import <AppKit/AppKit.h>

static NSMutableArray<NSArray<NSString *> *> *players_read(NSString *data) {   // @[folder, name] rows, never empty
    NSMutableArray *rows = [NSMutableArray array];
    NSString *text = [NSString stringWithContentsOfFile:[data stringByAppendingPathComponent:@"players.txt"] encoding:NSUTF8StringEncoding error:nil];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        NSArray *f = [line componentsSeparatedByString:@"\t"];
        if (f.count == 2 && [f[0] length] && [f[1] length] && ![f[0] containsString:@".."]) [rows addObject:f];
    }
    if (!rows.count || ![rows[0][0] isEqualToString:@"profile"]) {   // the original profile always comes first
        NSString *first = [NSFullUserName() componentsSeparatedByString:@" "].firstObject;
        [rows insertObject:@[@"profile", first.length ? first : @(TOTK_UI("玩家 1", "Player 1"))] atIndex:0];
    }
    return rows;
}

static BOOL players_write(NSString *data, NSArray<NSArray<NSString *> *> *rows) {
    NSMutableString *text = [NSMutableString string];
    for (NSArray *r in rows) [text appendFormat:@"%@\t%@\n", r[0], r[1]];
    return [text writeToFile:[data stringByAppendingPathComponent:@"players.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static NSString *player_name_ask(NSString *title, NSString *initial, NSArray<NSArray<NSString *> *> *rows, NSString *except) {
    for (NSString *problem = nil;;) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = title;
        alert.informativeText = problem ?: @"";
        NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 240, 24)];
        field.stringValue = initial ?: @"";
        alert.accessoryView = field;
        [alert addButtonWithTitle:@(TOTK_UI("好", "OK"))];
        [alert addButtonWithTitle:@(TOTK_UI("取消", "Cancel"))];
        alert.window.initialFirstResponder = field;
        if ([alert runModal] != NSAlertFirstButtonReturn) return nil;
        NSString *name = [field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        name = [[name componentsSeparatedByCharactersInSet:NSCharacterSet.controlCharacterSet] componentsJoinedByString:@""];
        BOOL taken = NO;
        for (NSArray *r in rows) if (![r[0] isEqualToString:except ?: @""] && [r[1] caseInsensitiveCompare:name] == NSOrderedSame) taken = YES;
        if (!name.length || name.length > 24) problem = @(TOTK_UI("名字要 1 到 24 个字。", "A name is 1 to 24 characters."));
        else if (taken) problem = @(TOTK_UI("已经有这个名字的玩家了。", "There is already a player with that name."));
        else return name;
        initial = field.stringValue;
    }
}

static NSString *player_folder_new(NSString *data, NSString *name) {   // players/<ascii of the name>[-n], not yet used
    NSMutableString *id = [NSMutableString string];
    for (NSUInteger i = 0; i < name.length && id.length < 24; i++) {
        unichar c = [name characterAtIndex:i];
        if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) [id appendFormat:@"%C", c];
        else if (c >= 'A' && c <= 'Z') [id appendFormat:@"%C", (unichar)(c + 32)];
    }
    if (!id.length) [id setString:@"player"];
    NSString *folder = [@"players" stringByAppendingPathComponent:id];
    for (int n = 2; [NSFileManager.defaultManager fileExistsAtPath:[data stringByAppendingPathComponent:folder]]; n++)
        folder = [@"players" stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%d", id, n]];
    return folder;
}

@interface PlayerPicker : NSObject
@property NSString *data;
@property NSMutableArray<NSArray<NSString *> *> *rows;
@property NSPopUpButton *menu;
@property NSButton *removeButton;
@end
@implementation PlayerPicker
- (void)refresh:(NSString *)select {
    [self.menu removeAllItems];
    for (NSArray *r in self.rows) [self.menu addItemWithTitle:r[1]];
    NSUInteger at = 0;
    for (NSUInteger i = 0; i < self.rows.count; i++) if ([self.rows[i][0] isEqualToString:select ?: @""]) at = i;
    [self.menu selectItemAtIndex:(NSInteger)at];
    [self changed:nil];
}
- (void)changed:(id)sender { (void)sender; self.removeButton.enabled = self.menu.indexOfSelectedItem > 0; }   // the original stays
- (void)add:(id)sender {
    (void)sender;
    NSString *name = player_name_ask(@(TOTK_UI("新玩家的名字", "New player's name")), @"", self.rows, nil);
    if (!name) return;
    NSString *folder = player_folder_new(self.data, name);
    if (![NSFileManager.defaultManager createDirectoryAtPath:[self.data stringByAppendingPathComponent:folder] withIntermediateDirectories:YES attributes:nil error:nil]) return;
    [self.rows addObject:@[folder, name]];
    players_write(self.data, self.rows);
    [self refresh:folder];
}
- (void)rename:(id)sender {
    (void)sender;
    NSArray *r = self.rows[(NSUInteger)self.menu.indexOfSelectedItem];
    NSString *name = player_name_ask(@(TOTK_UI("改名", "Rename player")), r[1], self.rows, r[0]);
    if (!name) return;
    self.rows[(NSUInteger)self.menu.indexOfSelectedItem] = @[r[0], name];
    players_write(self.data, self.rows);
    [self refresh:r[0]];
}
- (void)remove:(id)sender {
    (void)sender;
    NSInteger at = self.menu.indexOfSelectedItem;
    if (at <= 0) return;
    NSArray *r = self.rows[(NSUInteger)at];
    NSAlert *alert = [NSAlert new];
    alert.messageText = [NSString stringWithFormat:@(TOTK_UI("删除玩家“%@”？", "Remove the player \"%@\"?")), r[1]];
    alert.informativeText = @(TOTK_UI("这个玩家的存档会移到废纸篓，在那里还能找回来。", "Their saves move to the Trash, where they can still be recovered."));
    [alert addButtonWithTitle:@(TOTK_UI("删除", "Remove"))];
    [alert addButtonWithTitle:@(TOTK_UI("取消", "Cancel"))];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    NSURL *url = [NSURL fileURLWithPath:[self.data stringByAppendingPathComponent:r[0]]];
    NSError *error = nil;
    if ([NSFileManager.defaultManager fileExistsAtPath:url.path] && ![NSFileManager.defaultManager trashItemAtURL:url resultingItemURL:nil error:&error]) {
        NSAlert *failed = [NSAlert new];
        failed.messageText = [@(TOTK_UI("没能移到废纸篓：", "Could not move it to the Trash: ")) stringByAppendingString:error.localizedDescription ?: @""];
        [failed runModal];
        return;
    }
    [self.rows removeObjectAtIndex:(NSUInteger)at];
    players_write(self.data, self.rows);
    [self refresh:self.rows[0][0]];
}
@end

/* The player for this run: the profile folder and its name, *several set when there is more than one player (the window
   title then names the player). Returns NO when the player chose Quit. */
static BOOL players_choose(NSString *data, NSString **profile, NSString **name, BOOL *several) {
    NSMutableArray *rows = players_read(data);
    NSString *last = [[NSString stringWithContentsOfFile:[data stringByAppendingPathComponent:@"player-last.txt"] encoding:NSUTF8StringEncoding error:nil]
                      stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSUInteger pick = 0;
    for (NSUInteger i = 0; i < rows.count; i++) if ([rows[i][0] isEqualToString:last ?: @""]) pick = i;
    BOOL option = (NSEvent.modifierFlags & NSEventModifierFlagOption) != 0;
    if (rows.count > 1 || option) {
        [NSApplication sharedApplication]; [NSApp activateIgnoringOtherApps:YES];
        PlayerPicker *picker = [PlayerPicker new];
        picker.data = data; picker.rows = rows;
        NSView *box = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 64)];
        picker.menu = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 36, 300, 26) pullsDown:NO];
        picker.menu.target = picker; picker.menu.action = @selector(changed:);
        [box addSubview:picker.menu];
        NSArray *buttons = @[@[@(TOTK_UI("新玩家…", "New Player…")), @"add:"], @[@(TOTK_UI("改名…", "Rename…")), @"rename:"], @[@(TOTK_UI("删除…", "Remove…")), @"remove:"]];
        for (NSUInteger i = 0; i < buttons.count; i++) {
            NSButton *b = [NSButton buttonWithTitle:buttons[i][0] target:picker action:NSSelectorFromString(buttons[i][1])];
            b.frame = NSMakeRect(i * 100, 0, 98, 28); b.controlSize = NSControlSizeSmall;
            [box addSubview:b];
            if (i == 2) picker.removeButton = b;
        }
        [picker refresh:rows[pick][0]];
        NSAlert *alert = [NSAlert new];
        alert.messageText = @(TOTK_UI("谁在玩？", "Who's playing?"));
        alert.informativeText = @(TOTK_UI("每个玩家有自己的存档。设置是大家共用的。启动时按住 ⌥ Option 可以随时打开这里。",
                                          "Each player has their own saves; settings are shared. Hold ⌥ Option at launch to come back here any time."));
        alert.accessoryView = box;
        [alert addButtonWithTitle:@(TOTK_UI("开始", "Play"))];
        [alert addButtonWithTitle:@(TOTK_UI("退出", "Quit"))];
        if ([alert runModal] != NSAlertFirstButtonReturn) return NO;
        pick = (NSUInteger)picker.menu.indexOfSelectedItem;
        rows = picker.rows;
    }
    [rows[pick][0] writeToFile:[data stringByAppendingPathComponent:@"player-last.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    *profile = [data stringByAppendingPathComponent:rows[pick][0]];
    *name = rows[pick][1];
    *several = rows.count > 1;
    return YES;
}

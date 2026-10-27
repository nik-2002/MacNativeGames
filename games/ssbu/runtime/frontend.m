/* Native macOS window and VI service adapter. No guest frame is synthesized. */
#import <Cocoa/Cocoa.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import <CoreVideo/CoreVideo.h>
#import <WebKit/WebKit.h>
#include <stdatomic.h>
#include <math.h>
#include "runtime.h"
#include "game_version.h"
#include "totk_ui_lang.h"
static NSWindow *window;
uint64_t dm_nvn_frame_count(void);   /* gfx/nvn/hle_nvn.c: game frames presented so far */
static CAMetalLayer *metalLayer;
static NSView *bootOverlay;
static NSTextField *bootStage,*bootDetail;
static NSProgressIndicator *bootProgress;
static NSView *shortcutHelp;
static uint64_t bootStartNS;
static _Atomic uint64_t presentedFrames;
static _Atomic int warmPending,warmStarted;
static CVDisplayLinkRef displayLink;
static _Atomic int focused;
static pthread_mutex_t vsyncLock=PTHREAD_MUTEX_INITIALIZER;
static void *vsyncEvents[16];
static unsigned vsyncCount;
void hle_bind_system_event(void *,int);
void hle_signal_system_event(void *);
void *front_metal_layer(void){return (__bridge void *)metalLayer;}
void front_frame_presented(void){
 if(atomic_fetch_add_explicit(&presentedFrames,1,memory_order_relaxed)==0){
  fprintf(stderr,"[ssbu-boot] %.3f first presented frame\n",(runtime_now_ns()-bootStartNS)/1e9);
  /* The loading screen stays until the shader warm-up is done (runtime_warm_done), which starts right after the first
     frame and holds the game until it finishes: the player sees its progress bar, not a black window. Without a
     warm-up (none started within 3 s) it goes then. */
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC),dispatch_get_main_queue(), ^{if(!atomic_load(&warmStarted))bootOverlay.hidden=YES;});
 }
}
void runtime_boot_progress(const char *stage,uint64_t done,uint64_t total){
 static const char *last;
 if(stage!=last){fprintf(stderr,"[ssbu-boot] %.3f %s\n",bootStartNS?(runtime_now_ns()-bootStartNS)/1e9:0,stage?stage:"startup");last=stage;}
 NSString *s=[NSString stringWithUTF8String:stage?stage:TOTK_UI("正在启动","Starting")];
 dispatch_async(dispatch_get_main_queue(), ^{
  if(!bootOverlay||bootOverlay.hidden)return;
  bootStage.stringValue=s;
  if(total){bootDetail.stringValue=[NSString stringWithFormat:@"%.1f / %.1f GB",done/1e9,total/1e9];
   bootProgress.indeterminate=NO;bootProgress.doubleValue=(double)done/(double)total*100.0;}
  else {bootDetail.stringValue=@(TOTK_UI("正在处理，请稍候","Working, please wait"));bootProgress.indeterminate=YES;[bootProgress startAnimation:nil];}
 });
}
void runtime_boot_count(const char *stage,uint64_t done,uint64_t total){
 /* Steps counted in items, not bytes (the shader import: tens of thousands of files, minutes on a phone). */
 static const char *last;
 if(stage!=last){fprintf(stderr,"[ssbu-boot] %.3f %s\n",bootStartNS?(runtime_now_ns()-bootStartNS)/1e9:0,stage?stage:"startup");last=stage;}
 NSString *s=[NSString stringWithUTF8String:stage?stage:TOTK_UI("正在启动","Starting")];
 dispatch_async(dispatch_get_main_queue(), ^{
  if(!bootOverlay||bootOverlay.hidden)return;
  bootStage.stringValue=s;bootDetail.stringValue=[NSString stringWithFormat:@"%llu / %llu",(unsigned long long)done,(unsigned long long)total];
  if(total){bootProgress.indeterminate=NO;bootProgress.doubleValue=(double)done/(double)total*100.0;}
 });
}
void runtime_boot_status(const char *stage,const char *detail){
 if(bootStartNS)fprintf(stderr,"[ssbu-boot] %.3f %s — %s\n",(runtime_now_ns()-bootStartNS)/1e9,stage?stage:"startup",detail?detail:"");
 NSString *s=[NSString stringWithUTF8String:stage?stage:TOTK_UI("正在启动","Starting")];
 NSString *d=[NSString stringWithUTF8String:detail?detail:TOTK_UI("正在处理，请稍候","Working, please wait")];
 dispatch_async(dispatch_get_main_queue(), ^{
  if(!bootOverlay||bootOverlay.hidden)return;
  bootStage.stringValue=s;bootDetail.stringValue=d;
  bootProgress.indeterminate=YES;[bootProgress startAnimation:nil];
 });
}
void runtime_warm_progress(uint64_t done,uint64_t total,uint64_t shaders,uint64_t shader_total,uint64_t pipelines,uint64_t pipeline_total){
 atomic_store(&warmPending,1);atomic_store(&warmStarted,1);(void)shader_total;
 dispatch_async(dispatch_get_main_queue(), ^{
  if(!bootOverlay||bootOverlay.hidden)return;
  /* The bar follows the pipelines (what the game waits for); the cache top-up after them happens with the game running. */
  double percent=pipeline_total ? fmin(100.0,(double)pipelines/(double)pipeline_total*100.0) : total ? fmin(100.0,(double)done/(double)total*100.0) : 100.0;
  bootStage.stringValue=[NSString stringWithFormat:@(TOTK_UI("正在准备图形 %.0f%%","Preparing graphics %.0f%%")),floor(percent)];
  bootDetail.stringValue=[NSString stringWithFormat:@(TOTK_UI("管线 %llu/%llu · 着色器 %llu","pipelines %llu/%llu · shaders %llu")),
      (unsigned long long)pipelines,(unsigned long long)pipeline_total,(unsigned long long)shaders];
  bootProgress.indeterminate=NO;
  bootProgress.doubleValue=percent;
 });
}
static void page_prewarm(void);   /* the manual's web process, started once the game runs (below) */
void runtime_warm_ready(void){   /* the startup pipelines are ready and the game goes on: the loading screen goes */
 atomic_store(&warmPending,0);
 dispatch_async(dispatch_get_main_queue(), ^{if(atomic_load(&presentedFrames))bootOverlay.hidden=YES;page_prewarm();});
}
void runtime_warm_done(void){
 atomic_store(&warmPending,0);
 dispatch_async(dispatch_get_main_queue(), ^{if(atomic_load(&presentedFrames))bootOverlay.hidden=YES;});
}
uint64_t front_game_res(int docked){(void)docked;return (720ULL<<32)|1280;}
/* TOTK_ASSUME_FOCUS=1: unattended test runs. macOS refuses to activate an app launched from the background while the user is working in
   another one; the window then never becomes key, GetCurrentFocusState stays 0 and the game waits before its first frame. In this mode the
   game is told it is focused, and the window is shown without taking the keyboard from the user (scripted input does not need it). */
static int assume_focus(void){static int v=-1;if(v<0){const char *e=getenv("TOTK_ASSUME_FOCUS");v=e&&atoi(e);}return v;}
/* Keep the guest active when the macOS window loses key status. Native input is still cleared
   in windowDidResignKey so a held key cannot remain stuck while another app has focus. */
int runtime_front_focus(void){return 1;}
static CVReturn vsync_callback(CVDisplayLinkRef link,const CVTimeStamp *now,const CVTimeStamp *output,CVOptionFlags flags,CVOptionFlags *out,void *ctx){
 (void)link;(void)now;(void)output;(void)flags;(void)out;(void)ctx;
 pthread_mutex_lock(&vsyncLock);for(unsigned i=0;i<vsyncCount;i++)hle_signal_system_event(vsyncEvents[i]);pthread_mutex_unlock(&vsyncLock);return kCVReturnSuccess;
}
@interface TOTKInputView:NSView
@end
@implementation TOTKInputView
-(BOOL)acceptsFirstResponder{return YES;}
-(void)keyDown:(NSEvent *)e{runtime_input_key(e.keyCode,1);}
-(void)keyUp:(NSEvent *)e{runtime_input_key(e.keyCode,0);}
-(void)flagsChanged:(NSEvent *)e{if(e.keyCode==56)runtime_input_key(56,!!(e.modifierFlags&NSEventModifierFlagShift));if(e.keyCode==58)runtime_input_key(58,!!(e.modifierFlags&NSEventModifierFlagOption));}
@end
@interface TOTKShortcutHelp:NSView
@property(strong) NSTextField *label;
@property(strong) NSTimer *timer;
@property NSSize textSize;
-(void)position;
-(void)refresh;
@end
/* Compact HUD (default): one small box in the window's top-right corner with the FPS, shader and load lines (published by
   gfx/nvn/fps_overlay.c, refreshed twice a second) above the shortcuts. TOTK_HUD=corners: the lines stay in the picture's
   corners and this is the larger centred shortcut box. */
@implementation TOTKShortcutHelp
static NSString *shortcut_text(void){
 /* The by3 help advertised its 60 fps/interpolation/picture/ultrawide keys. Those are not SSBU settings in this
    scaffold; the launcher owns the output choices. TODO(ssbu): document real SSBU shortcuts once they exist. */
 return @(TOTK_UI("快捷键说明\n1  显示 / 隐藏所有提示","Shortcuts\n1  Show / hide all overlays"));
}
-(instancetype)initWithFrame:(NSRect)frame{if((self=[super initWithFrame:frame])){int compact=hud_compact();self.wantsLayer=YES;self.layer.backgroundColor=[NSColor colorWithCalibratedWhite:0.04 alpha:compact?0.72:0.86].CGColor;self.layer.cornerRadius=compact?7:14;self.layer.borderWidth=1;self.layer.borderColor=[NSColor colorWithCalibratedWhite:1 alpha:compact?0.14:0.2].CGColor;
 self.label=[NSTextField labelWithString:shortcut_text()];self.label.font=[NSFont systemFontOfSize:17 weight:NSFontWeightMedium];self.label.textColor=NSColor.whiteColor;self.label.alignment=NSTextAlignmentCenter;self.label.maximumNumberOfLines=0;self.label.lineBreakMode=NSLineBreakByWordWrapping;self.label.frame=NSInsetRect(self.bounds,20,18);self.label.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;[self addSubview:self.label];
 if(compact){self.label.alignment=NSTextAlignmentLeft;self.label.lineBreakMode=NSLineBreakByClipping;}
 [self refresh];__weak TOTKShortcutHelp *weak=self;self.timer=[NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t){(void)t;[weak refresh];}];}return self;}
-(void)refresh{
 if(!hud_compact()){self.label.stringValue=shortcut_text();return;}
 NSFont *mono=[NSFont monospacedSystemFontOfSize:10.5 weight:NSFontWeightMedium],*small=[NSFont systemFontOfSize:10];
 NSColor *green=[NSColor colorWithCalibratedRed:80/255.0 green:1 blue:120/255.0 alpha:1],*yellow=[NSColor colorWithCalibratedRed:1 green:230/255.0 blue:40/255.0 alpha:1];
 NSMutableAttributedString *a=[NSMutableAttributedString new];
 for(int i=0;i<3;i++){char t[128];int hl=0;if(!hud_snapshot(i,t,sizeof t,&hl))continue;
  [a appendAttributedString:[[NSAttributedString alloc] initWithString:[([NSString stringWithUTF8String:t] ?: @"") stringByAppendingString:@"\n"] attributes:@{NSFontAttributeName:mono,NSForegroundColorAttributeName:hl?yellow:green}]];}
 if(a.length){NSMutableParagraphStyle *gap=[NSMutableParagraphStyle new];gap.paragraphSpacingBefore=4;
  [a appendAttributedString:[[NSAttributedString alloc] initWithString:shortcut_text() attributes:@{NSFontAttributeName:small,NSForegroundColorAttributeName:[NSColor colorWithCalibratedWhite:0.75 alpha:1],NSParagraphStyleAttributeName:gap}]];}
 else [a appendAttributedString:[[NSAttributedString alloc] initWithString:shortcut_text() attributes:@{NSFontAttributeName:small,NSForegroundColorAttributeName:[NSColor colorWithCalibratedWhite:0.75 alpha:1]}]];
 if([a isEqualToAttributedString:self.label.attributedStringValue])return;
 self.label.attributedStringValue=a;NSSize z=[self.label sizeThatFits:NSMakeSize(CGFLOAT_MAX,CGFLOAT_MAX)];self.textSize=NSMakeSize(ceil(z.width),ceil(z.height));[self position];}
-(NSView *)hitTest:(NSPoint)p{(void)p;return nil;}
-(void)viewDidMoveToSuperview{[super viewDidMoveToSuperview];[self position];}
-(void)layout{[super layout];[self position];}
-(void)position{if(!self.superview)return;NSRect f,in;
 if(hud_compact()){CGFloat w=self.textSize.width+16,h=self.textSize.height+10,m=10;f=NSMakeRect(floor(self.superview.bounds.size.width-w-m),floor(self.superview.bounds.size.height-h-m),w,h);in=NSMakeRect(8,5,self.textSize.width,self.textSize.height);}
 else{CGFloat w=MIN(560,MAX(280,self.superview.bounds.size.width-40)),h=168;f=NSMakeRect(floor((self.superview.bounds.size.width-w)/2),floor((self.superview.bounds.size.height-h)/2),w,h);in=NSInsetRect(NSMakeRect(0,0,w,h),20,18);}
 if(!NSEqualRects(self.frame,f))self.frame=f;self.label.frame=in;}
@end
void runtime_shortcut_help_toggle(void){int show=fps_overlay_toggle_hints();dispatch_async(dispatch_get_main_queue(), ^{shortcutHelp.hidden=!show;});}
/* The drawable follows the window's pixel size; the present pass scales the game picture (1920x1080 docked) into it and
   keeps 16:9 (black bars on other shapes), so a larger window or full screen shows the game at its own resolution instead
   of a fixed small drawable that the compositor stretches. */
/* TOTK_DRAWABLE_SCALE=<f> (test scripts only): the drawable is that many times the window's pixels and the window server
   scales it down for the screen. It lets a test exercise the 2K output path (a 2560x1440 picture) on a screen smaller than
   that (2026-10-17: the Mac reported a 1920x1080 display); the desktop launcher never sets it. */
static CGFloat drawable_scale(void){static CGFloat f=-1;if(f<0){const char *e=getenv("TOTK_DRAWABLE_SCALE");f=e?atof(e):1;if(f<0.25||f>4)f=1;}return f;}
static void front_sync_drawable(void){
 NSView *v=window.contentView;if(!v||!metalLayer)return;
 CGFloat s=window.backingScaleFactor>0?window.backingScaleFactor:1,ts=drawable_scale();CGSize px=CGSizeMake(round(v.bounds.size.width*s*ts),round(v.bounds.size.height*s*ts));
 if(px.width<1||px.height<1||CGSizeEqualToSize(metalLayer.drawableSize,px))return;
 metalLayer.contentsScale=s;metalLayer.drawableSize=px;fprintf(stderr,"[ssbu] window drawable %.0fx%.0f (scale %.0f)\n",px.width,px.height,s);
}
@interface TOTKWindowDelegate:NSObject<NSWindowDelegate>
@end
@implementation TOTKWindowDelegate
-(void)windowDidBecomeKey:(NSNotification *)n{(void)n;atomic_store(&focused,1);runtime_oe_push_message(15);fprintf(stderr,"[ssbu] window gained focus\n");}
-(void)windowDidResignKey:(NSNotification *)n{(void)n;atomic_store(&focused,0);runtime_input_focus_lost();runtime_oe_push_message(15);fprintf(stderr,"[ssbu] window lost focus\n");}
/* The process ends with the window. Save writes go straight to the files (runtime/fs_host.c), so a close in the middle of a
   save waits (up to 15 s, the window already gone) until the game has written and committed it (runtime_fs_save_busy). */
-(void)windowWillClose:(NSNotification *)n{(void)n;
 if(!runtime_fs_save_busy()){fprintf(stderr,"[ssbu] window closed; graceful guest shutdown pending\n");_exit(0);}
 fprintf(stderr,"[ssbu] window closed while the game is saving: quitting when the save is done\n");
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
  uint64_t t0=runtime_now_ns();while(runtime_fs_save_busy()&&runtime_now_ns()-t0<15000000000ull)usleep(20000);
  fprintf(stderr,"[ssbu] save %s after %.2f s; quitting\n",runtime_fs_save_busy()?"still in progress (gave up)":"done",(runtime_now_ns()-t0)/1e9);_exit(0);});
}
-(void)windowDidResize:(NSNotification *)n{(void)n;front_sync_drawable();}
/* Whether any part of the window can be seen (TOTK, 2026-10-16 night): macOS stops the display link's callbacks for a
   fully covered window, so presents stop and per-picture measurements of that stretch are void; a test session's log
   says when (the user working in other apps covered the test windows of the frame interpolation tests). */
static _Atomic int windowVisible=-1;   /* -1 not known yet; read by the present path's stall lines (runtime_front_window_visible) */
static void note_occlusion(const char *when){int v=(window.occlusionState&NSWindowOcclusionStateVisible)!=0;atomic_store(&windowVisible,v);
 fprintf(stderr,"[ssbu] window %s%s (frame %llu)\n",v?"visible":"covered (or on another Space): no presents until it is visible again",when,(unsigned long long)dm_nvn_frame_count());}
-(void)windowDidChangeOcclusionState:(NSNotification *)n{(void)n;note_occlusion("");}
-(void)windowDidChangeBackingProperties:(NSNotification *)n{(void)n;front_sync_drawable();}
@end
static TOTKWindowDelegate *windowDelegate;
int runtime_front_window_visible(void){return atomic_load(&windowVisible);}
void runtime_front_request_close(void){dispatch_async(dispatch_get_main_queue(), ^{[window performClose:nil];});}
/* Use the window-close path, not terminate:, so Command-Q also waits for active saves. */
void *runtime_front_content_view(void){return (__bridge void *)window.contentView;}   /* pad_screen.m */
@interface TOTKMenuTarget:NSObject
@end
@implementation TOTKMenuTarget
-(void)controllers:(id)sender{(void)sender;runtime_pad_screen_open();}
@end
static TOTKMenuTarget *menuTarget;
static void front_install_menu(void){
 NSMenu *menu=[NSMenu new],*appMenu=[NSMenu new];
 NSMenuItem *appItem=[NSMenuItem new];appItem.submenu=appMenu;[menu addItem:appItem];
 /* ⌘K: the controller screen (runtime/pad_screen.m), as the Switch's Controllers > Change Grip/Order. */
 menuTarget=[TOTKMenuTarget new];
 NSMenuItem *pads=[[NSMenuItem alloc] initWithTitle:@(TOTK_UI("手柄…","Controllers…")) action:@selector(controllers:) keyEquivalent:@"k"];
 pads.keyEquivalentModifierMask=NSEventModifierFlagCommand;pads.target=menuTarget;[appMenu addItem:pads];[appMenu addItem:[NSMenuItem separatorItem]];
 NSMenuItem *quit=[[NSMenuItem alloc] initWithTitle:@(TOTK_UI("退出 Super Smash Bros. Ultimate","Quit Super Smash Bros. Ultimate")) action:@selector(performClose:) keyEquivalent:@"q"];
 quit.keyEquivalentModifierMask=NSEventModifierFlagCommand;quit.target=window;
 [appMenu addItem:quit];NSApp.mainMenu=menu;
}
static void *guest_main(void *callback){@autoreleasepool{((void(*)(void))callback)();}return NULL;}
void runtime_front_run(void(*callback)(void)){
 @autoreleasepool{
  bootStartNS=runtime_now_ns();
  [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
  runtime_gamepad_start();
  /* Default window: the docked output size, 1920x1080, scaled down (16:9 kept) when the screen's visible area is smaller. */
  /* TOTK_WINDOW_SIZE=<w>x<h> (test scripts only, e.g. the 2K output test; the desktop launcher never sets it): another starting size. */
  /* SSBU_DISPLAY=<n> (the launcher's monitor choice): NSScreen.screens[n] holds the window, and full screen opens there. */
  NSScreen *screen=NSScreen.mainScreen;
  {const char *d=getenv("SSBU_DISPLAY");NSArray<NSScreen *> *all=NSScreen.screens;if(d&&*d){unsigned long i=strtoul(d,NULL,10);if(i<all.count)screen=all[i];}}
  NSRect vis=screen?screen.visibleFrame:NSMakeRect(0,0,1920,1080+28);CGFloat ww=1920,wh=1080;
  {const char *e=getenv("TOTK_WINDOW_SIZE");int w=0,h=0;if(e&&sscanf(e,"%dx%d",&w,&h)==2&&w>=320&&h>=180&&w<=8192&&h<=8192){ww=w;wh=h;}}
  CGFloat k=fmin(1,fmin(vis.size.width/ww,(vis.size.height-28)/wh));ww=floor(ww*k);wh=floor(wh*k);
  window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,ww,wh) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
  window.releasedWhenClosed=NO;   /* a close that waits for a save (windowWillClose) must not free the window the static pointer still holds */
  /* An agent's test game (TOTK_SLOT_OWNER other than user) says so in its title: it plays a save copy and its script closes it. */
  const char *owner=getenv("TOTK_SLOT_OWNER"),*purpose=getenv("TOTK_SLOT_PURPOSE");
  window.title=owner&&*owner&&strcmp(owner,"user")?[NSString stringWithFormat:@(TOTK_UI("测试局（%s）Ver. %s：%s — 存档副本，进度不会存进你的存档，脚本会自己关闭","Test session (%s) Ver. %s: %s — save copy, progress is not saved to your save, the script closes it")),owner,TOTK_GAME_VERSION,purpose&&*purpose?purpose:TOTK_UI("代理测试","agent test")]:[NSString stringWithFormat:@"Super Smash Bros. Ultimate Mac — Ver. %s",TOTK_GAME_VERSION];
  windowDelegate=[TOTKWindowDelegate new];window.delegate=windowDelegate;
  front_install_menu();
  window.collectionBehavior|=NSWindowCollectionBehaviorFullScreenPrimary;
  window.contentView=[[TOTKInputView alloc] initWithFrame:NSMakeRect(0,0,ww,wh)];
  metalLayer=[CAMetalLayer layer];metalLayer.device=MTLCreateSystemDefaultDevice();metalLayer.pixelFormat=MTLPixelFormatBGRA8Unorm_sRGB;metalLayer.drawableSize=CGSizeMake(ww,wh);
  metalLayer.framebufferOnly=NO;window.contentView.wantsLayer=YES;window.contentView.layer=metalLayer;
  bootOverlay=[[NSView alloc] initWithFrame:window.contentView.bounds];bootOverlay.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
  bootOverlay.wantsLayer=YES;bootOverlay.layer.backgroundColor=[NSColor colorWithCalibratedRed:0.035 green:0.075 blue:0.09 alpha:1].CGColor;
  bootStage=[NSTextField labelWithString:@(TOTK_UI("正在启动 Super Smash Bros. Ultimate","Starting Super Smash Bros. Ultimate"))];
  bootStage.font=[NSFont systemFontOfSize:25 weight:NSFontWeightSemibold];bootStage.textColor=NSColor.whiteColor;
  bootStage.alignment=NSTextAlignmentCenter;bootStage.frame=NSMakeRect(0,wh/2+20,ww,40);bootStage.autoresizingMask=NSViewWidthSizable|NSViewMinYMargin|NSViewMaxYMargin;
  bootDetail=[NSTextField labelWithString:@(TOTK_UI("正在准备游戏环境","Preparing the game environment"))];
  bootDetail.font=[NSFont systemFontOfSize:14];bootDetail.textColor=[NSColor colorWithCalibratedWhite:0.72 alpha:1];
  bootDetail.alignment=NSTextAlignmentCenter;bootDetail.frame=NSMakeRect(0,wh/2-20,ww,28);bootDetail.autoresizingMask=NSViewWidthSizable|NSViewMinYMargin|NSViewMaxYMargin;
  bootProgress=[[NSProgressIndicator alloc] initWithFrame:NSMakeRect(ww/2-140,wh/2-55,280,10)];
  bootProgress.minValue=0;bootProgress.maxValue=100;bootProgress.indeterminate=YES;bootProgress.autoresizingMask=NSViewMinXMargin|NSViewMaxXMargin|NSViewMinYMargin|NSViewMaxYMargin;
  [bootOverlay addSubview:bootStage];[bootOverlay addSubview:bootDetail];[bootOverlay addSubview:bootProgress];
  [window.contentView addSubview:bootOverlay];[bootProgress startAnimation:nil];
  shortcutHelp=[[TOTKShortcutHelp alloc] initWithFrame:NSZeroRect];shortcutHelp.autoresizingMask=hud_compact()?NSViewMinXMargin|NSViewMinYMargin:NSViewMinXMargin|NSViewMaxXMargin|NSViewMinYMargin|NSViewMaxYMargin;
  /* Keep discovery/warm-up visible; the help appears after the opaque boot
     overlay is hidden. Key 1 still controls its requested visibility. */
  [window.contentView addSubview:shortcutHelp positioned:NSWindowBelow relativeTo:bootOverlay];
  [(TOTKShortcutHelp *)shortcutHelp position];
  /* The FPS, shader and load lines: in the corner panel above (compact HUD), or with TOTK_HUD=corners drawn into the game picture's corners by the present encoder (gfx/nvn/fps_overlay.c). */
  [window makeFirstResponder:window.contentView];
  {NSRect f=window.frame;f.origin.x=NSMidX(vis)-f.size.width/2;f.origin.y=NSMidY(vis)-f.size.height/2;[window setFrame:f display:NO];}   /* centred on the chosen screen */
  front_sync_drawable();
  if(assume_focus()){[window orderFrontRegardless];}else{[window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];}   /* in front of other apps' windows, keyboard left alone */
  /* SSBU_FULLSCREEN=1 (the launcher's "Full screen"): macOS full screen from the start; the green button or ⌃⌘F leaves it. */
  {const char *fs=getenv("SSBU_FULLSCREEN");if(fs&&!strcmp(fs,"1"))dispatch_async(dispatch_get_main_queue(),^{if(!(window.styleMask&NSWindowStyleMaskFullScreen))[window toggleFullScreen:nil];});}
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC),dispatch_get_main_queue(),^{note_occlusion(" 3 s after opening");});
  atomic_store(&focused,1);
  CGDirectDisplayID dpid=(CGDirectDisplayID)[screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
  if(!dpid)dpid=CGMainDisplayID();
  if((CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)&&CVDisplayLinkCreateWithCGDisplay(dpid,&displayLink))||CVDisplayLinkSetOutputCallback(displayLink,vsync_callback,NULL)||CVDisplayLinkStart(displayLink))runtime_fail("native display link initialization");
  pthread_t guest;pthread_attr_t attr;pthread_attr_init(&attr);pthread_attr_setstacksize(&attr,8*1024*1024);int err=pthread_create(&guest,&attr,guest_main,(void *)callback);pthread_attr_destroy(&attr);if(err)runtime_fail("native game thread creation");
  [NSApp run];runtime_fail("native event loop returned unexpectedly");
 }
}
/* Text entry for the game (nn::swkbd::ShowKeyboard, runtime/swkbd_host.c; on the Switch a keyboard applet takes the screen).
   User, 2026-10-17: no on-screen keyboard, just the Mac keyboard. A bar at the bottom of the game window shows the game's
   prompt and one text field (input methods work); Return confirms, Escape cancels. Characters the game disallows and text
   beyond its length limit are removed as they are typed (the caller checks again). The calling guest thread waits on a
   semaphore; the game's keys are cleared while the bar has the keyboard. */
/* On-screen keyboard under the text field, for players on a controller (user, 2026-10-25): four rows of ten keys and a row of
   actions. Any controller drives it -- D-pad / left stick move (held: repeats), A types the key, B deletes, Y space,
   L capitals, R symbols, + done, - cancel -- and the mouse clicks keys. The first letter is a capital, as the Switch does. */
static NSString *const KEY_SHIFT=@"\u21E7",*const KEY_SYMBOLS=@"#+=",*const KEY_SPACE=@" ",*const KEY_DELETE=@"\u232B",*const KEY_DONE=@"OK";
@interface TOTKKeyGrid:NSView
@property int row,col;
@property BOOL shift,symbols,autoShift;   /* autoShift: the shift is the first-letter capital, not the player's */
@property(copy) void(^press)(NSString *key);
-(void)move:(int)dx :(int)dy;
-(NSString *)keyAt:(int)r :(int)c;
@end
@implementation TOTKKeyGrid
static const double actionUnits[5]={1.5,1.5,4,1.5,1.5};
-(BOOL)isFlipped{return YES;}
-(int)columns:(int)r{return r<4?10:5;}
-(NSString *)keyAt:(int)r :(int)c{   /* every row of letters / symbols has 10 keys; a short row gives blank keys, not a crash */
 static NSString *const letters[4]={@"1234567890",@"qwertyuiop",@"asdfghjkl'",@"zxcvbnm,.-"};
 static NSString *const symbols[4]={@"!@#$%^&*()",@"-_=+[]{};:",@"\"/?<>|\\~`\u20AC",@"\u00E9\u00E8\u00F1\u00FC\u00E7\u00E0\u00F6\u00DF\u2665\u2606"};
 if(r==4)return c>=0&&c<5?@[self.symbols?@"abc":KEY_SYMBOLS,KEY_SHIFT,KEY_SPACE,KEY_DELETE,KEY_DONE][c]:@"";
 NSString *row=(self.symbols?symbols:letters)[r];if(c<0||(NSUInteger)c>=row.length)return @"";
 NSString *k=[row substringWithRange:NSMakeRange((NSUInteger)c,1)],*up=k.uppercaseString;
 return self.shift&&up.length==1?up:k;   /* ß has no one-letter capital */
}
-(NSRect)rectAt:(int)r :(int)c{
 CGFloat gap=6,w=self.bounds.size.width,h=(self.bounds.size.height-4*gap)/5,unit=(w-9*gap)/10,x=0;
 if(r<4)return NSMakeRect(c*(unit+gap),r*(h+gap),unit,h);
 for(int i=0;i<c;i++)x+=actionUnits[i]*unit+(actionUnits[i]-1)*gap+gap;
 return NSMakeRect(x,4*(h+gap),actionUnits[c]*unit+(actionUnits[c]-1)*gap,h);
}
-(void)drawRect:(NSRect)dirty{(void)dirty;
 for(int r=0;r<5;r++)for(int c=0;c<[self columns:r];c++){
  NSRect k=[self rectAt:r :c];BOOL sel=r==self.row&&c==self.col,on=r==4&&((c==1&&self.shift)||(c==0&&self.symbols));
  [(sel?[NSColor colorWithCalibratedRed:0.15 green:0.55 blue:0.95 alpha:1]:on?[NSColor colorWithCalibratedWhite:0.38 alpha:1]:[NSColor colorWithCalibratedWhite:0.2 alpha:1]) setFill];
  [[NSBezierPath bezierPathWithRoundedRect:k xRadius:7 yRadius:7] fill];
  NSString *t=[self keyAt:r :c];if([t isEqualToString:KEY_SPACE])t=@(TOTK_UI("空格","space"));
  NSDictionary *a=@{NSFontAttributeName:[NSFont systemFontOfSize:r==4?15:19 weight:NSFontWeightMedium],NSForegroundColorAttributeName:NSColor.whiteColor};
  NSSize z=[t sizeWithAttributes:a];[t drawAtPoint:NSMakePoint(NSMidX(k)-z.width/2,NSMidY(k)-z.height/2) withAttributes:a];}
}
-(void)move:(int)dx :(int)dy{
 int r=self.row,c=self.col;
 if(dy){int nr=(r+dy+5)%5;
  if(r<4&&nr==4){double x=c+0.5,acc=0;c=4;for(int i=0;i<5;i++){acc+=actionUnits[i];if(x<=acc){c=i;break;}}}
  else if(r==4&&nr<4){double acc=0;for(int i=0;i<c;i++)acc+=actionUnits[i];c=(int)fmin(9,acc+actionUnits[c]/2);}
  r=nr;}
 if(dx)c=(c+dx+[self columns:r])%[self columns:r];
 self.row=r;self.col=c;self.needsDisplay=YES;
}
-(void)mouseDown:(NSEvent *)e{
 NSPoint p=[self convertPoint:e.locationInWindow fromView:nil];
 for(int r=0;r<5;r++)for(int c=0;c<[self columns:r];c++)if(NSPointInRect(p,[self rectAt:r :c])){self.row=r;self.col=c;self.needsDisplay=YES;if(self.press)self.press([self keyAt:r :c]);return;}
}
@end
@interface TOTKTextBar:NSView<NSTextFieldDelegate>
@property(strong) NSTextField *field;
@property int maxUnits,minUnits,digitsOnly;
@property uint32_t disabled;
@property(copy) void(^done)(NSString *text);   /* nil: cancelled */
@property(strong) TOTKKeyGrid *grid;
@property(strong) NSTimer *pad;
@property uint64_t prev,repeatAt;
@property int repeatDir;
-(void)refilter;
-(void)key:(NSString *)k;
@end
@implementation TOTKTextBar
-(BOOL)allowed:(unichar)c{
 BOOL digit=c>='0'&&c<='9';uint32_t d=self.disabled;
 if(self.digitsOnly&&!digit)return NO;
 if(c<0x20||c==0x7f)return NO;
 if((d&1u<<1&&c==' ')||(d&1u<<2&&c=='@')||(d&1u<<3&&c=='%')||(d&1u<<4&&c=='/')||(d&1u<<5&&c=='\\')||(d&1u<<6&&digit))return NO;
 return YES;
}
-(void)controlTextDidChange:(NSNotification *)n{(void)n;[self refilter];
 TOTKKeyGrid *g=self.grid;BOOL empty=!self.field.stringValue.length;   /* typed on the Mac keyboard: the first-letter capital follows */
 if(!g.symbols&&g.shift!=empty&&g.autoShift){g.shift=empty;g.needsDisplay=YES;}}
-(void)refilter{
 NSText *ed=self.field.currentEditor;if([ed isKindOfClass:NSTextView.class]&&((NSTextView *)ed).hasMarkedText)return;   /* still composing */
 NSString *s=self.field.stringValue;NSMutableString *t=[NSMutableString string];
 [s enumerateSubstringsInRange:NSMakeRange(0,s.length) options:NSStringEnumerationByComposedCharacterSequences usingBlock:^(NSString *sub,NSRange r,NSRange er,BOOL *stop){
  (void)r;(void)er;
  if(sub.length==1&&![self allowed:[sub characterAtIndex:0]])return;
  if(self.maxUnits>0&&t.length+sub.length>(NSUInteger)self.maxUnits){*stop=YES;return;}
  [t appendString:sub];}];
 if(![t isEqualToString:s]){self.field.stringValue=t;NSBeep();}
}
-(void)finish:(NSString *)text{[self.pad invalidate];self.pad=nil;void(^d)(NSString *)=self.done;self.done=nil;if(d)d(text);}
-(void)confirm{[self refilter];NSString *s=self.field.stringValue;
 if((NSInteger)s.length<self.minUnits||!s.length){NSBeep();return;}[self finish:s];}
-(void)key:(NSString *)k{   /* a key of the on-screen keyboard */
 TOTKKeyGrid *g=self.grid;NSString *s=self.field.stringValue;if(!k.length)return;
 if([k isEqualToString:KEY_DONE]){[self confirm];return;}
 if([k isEqualToString:KEY_SHIFT]){g.shift=!g.shift;g.autoShift=NO;g.needsDisplay=YES;return;}
 if([k isEqualToString:KEY_SYMBOLS]||[k isEqualToString:@"abc"]){g.symbols=!g.symbols;g.needsDisplay=YES;return;}
 if([k isEqualToString:KEY_DELETE]){if(s.length){NSRange r=[s rangeOfComposedCharacterSequenceAtIndex:s.length-1];self.field.stringValue=[s substringToIndex:r.location];}
  if(!self.field.stringValue.length&&!g.symbols){g.shift=g.autoShift=YES;g.needsDisplay=YES;}return;}
 self.field.stringValue=[s stringByAppendingString:k];[self refilter];
 if(g.shift&&!g.symbols&&k.length==1&&[NSCharacterSet.letterCharacterSet characterIsMember:[k characterAtIndex:0]]&&g.autoShift){g.shift=NO;g.needsDisplay=YES;}
 NSText *ed=self.field.currentEditor;if(ed)ed.selectedRange=NSMakeRange(self.field.stringValue.length,0);
}
-(void)poll{   /* every controller (the game is waiting for the text, so its reads are not disturbed) */
 uint64_t b=0;int32_t lx=0,ly=0;
 for(int s=0;s<RUNTIME_GAMEPAD_SLOTS;s++){RuntimeGamepadState g;runtime_gamepad_read_slot(s,&g);b|=g.buttons;if(abs(g.lx)>abs(lx))lx=g.lx;if(abs(g.ly)>abs(ly))ly=g.ly;}
 uint64_t press=b&~self.prev,now=runtime_now_ns();self.prev=b;
 TOTKKeyGrid *g=self.grid;
 if(press&1)[self key:[g keyAt:g.row :g.col]];
 if(press&2)[self key:KEY_DELETE];
 if(press&8)[self key:KEY_SPACE];
 if(press&64)[self key:KEY_SHIFT];
 if(press&128)[self key:KEY_SYMBOLS];
 if(press&1024){[self confirm];return;}
 if(press&2048){[self finish:nil];return;}
 int dir=(b&1u<<12)||lx<-16000?1:(b&1u<<14)||lx>16000?2:(b&1u<<13)||ly>16000?3:(b&1u<<15)||ly<-16000?4:0;
 if(dir!=self.repeatDir){self.repeatDir=dir;self.repeatAt=now+380000000ull;}
 else if(!dir||now<self.repeatAt)return;
 else self.repeatAt=now+90000000ull;
 if(dir)[g move:dir==1?-1:dir==2?1:0 :dir==3?-1:dir==4?1:0];
}
-(BOOL)control:(NSControl *)c textView:(NSTextView *)tv doCommandBySelector:(SEL)sel{
 (void)c;(void)tv;
 if(sel==@selector(insertNewline:)){[self confirm];return YES;}
 if(sel==@selector(cancelOperation:)){[self finish:nil];return YES;}
 return NO;
}
@end
static __weak TOTKTextBar *openBar;   /* main thread only */
void runtime_front_text_test(const char *op,const char *text){
 NSString *o=[NSString stringWithUTF8String:op],*t=[NSString stringWithUTF8String:text?text:""]?:@"";
 dispatch_async(dispatch_get_main_queue(), ^{
  TOTKTextBar *bar=openBar;if(!bar){fprintf(stderr,"[ssbu] keyboard test: no text entry bar is open\n");return;}
  if([o isEqualToString:@"type"]){bar.field.stringValue=[bar.field.stringValue stringByAppendingString:t];[bar refilter];}
  else if([o isEqualToString:@"enter"])[bar control:bar.field textView:(NSTextView *)bar.field.currentEditor doCommandBySelector:@selector(insertNewline:)];
  else if([o isEqualToString:@"shot"]){   /* the bar as drawn (window screenshots of the game picture do not include AppKit views) */
   NSBitmapImageRep *rep=[bar bitmapImageRepForCachingDisplayInRect:bar.bounds];[bar cacheDisplayInRect:bar.bounds toBitmapImageRep:rep];
   NSData *png=[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];BOOL ok=[png writeToFile:t atomically:YES];
   fprintf(stderr,"[ssbu] keyboard test: bar picture %s %s\n",t.UTF8String,ok?"written":"FAILED");return;}
  else if([o isEqualToString:@"esc"])[bar control:bar.field textView:(NSTextView *)bar.field.currentEditor doCommandBySelector:@selector(cancelOperation:)];
  else if([o isEqualToString:@"key"])[bar key:t];   /* an on-screen key, as A or a click presses it (#+= symbols, the shift arrow, OK) */
  fprintf(stderr,"[ssbu] keyboard test: %s -> field \"%s\"\n",o.UTF8String,bar.field.stringValue.UTF8String);
 });
}
int runtime_front_text_input(const RuntimeTextRequest *req,char *out,size_t out_size){
 if(!window||!req||!out||!out_size){fprintf(stderr,"[ssbu] keyboard: no game window for text entry; cancelled\n");return 0;}
 NSString *prompt=[NSString stringWithUTF8String:req->prompt?req->prompt:""]?:@"",*initial=[NSString stringWithUTF8String:req->initial?req->initial:""]?:@"";
 int maxU=req->max_units,minU=req->min_units,digits=req->digits_only,secure=req->secure;uint32_t dis=req->disabled;
 __block NSString *result=nil;dispatch_semaphore_t sem=dispatch_semaphore_create(0);
 dispatch_async(dispatch_get_main_queue(), ^{
  NSView *cv=window.contentView;CGFloat w=fmin(720,cv.bounds.size.width-40),G=fmin(240,cv.bounds.size.height-220),h=G+122;
  TOTKTextBar *bar=[[TOTKTextBar alloc] initWithFrame:NSMakeRect(floor((cv.bounds.size.width-w)/2),48,w,h)];
  bar.autoresizingMask=NSViewMinXMargin|NSViewMaxXMargin|NSViewMaxYMargin;bar.wantsLayer=YES;bar.layer.cornerRadius=12;
  bar.layer.backgroundColor=[NSColor colorWithCalibratedRed:0.035 green:0.075 blue:0.09 alpha:0.92].CGColor;
  bar.maxUnits=maxU;bar.minUnits=minU;bar.digitsOnly=digits;bar.disabled=dis;
  NSTextField *label=[NSTextField labelWithString:prompt];label.font=[NSFont systemFontOfSize:16 weight:NSFontWeightSemibold];
  label.textColor=NSColor.whiteColor;label.frame=NSMakeRect(18,h-36,w-36,22);label.lineBreakMode=NSLineBreakByTruncatingTail;
  NSString *limit=maxU>0?[NSString stringWithFormat:@(TOTK_UI("最多 %d 个字 · ","Up to %d characters · ")),maxU]:@"";
  NSTextField *hint=[NSTextField labelWithString:[NSString stringWithFormat:@(TOTK_UI("%@键盘：回车确定，Esc 取消 · 手柄：A 输入 B 删除 Y 空格 L 大写 R 符号 + 确定 − 取消","%@Keyboard: Return / Esc · Controller: A type, B delete, Y space, L caps, R symbols, + done, \u2212 cancel")),limit]];
  hint.font=[NSFont systemFontOfSize:12];hint.textColor=[NSColor colorWithCalibratedWhite:0.72 alpha:1];hint.alignment=NSTextAlignmentLeft;hint.lineBreakMode=NSLineBreakByTruncatingTail;
  hint.frame=NSMakeRect(18,G+62,w-36,18);hint.autoresizingMask=NSViewWidthSizable;
  NSTextField *field=secure?[[NSSecureTextField alloc] initWithFrame:NSMakeRect(18,G+24,w-36,34)]:[[NSTextField alloc] initWithFrame:NSMakeRect(18,G+24,w-36,34)];
  field.font=[NSFont systemFontOfSize:20];field.stringValue=initial;field.delegate=bar;field.bezelStyle=NSTextFieldRoundedBezel;bar.field=field;
  __weak TOTKTextBar *weakBar=bar;
  bar.done=^(NSString *text){result=[text copy];[weakBar removeFromSuperview];[window makeFirstResponder:window.contentView];dispatch_semaphore_signal(sem);};
  TOTKKeyGrid *grid=[[TOTKKeyGrid alloc] initWithFrame:NSMakeRect(18,12,w-36,G)];grid.shift=grid.autoShift=!initial.length&&!digits;grid.row=1;
  grid.press=^(NSString *k){[weakBar key:k];};bar.grid=grid;
  [bar addSubview:label];[bar addSubview:hint];[bar addSubview:field];[bar addSubview:grid];[cv addSubview:bar];openBar=bar;
  bar.prev=~0ull;   /* buttons held when the bar opens (the A that opened it) do not count */
  bar.pad=[NSTimer timerWithTimeInterval:1.0/60 target:bar selector:@selector(poll) userInfo:nil repeats:YES];
  [NSRunLoop.mainRunLoop addTimer:bar.pad forMode:NSRunLoopCommonModes];
  runtime_input_clear();
  if(window.miniaturized)[window deminiaturize:nil];
  if(!assume_focus()){[NSApp activateIgnoringOtherApps:YES];[window makeKeyAndOrderFront:nil];}   /* test windows never take the keyboard */
  [window makeFirstResponder:field];
  fprintf(stderr,"[ssbu] keyboard: text entry bar shown (%s)\n",prompt.UTF8String);
 });
 dispatch_semaphore_wait(sem,DISPATCH_TIME_FOREVER);
 if(!result)return 0;
 snprintf(out,out_size,"%s",result.UTF8String?result.UTF8String:"");
 return 1;
}
/* The game's offline manual (Y Help: nn::web::ShowOfflineHtmlPage, runtime/system_services.c). On the Switch the web
   applet takes the screen; here a web view covers the game window and the calling guest thread waits until the player
   closes it. The pages come from <work>/manual/html-document (make manual: the HtmlDocument NCA of the player's base game
   and update). Their scripts call the applet's "nx" object (endApplet, footer, playReport): a stand-in answers every call,
   endApplet closes the page. Controls: mouse; B / Escape go back, or close on the first page; D-pad / left stick scroll.
   No buttons of our own: the pages draw the applet's button guide themselves ("B Back").
   The main menu's Help pages (How to Play, contents/howto) are a small app that reads the browser's Gamepad API instead:
   navigator.getGamepads()[0] in the NX browser's order (0 B, 1 A, 2 Y, 3 X, 4 L, 5 R, 6 ZL, 7 ZR, 8 -, 9 +, 10/11 stick
   clicks, 12-15 up/down/left/right) is a stand-in fed from every controller and the game's keyboard keys. While a page
   reads it, the page handles B itself. Its list page stays hidden (black) until a link has the focus, which the NX
   browser gives the first link; the stand-in does the same. Leaving to http://localhost/ is the applet's "close". */
@interface TOTKPageView:NSView<WKScriptMessageHandler,WKNavigationDelegate>
@property(strong) WKWebView *web;
@property(strong) NSTimer *pad;
@property(strong) id keys;
@property uint64_t prev,keyBits,sent;
@property BOOL padOwned;
@property unsigned tick;
@property(copy) void(^done)(void);
@end
@implementation TOTKPageView
-(void)userContentController:(WKUserContentController *)c didReceiveScriptMessage:(WKScriptMessage *)m{(void)c;(void)m;[self finish];}
-(void)webView:(WKWebView *)w decidePolicyForNavigationAction:(WKNavigationAction *)a decisionHandler:(void(^)(WKNavigationActionPolicy))h{
 (void)w;if([a.request.URL.host isEqualToString:@"localhost"]){h(WKNavigationActionPolicyCancel);[self finish];return;}
 h(WKNavigationActionPolicyAllow);}
-(void)finish{[self.pad invalidate];self.pad=nil;if(self.keys){[NSEvent removeMonitor:self.keys];self.keys=nil;}
 void(^d)(void)=self.done;self.done=nil;if(!d)return;
 [NSAnimationContext runAnimationGroup:^(NSAnimationContext *c){c.duration=0.15;self.animator.alphaValue=0;} completionHandler:d];}
-(void)back{if(self.web.canGoBack)[self.web goBack];else [self finish];}
-(BOOL)acceptsFirstResponder{return YES;}
-(void)layout{[super layout];   /* the pages are laid out for the Switch's 1280x720 screen: the largest 16:9 area of the window,
   centered (black around it), so nothing the pages keep below the screen shows */
 NSSize z=self.bounds.size;CGFloat k=fmax(0.25,fmin(z.width/1280,z.height/720));
 self.web.frame=NSMakeRect(floor((z.width-1280*k)/2),floor((z.height-720*k)/2),round(1280*k),round(720*k));self.web.pageZoom=k;}
-(void)cancelOperation:(id)sender{(void)sender;[self back];}
-(void)keyDown:(NSEvent *)e{if(e.keyCode==53)[self back];else [super keyDown:e];}
-(void)webView:(WKWebView *)w didFailProvisionalNavigation:(WKNavigation *)n withError:(NSError *)e{
 fprintf(stderr,"[ssbu] offline page: load failed: %s\n",e.localizedDescription.UTF8String);w.alphaValue=1;(void)n;}
-(void)webView:(WKWebView *)w didFinishNavigation:(WKNavigation *)n{(void)n;[w.window makeFirstResponder:w];
 if(w.alphaValue>0)return;   /* a later page of the same visit: the page does its own transition */
 /* the page over the black backdrop once it has drawn (no white first frame), faded in like the applet */
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(80*NSEC_PER_MSEC)),dispatch_get_main_queue(),^{
  [NSAnimationContext runAnimationGroup:^(NSAnimationContext *c){c.duration=0.2;w.animator.alphaValue=1;} completionHandler:nil];});}
-(uint64_t)keyBit:(unsigned short)k{   /* the game's keyboard controls (README), as Npad button bits */
 switch(k){case 38:return 1;case 40:case 49:return 2;case 34:return 4;case 32:return 8;case 12:return 1u<<6;case 14:return 1u<<7;
  case 36:return 1u<<10;case 48:return 1u<<11;case 13:case 17:case 126:return 1u<<13;case 1:case 5:case 125:return 1u<<15;
  case 0:case 3:case 123:return 1u<<12;case 2:case 4:case 124:return 1u<<14;default:return 0;}}
-(void)watchKeys{__weak TOTKPageView *me=self;   /* the game's keys drive the page as a controller does; other keys and Escape stay the web view's */
 self.keys=[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown|NSEventMaskKeyUp handler:^NSEvent *(NSEvent *e){
  TOTKPageView *p=me;uint64_t bit=p&&!(e.modifierFlags&NSEventModifierFlagCommand)?[p keyBit:e.keyCode]:0;if(!bit)return e;
  p.keyBits=e.type==NSEventTypeKeyDown?p.keyBits|bit:p.keyBits&~bit;return nil;}];}
-(void)feed:(uint64_t)b lx:(int32_t)lx ly:(int32_t)ly rx:(int32_t)rx ry:(int32_t)ry{   /* the Gamepad API stand-in */
 static const int8_t nx[16]={1,0,3,2,10,11,4,5,6,7,9,8,14,12,15,13};   /* Npad bit -> NX browser button */
 uint32_t m=0;for(int i=0;i<16;i++)if(b>>i&1)m|=1u<<nx[i];
 uint64_t key=(uint64_t)m|(uint64_t)((lx/4096)&15)<<32|(uint64_t)((ly/4096)&15)<<36|(uint64_t)((rx/4096)&15)<<40|(uint64_t)((ry/4096)&15)<<44;
 if(key==self.sent&&++self.tick%30)return;self.sent=key;   /* on a change, and twice a second to see whether the page reads it */
 __weak TOTKPageView *me=self;
 [self.web evaluateJavaScript:[NSString stringWithFormat:@"window.__nxPad&&window.__nxPad(%u,%.3f,%.3f,%.3f,%.3f)",m,lx/32767.0,-ly/32767.0,rx/32767.0,-ry/32767.0]
  completionHandler:^(id r,NSError *e){(void)e;me.padOwned=[r isKindOfClass:NSNumber.class]&&[r boolValue];}];}
-(void)poll{   /* every controller: B back, D-pad / left stick scroll (the game is waiting, so its reads are not disturbed) */
 uint64_t b=0;int32_t lx=0,ly=0,rx=0,ry=0;
 for(int s=0;s<RUNTIME_GAMEPAD_SLOTS;s++){RuntimeGamepadState g;runtime_gamepad_read_slot(s,&g);b|=g.buttons;
  if(abs(g.lx)>abs(lx))lx=g.lx;if(abs(g.ly)>abs(ly))ly=g.ly;if(abs(g.rx)>abs(rx))rx=g.rx;if(abs(g.ry)>abs(ry))ry=g.ry;}
 if(self.prev==~0ull&&b){return;}   /* buttons held when the page opens (the A or Y that opened it) do not count */
 b|=self.keyBits;[self feed:b lx:lx ly:ly rx:rx ry:ry];
 uint64_t press=b&~self.prev;self.prev=b;
 if(self.padOwned)return;   /* the page reads the pad: B, scrolling and closing are its own */
 if(press&2){[self back];return;}
 if(press&1){[self.web evaluateJavaScript:@"window.__nxNav&&window.__nxNav(0,0)" completionHandler:nil];return;}   /* A: the focused link */
 /* D-pad / left stick: the NX browser's focus moves to the nearest link that way, or the page scrolls; held, it repeats */
 int dx=(b&1u<<12)?-1:(b&1u<<14)?1:lx<-16000?-1:lx>16000?1:0,dy=(b&1u<<13)?-1:(b&1u<<15)?1:ly>16000?-1:ly<-16000?1:0;
 if(dy)dx=0;
 int dir=dx?2+dx:dy?5+dy:0;static int held,lastDir;
 if(!dir){held=0;lastDir=0;return;}
 if(dir!=lastDir)held=0;lastDir=dir;
 if(held++==0||(held>18&&(held-18)%6==0))
  [self.web evaluateJavaScript:[NSString stringWithFormat:@"window.__nxNav&&window.__nxNav(%d,%d)",dx,dy] completionHandler:nil];
}
@end
static __weak TOTKPageView *openPage;   /* main thread only */
/* One web content process kept running from the end of the loading screen: starting it when the player presses Y Help
   took most of a second, with the game's last frame standing still. */
static WKProcessPool *pagePool;static WKWebView *pageWarm;
static void page_prewarm(void){if(pagePool)return;pagePool=[WKProcessPool new];
 WKWebViewConfiguration *cfg=[WKWebViewConfiguration new];cfg.processPool=pagePool;
 pageWarm=[[WKWebView alloc] initWithFrame:NSMakeRect(0,0,16,16) configuration:cfg];[pageWarm loadHTMLString:@"" baseURL:nil];}
static NSString *manual_file(NSString *path){   /* "contents/help/x.html" -> <work>/manual/html-document/contents.htdocs/help/x.html */
 NSString *root=[NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:@"manual/html-document"];
 NSArray<NSString *> *parts=path.pathComponents;if(!parts.count)return nil;
 for(NSString *first in @[[parts[0] stringByAppendingString:@".htdocs"],parts[0]]){
  NSString *f=[[root stringByAppendingPathComponent:first] stringByAppendingPathComponent:[NSString pathWithComponents:[parts subarrayWithRange:NSMakeRange(1,parts.count-1)]]];
  if([NSFileManager.defaultManager fileExistsAtPath:f])return f;}
 return nil;
}
int runtime_front_offline_page(const char *document_path){
 NSString *full=[NSString stringWithUTF8String:document_path?document_path:""]?:@"";
 NSRange q=[full rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"?#"]];
 NSString *path=q.location==NSNotFound?full:[full substringToIndex:q.location],*query=q.location==NSNotFound?@"":[full substringFromIndex:q.location];
 while([path hasPrefix:@"/"])path=[path substringFromIndex:1];
 NSString *file=manual_file(path);
 if(!window||!file){fprintf(stderr,"[ssbu] offline page: %s not available (%s)\n",full.UTF8String,window?"no manual: make manual":"no window");return 0;}
 dispatch_semaphore_t sem=dispatch_semaphore_create(0);
 dispatch_async(dispatch_get_main_queue(), ^{
  NSView *cv=window.contentView;
  TOTKPageView *page=[[TOTKPageView alloc] initWithFrame:cv.bounds];page.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
  WKWebViewConfiguration *cfg=[WKWebViewConfiguration new];page_prewarm();cfg.processPool=pagePool;
  [cfg.preferences setValue:@YES forKey:@"allowFileAccessFromFileURLs"];
  NSString *shim=@"(function(){function stub(){return new Proxy(function(){},{get:function(t,k){if(k==='then')return undefined;if(!(k in t))t[k]=stub();return t[k];},apply:function(){return undefined;}});}"
   "var nx=stub();nx.endApplet=function(){window.webkit.messageHandlers.nx.postMessage('end');};window.nx=nx;"
   "if(!window.endApplet)window.endApplet=function(){nx.endApplet();};"
   "var pad={id:'nx',index:0,connected:true,mapping:'standard',timestamp:0,buttons:[],axes:[0,0,0,0]},read=0;"
   "for(var i=0;i<16;i++)pad.buttons.push({pressed:false,touched:false,value:0});"
   "Object.defineProperty(navigator,'getGamepads',{configurable:true,value:function(){read=Date.now();return [pad,null,null,null];}});"
   "window.__nxPad=function(m,lx,ly,rx,ry){for(var i=0;i<16;i++){var p=!!(m>>i&1);pad.buttons[i].pressed=pad.buttons[i].touched=p;pad.buttons[i].value=p?1:0;}"
   "pad.axes=[lx,ly,rx,ry];pad.timestamp=performance.now();return read>0&&Date.now()-read<1000;};"
   "window.__nxNav=function(dx,dy){var c=document.activeElement;"   /* (0,0): activate the focused link */
   "if(!dx&&!dy){if(c&&c!==document.body)c.click();return;}"
   "var vw=innerWidth,vh=innerHeight,best=null,bs=1e9,r0=c&&c!==document.body?c.getBoundingClientRect():null;"
   "var cx=r0?r0.left+r0.width/2:vw/2,cy=r0?r0.top+r0.height/2:(dy>0?-1:vh+1);"
   "var l=document.querySelectorAll('a[href],a[ref],button,[tabindex]:not([tabindex=\"-1\"])');"
   "for(var i=0;i<l.length;i++){var e=l[i];if(e===c||e.tabIndex<0)continue;var r=e.getBoundingClientRect();if(!r.width||!r.height)continue;"
   "if(r.bottom<-vh/2||r.top>vh*1.5||getComputedStyle(e).visibility==='hidden')continue;"
   "var along,lo,hi,clo,chi;if(!r0){along=dy>0?r.top:dy<0?vh-r.bottom:dx>0?r.left:vw-r.right;lo=hi=clo=chi=0;}"   /* edges, not centres: */
   "else if(dx){along=dx>0?r.left-r0.right:r0.left-r.right;lo=r.top;hi=r.bottom;clo=r0.top;chi=r0.bottom;}"   /* what lies straight that */
   "else{along=dy>0?r.top-r0.bottom:r0.top-r.bottom;lo=r.left;hi=r.right;clo=r0.left;chi=r0.right;}"   /* way wins over what is */
   "if(along<-8)continue;var gap=Math.max(0,lo-chi,clo-hi);var s=Math.max(along,0)+(gap>0?2000+gap*2:0);"   /* nearer but off to the side */
   "if(s<bs){bs=s;best=e;}}"
   "if(best&&(!r0||bs<2000+vh)){best.focus();best.scrollIntoView({block:'nearest',inline:'nearest',behavior:'smooth'});}"
   "else window.scrollBy({left:dx*vw/4,top:dy*vh/4,behavior:'smooth'});};"
   "var fk='nxfocus:'+location.pathname;"   /* coming back to a list, the link it was left from, as the NX browser keeps it */
   "document.addEventListener('focusin',function(e){var t=e.target,h=t&&t.tagName==='A'&&(t.getAttribute('ref')||t.getAttribute('href'));if(h)try{sessionStorage.setItem(fk,h);}catch(x){}});"
   "window.addEventListener('load',function(){requestAnimationFrame(function(){requestAnimationFrame(function(){"   /* the NX browser's event once the */
   "window.dispatchEvent(new Event('NXFirstPaintEndAfterLoad'));});});});"   /* loaded page has painted: Help lists start their images and intro on it */
   "var ff=document.fonts,fadd=ff.addEventListener.bind(ff);"   /* Help lists wait for a font 'loadingdone' that WebKit */
   "ff.addEventListener=function(t,f,o){fadd(t,f,o);if(t==='loadingdone')setTimeout(function(){ff.ready.then(function(){f({type:t,fontfaces:[]});});},100);};"   /* has sent already */
   "function first(){var h=null;try{h=sessionStorage.getItem(fk);}catch(x){}"
   "var l=[].filter.call(document.querySelectorAll('a[href],a[ref],[tabindex]'),function(e){var r=e.getBoundingClientRect();return e.tabIndex>=0&&r.width&&r.height;});"
   "for(var i=0;i<l.length;i++)if(h&&(l[i].getAttribute('href')===h||l[i].getAttribute('ref')===h))return l[i];return l[0];}"
   "window.addEventListener('load',function(){setTimeout(function(){"   /* after the page's own load handlers; lists drawn from */
   "if(document.activeElement!==document.body)return;var a=first();if(a)a.focus();},read?0:1200);});})();";   /* the pad at once, others after their intro */
  [cfg.userContentController addUserScript:[[WKUserScript alloc] initWithSource:shim injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
  /* The applet's own fonts: the pages' button guide ("B Back") names keyhelpFont / KeyHelpFont without a file, the Switch's
     standard UI font with the Nintendo extension font for the button glyphs (make manual decodes both into system-fonts). */
  NSString *fonts=[[NSURL fileURLWithPath:[NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:@"manual/html-document/system-fonts"] isDirectory:YES] absoluteString];
  NSMutableString *css=[NSMutableString string];
  [css appendFormat:@"@font-face{font-family:keyhelpFont;src:url('%@nintendo-extension.ttf');unicode-range:U+E000-E1FF}"   /* family names ignore case */
   "@font-face{font-family:keyhelpFont;src:url('%@standard.ttf');unicode-range:U+0000-DFFF,U+F000-FFFF}",fonts,fonts];
  /* Button glyphs in the pages' own fonts (Help captions: "A Select"): the Switch falls back to its extension font for
     them, so each family gets that range from it */
  for(NSString *family in @[@"MyFont",@"FontB",@"FontUB",@"FontB-Asia",@"FontUB-Asia",@"DFP_GB_H9",@"DFP_GB_HC",@"DFPT_B9",@"DFPT_BC",@"AsiaKBIGR",@"AsiaKGDU"])
   [css appendFormat:@"@font-face{font-family:'%@';src:url('%@nintendo-extension.ttf');unicode-range:U+E000-E1FF}",family,fonts];
  [css appendString:@"*:focus,*:focus-visible{outline:none!important}"
   "html{font-family:keyhelpFont}"];   /* the NX browser's default font is the system font (Mode Guide captions name none) */   /* the NX browser draws no focus ring (the pages' own cursor shows the focus) */
  NSString *fontScript=[NSString stringWithFormat:@"(function(){var s=document.createElement('style');s.textContent=%@;document.documentElement.appendChild(s);})();",
   [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:css options:NSJSONWritingFragmentsAllowed error:nil] encoding:NSUTF8StringEncoding]];
  [cfg.userContentController addUserScript:[[WKUserScript alloc] initWithSource:fontScript injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
  [cfg.userContentController addScriptMessageHandler:page name:@"nx"];
  WKWebView *web=[[WKWebView alloc] initWithFrame:page.bounds configuration:cfg];web.navigationDelegate=page;
  [web setValue:@NO forKey:@"drawsBackground"];web.underPageBackgroundColor=NSColor.blackColor;
  page.web=web;[page addSubview:web];page.wantsLayer=YES;page.layer.backgroundColor=NSColor.blackColor.CGColor;
  __weak TOTKPageView *weakPage=page;
  page.done=^{TOTKPageView *p=weakPage;[p.web.configuration.userContentController removeScriptMessageHandlerForName:@"nx"];[p removeFromSuperview];
   [window makeFirstResponder:window.contentView];runtime_input_clear();dispatch_semaphore_signal(sem);};
  /* the game picture fades to black at once, as the applet's screen does, while the page loads behind it */
  page.alphaValue=0;web.alphaValue=0;[cv addSubview:page];openPage=page;runtime_input_clear();
  [NSAnimationContext runAnimationGroup:^(NSAnimationContext *c){c.duration=0.15;page.animator.alphaValue=1;} completionHandler:nil];
  NSURL *root=[NSURL fileURLWithPath:[NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:@"manual/html-document"] isDirectory:YES];
  NSURL *url=[NSURL URLWithString:[[NSURL fileURLWithPath:file].absoluteString stringByAppendingString:query]];
  [web loadFileURL:url?:[NSURL fileURLWithPath:file] allowingReadAccessToURL:root];
  page.prev=~0ull;   /* buttons held when the page opens (the Y that opened it) do not count */
  page.pad=[NSTimer timerWithTimeInterval:1.0/60 target:page selector:@selector(poll) userInfo:nil repeats:YES];
  [NSRunLoop.mainRunLoop addTimer:page.pad forMode:NSRunLoopCommonModes];
  [page watchKeys];
  if(!assume_focus()){[NSApp activateIgnoringOtherApps:YES];[window makeKeyAndOrderFront:nil];}
  [window makeFirstResponder:page];
  fprintf(stderr,"[ssbu] offline page shown: %s\n",file.UTF8String);
 });
 dispatch_semaphore_wait(sem,DISPATCH_TIME_FOREVER);
 fprintf(stderr,"[ssbu] offline page closed\n");
 return 1;
}
void runtime_front_offline_test(const char *op){
 NSString *o=[NSString stringWithUTF8String:op?op:""]?:@"";
 dispatch_async(dispatch_get_main_queue(), ^{
  TOTKPageView *page=openPage;if(!page){fprintf(stderr,"[ssbu] offline page test: no page is open\n");return;}
  if([o hasPrefix:@"shot "]){NSString *path=[o substringFromIndex:5];
   [page.web takeSnapshotWithConfiguration:nil completionHandler:^(NSImage *img,NSError *err){
    NSBitmapImageRep *rep=img?[[NSBitmapImageRep alloc] initWithData:img.TIFFRepresentation]:nil;
    BOOL ok=[[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
    fprintf(stderr,"[ssbu] offline page test: picture %s %s%s\n",path.UTF8String,ok?"written":"FAILED ",ok?"":(err.localizedDescription?:@"").UTF8String);}];}
  else if([o isEqualToString:@"frame"])fprintf(stderr,"[ssbu] offline page test: view %.0fx%.0f, page at %.0f,%.0f %.0fx%.0f, zoom %.3f, alpha %.2f\n",
   page.bounds.size.width,page.bounds.size.height,page.web.frame.origin.x,page.web.frame.origin.y,page.web.frame.size.width,page.web.frame.size.height,page.web.pageZoom,page.alphaValue);
  else if([o hasPrefix:@"pad "]){uint64_t bits=strtoull([o substringFromIndex:4].UTF8String,NULL,0);   /* Npad buttons held 150 ms */
   page.keyBits|=bits;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(150*NSEC_PER_MSEC)),dispatch_get_main_queue(),^{page.keyBits&=~bits;});
   fprintf(stderr,"[ssbu] offline page test: pad 0x%llx (page reads the pad: %s)\n",(unsigned long long)bits,page.padOwned?"yes":"no");}
  else if([o hasPrefix:@"js "])[page.web evaluateJavaScript:[o substringFromIndex:3] completionHandler:^(id r,NSError *e){   /* "js <expression>": its value */
   fprintf(stderr,"[ssbu] offline page test: js -> %s\n",(e?e.localizedDescription:[NSString stringWithFormat:@"%@",r]).UTF8String);}];
  else if([o isEqualToString:@"close"])[page finish];
  else if([o isEqualToString:@"back"])[page back];
 });
}
static int viReady;
static unsigned displayIdentity,layerIdentity;
static void vi_initialize(void){if(!metalLayer)runtime_fail("VI requires native macOS window");viReady=1;fprintf(stderr,"[ssbu] native VI display initialized\n");}
static uint32_t vi_open(void **out){if(!viReady||!out)return 0xf601;*out=&displayIdentity;return 0;}
static uint32_t vi_layer(void **out,void *display){if(!out||display!=&displayIdentity)return 0xf601;*out=&layerIdentity;return 0;}
static uint32_t vi_window(void **out,void *layer){if(!out||layer!=&layerIdentity)return 0xf601;*out=front_metal_layer();return 0;}
static uint32_t vi_vsync(void *ev,void *display){
 if(!ev||display!=&displayIdentity)return 0xf601;hle_bind_system_event(ev,1);
 pthread_mutex_lock(&vsyncLock);if(vsyncCount>=16)runtime_fail("VI display event limit");vsyncEvents[vsyncCount++]=ev;pthread_mutex_unlock(&vsyncLock);return 0;
}
void *runtime_front_override(const char *name){
 static const struct{const char *name;void *fn;} entries[]={
 {"_ZN2nn2vi10InitializeEv",vi_initialize},{"_ZN2nn2vi18OpenDefaultDisplayEPPNS0_7DisplayE",vi_open},
 {"_ZN2nn2vi11CreateLayerEPPNS0_5LayerEPNS0_7DisplayE",vi_layer},{"_ZN2nn2vi15GetNativeWindowEPPvPNS0_5LayerE",vi_window},
 {"_ZN2nn2vi20GetDisplayVsyncEventEPNS_2os15SystemEventTypeEPNS0_7DisplayE",vi_vsync}};
 for(unsigned i=0;i<sizeof(entries)/sizeof(*entries);i++)if(!strcmp(name,entries[i].name))return entries[i].fn;return NULL;
}

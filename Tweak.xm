#include <substrate.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <limits.h>
#include <string.h>
#include <dispatch/dispatch.h>
#include <Foundation/Foundation.h>
#include <UIKit/UIKit.h>
#include <CoreGraphics/CoreGraphics.h>

// ─── Originals ────────────────────────────────────────────────────────────────
static BOOL (*orig_BatteryIsActive)(void);
static int  (*orig_BatteryRemainingSeconds)(void);
static void (*orig_BatteryOnGrant)(void);
static void (*orig_BatteryShowRewarded)(void);
static BOOL (*orig_StoreIsActive)(void);
static int  (*orig_StoreRemainingSeconds)(void);
static void (*orig_StoreBootstrap)(void);
static void (*orig_StoreGrantFromReward)(void);
static void (*orig_LibloaderBypassInstall)(void);
static void (*orig_AppStoreCheck)(void);
static void (*orig_GBAuto_SetConfig)(void);
static void (*orig_GBAuto_Reset)(void);
static void (*orig_GBOverlayStartIfNeeded)(void);
static void (*orig_GBOverlaySetModUIHidden)(BOOL);

// ─── Battery Hooks ────────────────────────────────────────────────────────────
static BOOL hook_BatteryIsActive(void)         { return YES;     }
static int  hook_BatteryRemainingSeconds(void) { return INT_MAX; }
static BOOL hook_StoreIsActive(void)           { return YES;     }
static int  hook_StoreRemainingSeconds(void)   { return INT_MAX; }
static void hook_StoreGrantFromReward(void)    {                 }
static void hook_AppStoreCheck(void)           {                 }

static void hook_StoreBootstrap(void) {
    if (orig_StoreBootstrap) orig_StoreBootstrap();
}
static void hook_BatteryOnGrant(void) {
    if (orig_BatteryOnGrant) orig_BatteryOnGrant();
}
static void hook_BatteryShowRewarded(void) {
    void (*grantFn)(void) = orig_BatteryOnGrant;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (grantFn) grantFn();
    });
}
static void hook_LibloaderBypassInstall(void) {
    if (orig_LibloaderBypassInstall) orig_LibloaderBypassInstall();
}

// ─── Sideload Detection Kill ──────────────────────────────────────────────────
%hook NSBundle
- (NSURL *)appStoreReceiptURL {
    return [NSURL fileURLWithPath:@"/private/var/mobile/Containers/Bundle/Application/receipt"];
}
%end

%hook UIAlertController
+ (instancetype)alertControllerWithTitle:(NSString *)title
                                 message:(NSString *)message
                          preferredStyle:(UIAlertControllerStyle)style {
    if (message && [message containsString:@"unofficial app"]) return nil;
    if (message && [message containsString:@"8350:C7BE"])      return nil;
    return %orig;
}
%end

%hook NSFileManager
- (BOOL)fileExistsAtPath:(NSString *)path {
    if ([path containsString:@"StoreKit"] ||
        [path containsString:@"receipt"]) return YES;
    return %orig;
}
%end

// ─── UI ───────────────────────────────────────────────────────────────────────

static UIWindow   *modWindow   = nil;
static UIView     *menuView    = nil;
static BOOL        menuVisible = NO;

// Forward declare
static void toggleMenu(void);
static void *gHandle = NULL;

static UILabel *makeLabel(NSString *text, CGFloat y, CGFloat fontSize, UIColor *color) {
    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(0, y, 260, 30)];
    lbl.text          = text;
    lbl.textColor     = color;
    lbl.font          = [UIFont boldSystemFontOfSize:fontSize];
    lbl.textAlignment = NSTextAlignmentCenter;
    return lbl;
}

static UIButton *makeButton(NSString *title, CGFloat y, SEL action, id target) {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = CGRectMake(15, y, 230, 38);
    [btn setTitle:title forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    btn.backgroundColor = [UIColor colorWithRed:0.08 green:0.08 blue:0.15 alpha:1.0];
    btn.layer.cornerRadius  = 10;
    btn.layer.borderWidth   = 1.0;
    btn.layer.borderColor   = [UIColor colorWithRed:0.0 green:0.8 blue:1.0 alpha:0.6].CGColor;
    [btn addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return btn;
}

@interface GBUnlimitedMenu : NSObject
+ (void)onAutoAim:(UIButton *)btn;
+ (void)onOverlay:(UIButton *)btn;
+ (void)onReset:(UIButton *)btn;
+ (void)onClose:(UIButton *)btn;
@end

@implementation GBUnlimitedMenu

+ (void)onAutoAim:(UIButton *)btn {
    btn.selected = !btn.selected;
    btn.backgroundColor = btn.selected
        ? [UIColor colorWithRed:0.0 green:0.6 blue:0.3 alpha:1.0]
        : [UIColor colorWithRed:0.08 green:0.08 blue:0.15 alpha:1.0];
    [btn setTitle:btn.selected ? @"🎯 Auto Aim: ON" : @"🎯 Auto Aim: OFF"
         forState:UIControlStateNormal];
    // Fire GBAuto via 80pool handle
    if (gHandle) {
        if (btn.selected) {
            void (*startFn)(void) = (void (*)(void))dlsym(gHandle, "GBAuto_OnPlayerTurn");
            if (startFn) startFn();
        } else {
            void (*stopFn)(void) = (void (*)(void))dlsym(gHandle, "GBAuto_Reset");
            if (stopFn) stopFn();
        }
    }
}

+ (void)onOverlay:(UIButton *)btn {
    btn.selected = !btn.selected;
    btn.backgroundColor = btn.selected
        ? [UIColor colorWithRed:0.0 green:0.4 blue:0.8 alpha:1.0]
        : [UIColor colorWithRed:0.08 green:0.08 blue:0.15 alpha:1.0];
    [btn setTitle:btn.selected ? @"👁 Overlay: ON" : @"👁 Overlay: OFF"
         forState:UIControlStateNormal];
    if (gHandle) {
        void (*overlayFn)(BOOL) = (void (*)(BOOL))dlsym(gHandle, "GBOverlaySetModUIHidden");
        if (overlayFn) overlayFn(!btn.selected);
    }
}

+ (void)onReset:(UIButton *)btn {
    if (gHandle) {
        void (*resetFn)(void) = (void (*)(void))dlsym(gHandle, "GBAuto_Reset");
        if (resetFn) resetFn();
    }
}

+ (void)onClose:(UIButton *)btn {
    toggleMenu();
}

@end

static void buildMenuView(void) {
    CGRect screen = [UIScreen mainScreen].bounds;
    CGFloat w = 260, h = 320;
    CGFloat x = (screen.size.width  - w) / 2;
    CGFloat y = (screen.size.height - h) / 2;

    menuView = [[UIView alloc] initWithFrame:CGRectMake(x, y, w, h)];
    menuView.backgroundColor    = [UIColor colorWithRed:0.05 green:0.05 blue:0.12 alpha:0.97];
    menuView.layer.cornerRadius = 18;
    menuView.layer.borderWidth  = 1.5;
    menuView.layer.borderColor  = [UIColor colorWithRed:0.0 green:0.8 blue:1.0 alpha:0.8].CGColor;
    menuView.layer.shadowColor  = [UIColor colorWithRed:0.0 green:0.8 blue:1.0 alpha:1.0].CGColor;
    menuView.layer.shadowOpacity= 0.6;
    menuView.layer.shadowRadius = 12;

    // Title
    UILabel *title = makeLabel(@"8Ball Unlimited", 12, 16, [UIColor colorWithRed:0.0 green:0.9 blue:1.0 alpha:1.0]);
    [menuView addSubview:title];

    // Subtitle
    UILabel *sub = makeLabel(@"Battery: ∞  |  Ads: None", 38, 11,
                              [UIColor colorWithRed:0.5 green:1.0 blue:0.7 alpha:1.0]);
    [menuView addSubview:sub];

    // Divider
    UIView *div = [[UIView alloc] initWithFrame:CGRectMake(15, 70, 230, 1)];
    div.backgroundColor = [UIColor colorWithRed:0.0 green:0.8 blue:1.0 alpha:0.3];
    [menuView addSubview:div];

    // Buttons
    UIButton *autoBtn    = makeButton(@"🎯 Auto Aim: OFF", 82,  @selector(onAutoAim:),  [GBUnlimitedMenu class]);
    UIButton *overlayBtn = makeButton(@"👁 Overlay: OFF",  132, @selector(onOverlay:),  [GBUnlimitedMenu class]);
    UIButton *resetBtn   = makeButton(@"🔄 Reset Bot",     182, @selector(onReset:),    [GBUnlimitedMenu class]);
    UIButton *closeBtn   = makeButton(@"✕ Close",          242, @selector(onClose:),    [GBUnlimitedMenu class]);

    closeBtn.backgroundColor = [UIColor colorWithRed:0.4 green:0.0 blue:0.0 alpha:1.0];
    closeBtn.layer.borderColor = [UIColor colorWithRed:1.0 green:0.2 blue:0.2 alpha:0.5].CGColor;

    [menuView addSubview:autoBtn];
    [menuView addSubview:overlayBtn];
    [menuView addSubview:resetBtn];
    [menuView addSubview:closeBtn];
}

static void toggleMenu(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!modWindow) {
            modWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
            modWindow.windowLevel    = UIWindowLevelAlert + 100;
            modWindow.backgroundColor= [UIColor clearColor];
            modWindow.rootViewController = [[UIViewController alloc] init];
            [modWindow makeKeyAndVisible];
            buildMenuView();
            [modWindow.rootViewController.view addSubview:menuView];
        }
        menuVisible = !menuVisible;
        menuView.hidden = !menuVisible;
        modWindow.hidden = !menuVisible;
    });
}

// ─── Floating Toggle Button ───────────────────────────────────────────────────
static UIWindow *floatWindow = nil;

static void spawnFloatButton(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        floatWindow = [[UIWindow alloc] initWithFrame:CGRectMake(10, 120, 50, 50)];
        floatWindow.windowLevel     = UIWindowLevelAlert + 200;
        floatWindow.backgroundColor = [UIColor clearColor];
        floatWindow.rootViewController = [[UIViewController alloc] init];
        [floatWindow makeKeyAndVisible];

        UIButton *fab = [UIButton buttonWithType:UIButtonTypeCustom];
        fab.frame           = CGRectMake(0, 0, 50, 50);
        fab.backgroundColor = [UIColor colorWithRed:0.0 green:0.8 blue:1.0 alpha:0.9];
        fab.layer.cornerRadius = 25;
        fab.layer.shadowColor   = [UIColor colorWithRed:0.0 green:0.8 blue:1.0 alpha:1.0].CGColor;
        fab.layer.shadowOpacity = 0.8;
        fab.layer.shadowRadius  = 8;
        [fab setTitle:@"8B" forState:UIControlStateNormal];
        fab.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        [fab setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
        [fab addTarget:[GBUnlimitedMenu class]
                action:@selector(onClose:)
      forControlEvents:UIControlEventTouchUpInside];

        // Tap to toggle
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
            initWithTarget:[NSBlockOperation blockOperationWithBlock:^{ toggleMenu(); }]
                    action:@selector(main)];
        [fab addGestureRecognizer:tap];

        [floatWindow.rootViewController.view addSubview:fab];
    });
}

// ─── Image finder ─────────────────────────────────────────────────────────────
static void *find80poolHandle(void) {
    uint32_t count = _dyld_image_count();
    uint32_t i;
    for (i = 0; i < count; i++) {
        const char *imgName = _dyld_get_image_name(i);
        if (imgName && strstr(imgName, "80pool")) {
            return dlopen(imgName, RTLD_NOLOAD | RTLD_LAZY);
        }
    }
    return NULL;
}

// ─── Hook installer ───────────────────────────────────────────────────────────
static void installHooks(void) {
    void *handle = find80poolHandle();
    if (!handle) return;
    gHandle = handle;

    void *symIsActive    = dlsym(handle, "GBModBatteryIsActive");
    void *symRemSec      = dlsym(handle, "GBModBatteryRemainingSeconds");
    void *symOnGrant     = dlsym(handle, "GBModBatteryOnGrant");
    void *symShowRew     = dlsym(handle, "GBModBatteryShowRewarded");
    void *symStoreActive = dlsym(handle, "GBModBatteryStoreIsActive");
    void *symStoreRem    = dlsym(handle, "GBModBatteryStoreRemainingSeconds");
    void *symStoreBoot   = dlsym(handle, "GBModBatteryStoreBootstrap");
    void *symStoreGrant  = dlsym(handle, "GBModBatteryStoreGrantFromReward");
    void *symBypass      = dlsym(handle, "GBLibloaderBypassInstall");

    if (symIsActive)    MSHookFunction(symIsActive,    (void *)hook_BatteryIsActive,        (void **)&orig_BatteryIsActive);
    if (symRemSec)      MSHookFunction(symRemSec,      (void *)hook_BatteryRemainingSeconds, (void **)&orig_BatteryRemainingSeconds);
    if (symOnGrant)     MSHookFunction(symOnGrant,     (void *)hook_BatteryOnGrant,          (void **)&orig_BatteryOnGrant);
    if (symShowRew)     MSHookFunction(symShowRew,     (void *)hook_BatteryShowRewarded,     (void **)&orig_BatteryShowRewarded);
    if (symStoreActive) MSHookFunction(symStoreActive, (void *)hook_StoreIsActive,           (void **)&orig_StoreIsActive);
    if (symStoreRem)    MSHookFunction(symStoreRem,    (void *)hook_StoreRemainingSeconds,   (void **)&orig_StoreRemainingSeconds);
    if (symStoreBoot)   MSHookFunction(symStoreBoot,   (void *)hook_StoreBootstrap,          (void **)&orig_StoreBootstrap);
    if (symStoreGrant)  MSHookFunction(symStoreGrant,  (void *)hook_StoreGrantFromReward,    (void **)&orig_StoreGrantFromReward);
    if (symBypass)      MSHookFunction(symBypass,      (void *)hook_LibloaderBypassInstall,  (void **)&orig_LibloaderBypassInstall);

    spawnFloatButton();
}

// ─── Constructor ──────────────────────────────────────────────────────────────
%ctor {
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{ installHooks(); }
    );
}

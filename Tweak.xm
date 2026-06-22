#include <substrate.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <limits.h>
#include <string.h>
#include <dispatch/dispatch.h>
#include <Foundation/Foundation.h>
#include <UIKit/UIKit.h>
#include <CoreGraphics/CoreGraphics.h>

// ─── State ────────────────────────────────────────────────────────────────────
static BOOL  autoAimEnabled  = NO;
static BOOL  overlayEnabled  = NO;
static void *gHandle         = NULL;
static UIWindow *floatWindow = nil;
static UIWindow *menuWindow  = nil;
static UIView   *menuView    = nil;
static BOOL      menuVisible = NO;

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

// ─── Battery Hooks ────────────────────────────────────────────────────────────
static BOOL hook_BatteryIsActive(void)         { return YES;     }
static int  hook_BatteryRemainingSeconds(void) { return INT_MAX; }
static BOOL hook_StoreIsActive(void)           { return YES;     }
static int  hook_StoreRemainingSeconds(void)   { return INT_MAX; }
static void hook_StoreGrantFromReward(void)    {                 }
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
    if (message && ([message containsString:@"unofficial app"] ||
                    [message containsString:@"8350:C7BE"])) return nil;
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

// ─── Auto Aim Hook ────────────────────────────────────────────────────────────
// Hook GBAuto_Tick — fires every frame, we intercept and fire GetSuggestedShot
static void (*orig_GBAuto_Tick)(void);
static void hook_GBAuto_Tick(void) {
    if (autoAimEnabled && gHandle) {
        void (*suggestFn)(void) = (void (*)(void))dlsym(gHandle, "GBAuto_GetSuggestedShot");
        if (suggestFn) suggestFn();
    }
    if (orig_GBAuto_Tick) orig_GBAuto_Tick();
}

// Hook GBAuto_OnPlayerTurn — fires when it's our turn
static void (*orig_GBAuto_OnPlayerTurn)(void);
static void hook_GBAuto_OnPlayerTurn(void) {
    if (autoAimEnabled && gHandle) {
        void (*primeFn)(void) = (void (*)(void))dlsym(gHandle, "GBAuto_PrimeForCurrentTurn");
        if (primeFn) primeFn();
    }
    if (orig_GBAuto_OnPlayerTurn) orig_GBAuto_OnPlayerTurn();
}

// ─── Overlay Hook ─────────────────────────────────────────────────────────────
static void (*orig_GBOverlaySetModUIHidden)(BOOL);
static void hook_GBOverlaySetModUIHidden(BOOL hidden) {
    // If overlay enabled, always force visible
    if (overlayEnabled) {
        if (orig_GBOverlaySetModUIHidden) orig_GBOverlaySetModUIHidden(NO);
    } else {
        if (orig_GBOverlaySetModUIHidden) orig_GBOverlaySetModUIHidden(hidden);
    }
}

// ─── UI Helpers ───────────────────────────────────────────────────────────────
static UIButton *activeAutoBtn    = nil;
static UIButton *activeOverlayBtn = nil;
static UILabel  *statusLabel      = nil;

static void updateStatus(void) {
    if (!statusLabel) return;
    statusLabel.text = [NSString stringWithFormat:@"Aim: %@ | Overlay: %@ | Battery: ∞",
                        autoAimEnabled  ? @"ON" : @"OFF",
                        overlayEnabled  ? @"ON" : @"OFF"];
}

static void toggleMenu(void);

@interface ModActions : NSObject
+ (void)tapAutoAim:(UIButton *)btn;
+ (void)tapOverlay:(UIButton *)btn;
+ (void)tapReset:(UIButton *)btn;
+ (void)tapClose:(UIButton *)btn;
+ (void)tapFloat:(UIButton *)btn;
@end

@implementation ModActions

+ (void)tapAutoAim:(UIButton *)btn {
    autoAimEnabled = !autoAimEnabled;
    btn.selected = autoAimEnabled;
    btn.backgroundColor = autoAimEnabled
        ? [UIColor colorWithRed:0.0  green:0.55 blue:0.27 alpha:1.0]
        : [UIColor colorWithRed:0.12 green:0.12 blue:0.20 alpha:1.0];
    [btn setTitle:autoAimEnabled ? @"🎯  Auto Aim   ON" : @"🎯  Auto Aim   OFF"
         forState:UIControlStateNormal];
    // Prime immediately if our turn
    if (autoAimEnabled && gHandle) {
        void (*primeFn)(void) = (void (*)(void))dlsym(gHandle, "GBAuto_PrimeForCurrentTurn");
        if (primeFn) primeFn();
    }
    updateStatus();
}

+ (void)tapOverlay:(UIButton *)btn {
    overlayEnabled = !overlayEnabled;
    btn.selected = overlayEnabled;
    btn.backgroundColor = overlayEnabled
        ? [UIColor colorWithRed:0.0  green:0.35 blue:0.75 alpha:1.0]
        : [UIColor colorWithRed:0.12 green:0.12 blue:0.20 alpha:1.0];
    [btn setTitle:overlayEnabled ? @"👁  Overlay     ON" : @"👁  Overlay     OFF"
         forState:UIControlStateNormal];
    if (gHandle) {
        void (*overlayFn)(BOOL) = (void (*)(BOOL))dlsym(gHandle, "GBOverlaySetModUIHidden");
        if (overlayFn) overlayFn(!overlayEnabled);
        if (overlayEnabled) {
            void (*startFn)(void) = (void (*)(void))dlsym(gHandle, "GBOverlayStartIfNeeded");
            if (startFn) startFn();
        }
    }
    updateStatus();
}

+ (void)tapReset:(UIButton *)btn {
    autoAimEnabled = NO;
    overlayEnabled = NO;
    if (activeAutoBtn) {
        activeAutoBtn.selected = NO;
        activeAutoBtn.backgroundColor = [UIColor colorWithRed:0.12 green:0.12 blue:0.20 alpha:1.0];
        [activeAutoBtn setTitle:@"🎯  Auto Aim   OFF" forState:UIControlStateNormal];
    }
    if (activeOverlayBtn) {
        activeOverlayBtn.selected = NO;
        activeOverlayBtn.backgroundColor = [UIColor colorWithRed:0.12 green:0.12 blue:0.20 alpha:1.0];
        [activeOverlayBtn setTitle:@"👁  Overlay     OFF" forState:UIControlStateNormal];
    }
    if (gHandle) {
        void (*resetFn)(void) = (void (*)(void))dlsym(gHandle, "GBAuto_Reset");
        if (resetFn) resetFn();
        void (*clearFn)(void) = (void (*)(void))dlsym(gHandle, "GBOverlayClearPrediction");
        if (clearFn) clearFn();
    }
    updateStatus();
}

+ (void)tapClose:(UIButton *)btn {
    toggleMenu();
}

+ (void)tapFloat:(UIButton *)btn {
    toggleMenu();
}

@end

// ─── Menu Builder ─────────────────────────────────────────────────────────────
static UIButton *styledButton(NSString *title, CGFloat y, SEL sel) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(14, y, 242, 44);
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font       = [UIFont boldSystemFontOfSize:13];
    b.backgroundColor       = [UIColor colorWithRed:0.12 green:0.12 blue:0.20 alpha:1.0];
    b.layer.cornerRadius    = 11;
    b.layer.borderWidth     = 1.0;
    b.layer.borderColor     = [UIColor colorWithRed:0.0 green:0.75 blue:1.0 alpha:0.5].CGColor;
    b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    b.titleEdgeInsets       = UIEdgeInsetsMake(0, 14, 0, 0);
    [b addTarget:[ModActions class] action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

static void buildMenu(void) {
    CGRect sc = [UIScreen mainScreen].bounds;
    CGFloat w = 270, h = 370;
    menuView = [[UIView alloc] initWithFrame:CGRectMake(
        (sc.size.width - w) / 2,
        (sc.size.height - h) / 2,
        w, h)];
    menuView.backgroundColor    = [UIColor colorWithRed:0.04 green:0.04 blue:0.10 alpha:0.97];
    menuView.layer.cornerRadius = 20;
    menuView.layer.borderWidth  = 1.5;
    menuView.layer.borderColor  = [UIColor colorWithRed:0.0 green:0.75 blue:1.0 alpha:0.9].CGColor;
    menuView.layer.shadowColor  = [UIColor colorWithRed:0.0 green:0.75 blue:1.0 alpha:1.0].CGColor;
    menuView.layer.shadowOpacity= 0.7;
    menuView.layer.shadowRadius = 16;

    // Title
    UILabel *ttl = [[UILabel alloc] initWithFrame:CGRectMake(0, 14, w, 24)];
    ttl.text          = @"8Ball Unlimited";
    ttl.textColor     = [UIColor colorWithRed:0.0 green:0.85 blue:1.0 alpha:1.0];
    ttl.font          = [UIFont boldSystemFontOfSize:17];
    ttl.textAlignment = NSTextAlignmentCenter;
    [menuView addSubview:ttl];

    // Status
    statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 42, w, 18)];
    statusLabel.text          = @"Aim: OFF | Overlay: OFF | Battery: ∞";
    statusLabel.textColor     = [UIColor colorWithRed:0.4 green:1.0 blue:0.6 alpha:1.0];
    statusLabel.font          = [UIFont systemFontOfSize:10];
    statusLabel.textAlignment = NSTextAlignmentCenter;
    [menuView addSubview:statusLabel];

    // Divider
    UIView *div = [[UIView alloc] initWithFrame:CGRectMake(14, 66, 242, 1)];
    div.backgroundColor = [UIColor colorWithRed:0.0 green:0.75 blue:1.0 alpha:0.25];
    [menuView addSubview:div];

    // Buttons
    UIButton *autoBtn    = styledButton(@"🎯  Auto Aim   OFF", 76,  @selector(tapAutoAim:));
    UIButton *overlayBtn = styledButton(@"👁  Overlay     OFF", 130, @selector(tapOverlay:));
    UIButton *resetBtn   = styledButton(@"🔄  Reset All",       184, @selector(tapReset:));
    UIButton *closeBtn   = styledButton(@"✕   Close Menu",      238, @selector(tapClose:));

    closeBtn.backgroundColor = [UIColor colorWithRed:0.35 green:0.0 blue:0.0 alpha:1.0];
    closeBtn.layer.borderColor = [UIColor colorWithRed:1.0 green:0.2 blue:0.2 alpha:0.5].CGColor;

    // Battery info row
    UILabel *battLbl = [[UILabel alloc] initWithFrame:CGRectMake(0, 296, w, 18)];
    battLbl.text          = @"⚡ Battery: Unlimited  •  Ads: Removed";
    battLbl.textColor     = [UIColor colorWithRed:0.5 green:1.0 blue:0.5 alpha:0.8];
    battLbl.font          = [UIFont systemFontOfSize:10];
    battLbl.textAlignment = NSTextAlignmentCenter;
    [menuView addSubview:battLbl];

    UILabel *ver = [[UILabel alloc] initWithFrame:CGRectMake(0, 344, w, 16)];
    ver.text          = @"v1.0 — by axiom";
    ver.textColor     = [UIColor colorWithRed:0.3 green:0.3 blue:0.4 alpha:1.0];
    ver.font          = [UIFont systemFontOfSize:9];
    ver.textAlignment = NSTextAlignmentCenter;
    [menuView addSubview:ver];

    [menuView addSubview:autoBtn];
    [menuView addSubview:overlayBtn];
    [menuView addSubview:resetBtn];
    [menuView addSubview:closeBtn];

    activeAutoBtn    = autoBtn;
    activeOverlayBtn = overlayBtn;
}

static void toggleMenu(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!menuWindow) {
            menuWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
            menuWindow.windowLevel = UIWindowLevelAlert + 100;
            menuWindow.backgroundColor = [UIColor clearColor];
            menuWindow.rootViewController = [[UIViewController alloc] init];
            [menuWindow makeKeyAndVisible];
            buildMenu();
            [menuWindow.rootViewController.view addSubview:menuView];
        }
        menuVisible = !menuVisible;
        menuView.hidden   = !menuVisible;
        menuWindow.hidden = !menuVisible;
    });
}

// ─── Floating Button ──────────────────────────────────────────────────────────
static void spawnFloatButton(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        floatWindow = [[UIWindow alloc] initWithFrame:CGRectMake(10, 160, 52, 52)];
        floatWindow.windowLevel = UIWindowLevelAlert + 200;
        floatWindow.backgroundColor = [UIColor clearColor];
        floatWindow.rootViewController = [[UIViewController alloc] init];
        [floatWindow makeKeyAndVisible];

        UIButton *fab = [UIButton buttonWithType:UIButtonTypeCustom];
        fab.frame = CGRectMake(0, 0, 52, 52);
        fab.backgroundColor = [UIColor colorWithRed:0.0 green:0.75 blue:1.0 alpha:0.92];
        fab.layer.cornerRadius  = 26;
        fab.layer.shadowColor   = [UIColor colorWithRed:0.0 green:0.75 blue:1.0 alpha:1.0].CGColor;
        fab.layer.shadowOpacity = 0.9;
        fab.layer.shadowRadius  = 10;
        [fab setTitle:@"8B" forState:UIControlStateNormal];
        [fab setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
        fab.titleLabel.font = [UIFont boldSystemFontOfSize:15];
        [fab addTarget:[ModActions class]
                action:@selector(tapFloat:)
      forControlEvents:UIControlEventTouchUpInside];

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
    void *symTick        = dlsym(handle, "GBAuto_Tick");
    void *symPlayerTurn  = dlsym(handle, "GBAuto_OnPlayerTurn");
    void *symOverlay     = dlsym(handle, "GBOverlaySetModUIHidden");

    if (symIsActive)    MSHookFunction(symIsActive,    (void *)hook_BatteryIsActive,        (void **)&orig_BatteryIsActive);
    if (symRemSec)      MSHookFunction(symRemSec,      (void *)hook_BatteryRemainingSeconds, (void **)&orig_BatteryRemainingSeconds);
    if (symOnGrant)     MSHookFunction(symOnGrant,     (void *)hook_BatteryOnGrant,          (void **)&orig_BatteryOnGrant);
    if (symShowRew)     MSHookFunction(symShowRew,     (void *)hook_BatteryShowRewarded,     (void **)&orig_BatteryShowRewarded);
    if (symStoreActive) MSHookFunction(symStoreActive, (void *)hook_StoreIsActive,           (void **)&orig_StoreIsActive);
    if (symStoreRem)    MSHookFunction(symStoreRem,    (void *)hook_StoreRemainingSeconds,   (void **)&orig_StoreRemainingSeconds);
    if (symStoreBoot)   MSHookFunction(symStoreBoot,   (void *)hook_StoreBootstrap,          (void **)&orig_StoreBootstrap);
    if (symStoreGrant)  MSHookFunction(symStoreGrant,  (void *)hook_StoreGrantFromReward,    (void **)&orig_StoreGrantFromReward);
    if (symBypass)      MSHookFunction(symBypass,      (void *)hook_LibloaderBypassInstall,  (void **)&orig_LibloaderBypassInstall);
    if (symTick)        MSHookFunction(symTick,        (void *)hook_GBAuto_Tick,             (void **)&orig_GBAuto_Tick);
    if (symPlayerTurn)  MSHookFunction(symPlayerTurn,  (void *)hook_GBAuto_OnPlayerTurn,     (void **)&orig_GBAuto_OnPlayerTurn);
    if (symOverlay)     MSHookFunction(symOverlay,     (void *)hook_GBOverlaySetModUIHidden, (void **)&orig_GBOverlaySetModUIHidden);

    spawnFloatButton();
}

// ─── Constructor ──────────────────────────────────────────────────────────────
%ctor {
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{ installHooks(); }
    );
}

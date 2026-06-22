#include <substrate.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <limits.h>
#include <string.h>
#include <dispatch/dispatch.h>
#include <Foundation/Foundation.h>
#include <UIKit/UIKit.h>

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

// ─── Bypass Hooks ─────────────────────────────────────────────────────────────
static void hook_LibloaderBypassInstall(void) {
    if (orig_LibloaderBypassInstall) orig_LibloaderBypassInstall();
}
static void hook_AppStoreCheck(void) { }

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

    // Battery gate
    void *symIsActive    = dlsym(handle, "GBModBatteryIsActive");
    void *symRemSec      = dlsym(handle, "GBModBatteryRemainingSeconds");
    void *symOnGrant     = dlsym(handle, "GBModBatteryOnGrant");
    void *symShowRew     = dlsym(handle, "GBModBatteryShowRewarded");
    void *symStoreActive = dlsym(handle, "GBModBatteryStoreIsActive");
    void *symStoreRem    = dlsym(handle, "GBModBatteryStoreRemainingSeconds");
    void *symStoreBoot   = dlsym(handle, "GBModBatteryStoreBootstrap");
    void *symStoreGrant  = dlsym(handle, "GBModBatteryStoreGrantFromReward");

    // Bypass + spoof + sideload check
    void *symBypass      = dlsym(handle, "GBLibloaderBypassInstall");
    void *symSpoof       = dlsym(handle, "GBPlistSpoofInstall");

    if (symIsActive)    MSHookFunction(symIsActive,    (void *)hook_BatteryIsActive,        (void **)&orig_BatteryIsActive);
    if (symRemSec)      MSHookFunction(symRemSec,      (void *)hook_BatteryRemainingSeconds, (void **)&orig_BatteryRemainingSeconds);
    if (symOnGrant)     MSHookFunction(symOnGrant,     (void *)hook_BatteryOnGrant,          (void **)&orig_BatteryOnGrant);
    if (symShowRew)     MSHookFunction(symShowRew,     (void *)hook_BatteryShowRewarded,     (void **)&orig_BatteryShowRewarded);
    if (symStoreActive) MSHookFunction(symStoreActive, (void *)hook_StoreIsActive,           (void **)&orig_StoreIsActive);
    if (symStoreRem)    MSHookFunction(symStoreRem,    (void *)hook_StoreRemainingSeconds,   (void **)&orig_StoreRemainingSeconds);
    if (symStoreBoot)   MSHookFunction(symStoreBoot,   (void *)hook_StoreBootstrap,          (void **)&orig_StoreBootstrap);
    if (symStoreGrant)  MSHookFunction(symStoreGrant,  (void *)hook_StoreGrantFromReward,    (void **)&orig_StoreGrantFromReward);
    if (symBypass)      MSHookFunction(symBypass,      (void *)hook_LibloaderBypassInstall,  (void **)&orig_LibloaderBypassInstall);
    if (symSpoof)       MSHookFunction(symSpoof,       (void *)hook_AppStoreCheck,           (void **)&orig_AppStoreCheck);

    dlclose(handle);
}

// ─── Constructor ──────────────────────────────────────────────────────────────
%ctor {
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{ installHooks(); }
    );
}

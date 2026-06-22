#include <substrate.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <limits.h>
#include <string.h>
#include <dispatch/dispatch.h>
#include <Foundation/Foundation.h>

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
static void (*orig_PlistSpoofInstall)(void);

// ─── Battery Hooks ────────────────────────────────────────────────────────────
// 0x10ad9c
static BOOL hook_BatteryIsActive(void)         { return YES;     }
// 0x10ada0
static int  hook_BatteryRemainingSeconds(void) { return INT_MAX; }
// 0x10da4c
static BOOL hook_StoreIsActive(void)           { return YES;     }
// 0x10db24
static int  hook_StoreRemainingSeconds(void)   { return INT_MAX; }
// 0x10dbf8
static void hook_StoreGrantFromReward(void)    {                 }

// 0x10d4a8
static void hook_StoreBootstrap(void) {
    if (orig_StoreBootstrap) orig_StoreBootstrap();
}
// 0x10ada4
static void hook_BatteryOnGrant(void) {
    if (orig_BatteryOnGrant) orig_BatteryOnGrant();
}
// 0x10add0 — skip ad, fire grant directly
static void hook_BatteryShowRewarded(void) {
    void (*grantFn)(void) = orig_BatteryOnGrant;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (grantFn) grantFn();
    });
}

// ─── Bypass Hooks ─────────────────────────────────────────────────────────────
// 0x63018 — let bypass install run normally, it's our friend
static void hook_LibloaderBypassInstall(void) {
    if (orig_LibloaderBypassInstall) orig_LibloaderBypassInstall();
}
// 0x10ea38 — let plist spoof run normally
static void hook_PlistSpoofInstall(void) {
    if (orig_PlistSpoofInstall) orig_PlistSpoofInstall();
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

    // Battery gate
    void *symIsActive    = dlsym(handle, "GBModBatteryIsActive");
    void *symRemSec      = dlsym(handle, "GBModBatteryRemainingSeconds");
    void *symOnGrant     = dlsym(handle, "GBModBatteryOnGrant");
    void *symShowRew     = dlsym(handle, "GBModBatteryShowRewarded");
    void *symStoreActive = dlsym(handle, "GBModBatteryStoreIsActive");
    void *symStoreRem    = dlsym(handle, "GBModBatteryStoreRemainingSeconds");
    void *symStoreBoot   = dlsym(handle, "GBModBatteryStoreBootstrap");
    void *symStoreGrant  = dlsym(handle, "GBModBatteryStoreGrantFromReward");

    // Bypass + spoof
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
    if (symSpoof)       MSHookFunction(symSpoof,       (void *)hook_PlistSpoofInstall,       (void **)&orig_PlistSpoofInstall);

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

// Add this to your existing Tweak.xm installHooks()

static void (*orig_AppStoreCheck)(void);
static BOOL (*orig_IsValidInstall)(void);
static BOOL (*orig_IsFromAppStore)(void);

// Kill the "cannot be installed from unofficial app stores" check
static void hook_AppStoreCheck(void)    {                }
static BOOL hook_IsValidInstall(void)   { return YES;    }
static BOOL hook_IsFromAppStore(void)   { return YES;    }

// Hook NSBundle receipt validation — this is what triggers REF: 6902
%hook NSBundle
- (NSURL *)appStoreReceiptURL {
    // Return a fake path that passes existence check
    return [NSURL fileURLWithPath:@"/private/var/mobile/Containers/Bundle/Application/receipt"];
}
%end

// Hook the actual Miniclip integrity alert
%hook UIAlertController
+ (instancetype)alertControllerWithTitle:(NSString *)title
                                 message:(NSString *)message
                          preferredStyle:(UIAlertControllerStyle)style {
    // Swallow the sideload detection popup
    if (message && [message containsString:@"unofficial app"]) {
        return nil;
    }
    if (message && [message containsString:@"8350:C7BE"]) {
        return nil;
    }
    return %orig;
}
%end

// Hook SecStaticCodeCheckValidity — the system call behind REF 6902
%hook NSFileManager
- (BOOL)fileExistsAtPath:(NSString *)path {
    // Fake the receipt file exists
    if ([path containsString:@"StoreKit"] ||
        [path containsString:@"receipt"]) {
        return YES;
    }
    return %orig;
}
%end


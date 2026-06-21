// Tweak.xm — ONLY battery gate removed. Zero other changes.

#import <substrate.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>

// ─── Originals ────────────────────────────────────────────────────────────────
static BOOL (*orig_BatteryIsActive)(void);
static int  (*orig_BatteryRemainingSeconds)(void);
static void (*orig_BatteryOnGrant)(void);
static void (*orig_BatteryShowRewarded)(void);
static BOOL (*orig_StoreIsActive)(void);
static int  (*orig_StoreRemainingSeconds)(void);
static void (*orig_StoreBootstrap)(void);
static void (*orig_StoreGrantFromReward)(void);

// ─── Hooks ────────────────────────────────────────────────────────────────────
static BOOL hook_BatteryIsActive(void)          { return YES;      }
static int  hook_BatteryRemainingSeconds(void)  { return INT_MAX;  }
static BOOL hook_StoreIsActive(void)            { return YES;      }
static int  hook_StoreRemainingSeconds(void)    { return INT_MAX;  }
static void hook_StoreGrantFromReward(void)     { /* no-op */      }

static void hook_StoreBootstrap(void) {
    if (orig_StoreBootstrap) orig_StoreBootstrap();
}

static void hook_BatteryOnGrant(void) {
    if (orig_BatteryOnGrant) orig_BatteryOnGrant();
}

// Skip ad, fire grant callback directly
static void hook_BatteryShowRewarded(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (orig_BatteryOnGrant) orig_BatteryOnGrant();
    });
}

// ─── Constructor ──────────────────────────────────────────────────────────────
%ctor {
    @autoreleasepool {
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{

            void *handle = NULL;
            uint32_t count = _dyld_image_count();
            for (uint32_t i = 0; i < count; i++) {
                const char *name = _dyld_get_image_name(i);
                if (name && strstr(name, "80pool")) {
                    handle = dlopen(name, RTLD_NOLOAD | RTLD_LAZY);
                    break;
                }
            }

            if (!handle) {
                NSLog(@"[80pool-patch] image not found");
                return;
            }

            #define HOOK(sym, hookfn, origptr) {                          \
                void *_s = dlsym(handle, sym);                            \
                if (_s) MSHookFunction(_s,(void*)hookfn,(void**)origptr); \
            }

            HOOK("GBModBatteryIsActive",             hook_BatteryIsActive,        &orig_BatteryIsActive)
            HOOK("GBModBatteryRemainingSeconds",      hook_BatteryRemainingSeconds, &orig_BatteryRemainingSeconds)
            HOOK("GBModBatteryOnGrant",               hook_BatteryOnGrant,         &orig_BatteryOnGrant)
            HOOK("GBModBatteryShowRewarded",          hook_BatteryShowRewarded,    &orig_BatteryShowRewarded)
            HOOK("GBModBatteryStoreIsActive",         hook_StoreIsActive,          &orig_StoreIsActive)
            HOOK("GBModBatteryStoreRemainingSeconds", hook_StoreRemainingSeconds,  &orig_StoreRemainingSeconds)
            HOOK("GBModBatteryStoreBootstrap",        hook_StoreBootstrap,         &orig_StoreBootstrap)
            HOOK("GBModBatteryStoreGrantFromReward",  hook_StoreGrantFromReward,   &orig_StoreGrantFromReward)

            #undef HOOK
            dlclose(handle);

            NSLog(@"[80pool-patch] battery hooks live — unlimited, no ads");
        });
    }
}

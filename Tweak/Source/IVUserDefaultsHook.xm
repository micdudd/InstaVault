#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "IVContainerManager.h"
#import "IVContainer.h"

// Per-container NSUserDefaults isolation.
//
// FIX (stack overflow on Activate):
// The previous version created a new NSUserDefaults inside the hooks and then
// called -objectForKey: / -setObject:forKey: on it. Those calls go through the
// same swizzled methods, which created another instance and called again ->
// infinite recursion. Now:
//   1. a per-thread re-entrancy guard (gInHook) protects every hook, including
//      the [IVContainerManager shared].active lookup, and
//   2. the container's defaults object is created, read and written through the
//      ORIGINAL implementations only, so it can never re-enter a hook.

static __thread BOOL gInHook = NO;

static IMP orig_standardUserDefaults;
static IMP orig_initWithSuiteName;
static IMP orig_objectForKey;
static IMP orig_setObject;

// Cached per-container defaults, built with the original init (no hook involved).
static NSUserDefaults *IVContainerDefaults(NSString *cid) {
    static NSMutableDictionary<NSString *, NSUserDefaults *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    @synchronized (cache) {
        NSUserDefaults *ud = cache[cid];
        if (!ud && orig_initWithSuiteName) {
            NSString *suite = [@"InstaVault." stringByAppendingString:cid];
            ud = ((id (*)(id, SEL, NSString *))orig_initWithSuiteName)(
                    [NSUserDefaults alloc], @selector(initWithSuiteName:), suite);
            if (ud) cache[cid] = ud;
        }
        return ud;
    }
}

// MUST be called with gInHook == YES.
static NSString *IVActiveCID(void) {
    IVContainer *active = [IVContainerManager shared].active;
    NSString *cid = active.cid;
    return cid.length ? cid : nil;
}

static id hooked_standardUserDefaults(id self, SEL _cmd) {
    if (!gInHook) {
        gInHook = YES;
        NSString *cid = IVActiveCID();
        NSUserDefaults *ud = cid ? IVContainerDefaults(cid) : nil;
        gInHook = NO;
        if (ud) return ud;
    }
    return ((id (*)(id, SEL))orig_standardUserDefaults)(self, _cmd);
}

static id hooked_initWithSuiteName(id self, SEL _cmd, NSString *suiteName) {
    NSString *suite = suiteName;
    if (!gInHook) {
        gInHook = YES;
        NSString *cid = IVActiveCID();
        gInHook = NO;
        if (cid) suite = [@"InstaVault." stringByAppendingString:cid];
    }
    return ((id (*)(id, SEL, NSString *))orig_initWithSuiteName)(self, _cmd, suite);
}

static id hooked_objectForKey(id self, SEL _cmd, NSString *key) {
    if (!gInHook) {
        gInHook = YES;
        NSString *cid = IVActiveCID();
        NSUserDefaults *c = cid ? IVContainerDefaults(cid) : nil;
        id result = nil;
        BOOL handled = NO;
        if (c) {
            // Original implementation on the container object: no re-entry.
            result = ((id (*)(id, SEL, NSString *))orig_objectForKey)(c, _cmd, key);
            handled = YES;
        }
        gInHook = NO;
        if (handled) return result;
    }
    return ((id (*)(id, SEL, NSString *))orig_objectForKey)(self, _cmd, key);
}

static void hooked_setObject(id self, SEL _cmd, id value, NSString *key) {
    if (!gInHook) {
        gInHook = YES;
        NSString *cid = IVActiveCID();
        NSUserDefaults *c = cid ? IVContainerDefaults(cid) : nil;
        BOOL handled = NO;
        if (c) {
            ((void (*)(id, SEL, id, NSString *))orig_setObject)(c, _cmd, value, key);
            handled = YES;
        }
        gInHook = NO;
        if (handled) return;
    }
    ((void (*)(id, SEL, id, NSString *))orig_setObject)(self, _cmd, value, key);
}

__attribute__((constructor))
static void IVInstallUserDefaultsHook(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class ud = objc_getClass("NSUserDefaults");
        if (!ud) return;

        // initWithSuiteName: first: IVContainerDefaults() needs its original.
        // method_setImplementation returns the previous IMP atomically.
        Method m_init = class_getInstanceMethod(ud, @selector(initWithSuiteName:));
        if (m_init) orig_initWithSuiteName = method_setImplementation(m_init, (IMP)hooked_initWithSuiteName);

        Method m_std = class_getClassMethod(ud, @selector(standardUserDefaults));
        if (m_std) orig_standardUserDefaults = method_setImplementation(m_std, (IMP)hooked_standardUserDefaults);

        Method m_get = class_getInstanceMethod(ud, @selector(objectForKey:));
        if (m_get) orig_objectForKey = method_setImplementation(m_get, (IMP)hooked_objectForKey);

        Method m_set = class_getInstanceMethod(ud, @selector(setObject:forKey:));
        if (m_set) orig_setObject = method_setImplementation(m_set, (IMP)hooked_setObject);

        NSLog(@"[InstaVault] NSUserDefaults hooks installed");
    });
}

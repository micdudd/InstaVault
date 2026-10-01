#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <AdSupport/AdSupport.h>
#import "IVDeviceSpoofing.h"
#import "IVFakeDevice.h"

// IDFV (identifierForVendor) and IDFA (advertisingIdentifier) spoofing.
//
// FIX (SIGABRT / unrecognized selector in IGDeviceID):
// Both of these Apple APIs return NSUUID, NOT NSString. The previous hooks
// returned the stored NSString directly, so Instagram's code calling
// -[... UUIDString] on the result threw "unrecognized selector". We now
// convert the stored string to an NSUUID, and fall back to the real value if
// the string is missing or not a valid UUID.

static IMP orig_idfv;
static NSUUID *hooked_idfv(id self, SEL _cmd) {
    IVDeviceSpoofing *sp = [IVDeviceSpoofing shared];
    if (sp.on && sp.dev.idfv.length) {
        NSUUID *u = [[NSUUID alloc] initWithUUIDString:sp.dev.idfv];
        if (u) return u;
    }
    return ((NSUUID *(*)(id, SEL))orig_idfv)(self, _cmd);
}

static IMP orig_idfa;
static NSUUID *hooked_idfa(id self, SEL _cmd) {
    IVDeviceSpoofing *sp = [IVDeviceSpoofing shared];
    if (sp.on && sp.dev.idfa.length) {
        NSUUID *u = [[NSUUID alloc] initWithUUIDString:sp.dev.idfa];
        if (u) return u;
    }
    return ((NSUUID *(*)(id, SEL))orig_idfa)(self, _cmd);
}

__attribute__((constructor))
static void IVInstallIdentifierHook(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class uidd = objc_getClass("UIDevice");
        if (uidd) {
            Method m = class_getInstanceMethod(uidd, @selector(identifierForVendor));
            if (m) orig_idfv = method_setImplementation(m, (IMP)hooked_idfv);
        }

        Class as = objc_getClass("ASIdentifierManager");
        if (as) {
            Method m = class_getInstanceMethod(as, @selector(advertisingIdentifier));
            if (m) orig_idfa = method_setImplementation(m, (IMP)hooked_idfa);
        }

        NSLog(@"[InstaVault] IDFV/IDFA hooks installed");
    });
}

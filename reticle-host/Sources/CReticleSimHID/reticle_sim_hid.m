#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <malloc/malloc.h>
#import <dlfcn.h>
#import "reticle_sim_hid.h"

// Private CoreSimulator/SimulatorKit HID input for the iOS simulator.
//
// History: an earlier revision hand-built an Indigo touch message from
// `IndigoHIDMessageForMouseNSEvent` and delivered it over a mach send right
// pulled out of the SimDeviceIO port graph. That path links and sends without
// error on iOS 26.3+, but the synthesized touch is silently dropped (or
// misread as a Home gesture) — the frameworks stopped routing bare mouse-event
// Indigo messages to the digitizer. Verified against a real baguette-driven tap
// that DID land on the same control, so the runtime supports HID; our message
// shape and delivery were wrong.
//
// Current recipe (reverse-engineered from Xcode 26 SimulatorKit; the same one
// baguette uses, verified on iOS 26.3/26.4):
//
//   1. Deliver through `SimDeviceLegacyHIDClient` (the Swift class
//      `_TtC12SimulatorKit24SimDeviceLegacyHIDClient`) via
//      `-sendWithMessage:freeWhenDone:completionQueue:completion:`, NOT a raw
//      mach_msg. Warm the client once by creating the pointer + mouse services.
//   2. Build a real `IOHIDEvent` digitizer parent with a finger child appended
//      (`IOHIDEventCreateDigitizerEvent` + `IOHIDEventCreateDigitizerFingerEvent`
//      + `IOHIDEventAppendEvent`) — iOS touches always arrive as parent+child.
//   3. Wrap it through `IndigoHIDMessageForTrackpadEventFromHIDEventRef` (the one
//      *FromHIDEventRef wrapper that accepts digitizer events), then patch two
//      byte slots the wrapper leaves zeroed: the touch-target tag (0x32) at
//      0x6c/0x10c, and the edge bitmask at 0x3a/0x3b (0 for interior touches).
//   4. Keyboard goes through `IndigoHIDMessageForHIDArbitrary(target,page,usage,op)`.
//
// Everything is resolved dynamically so this links on any Xcode and degrades to
// a clear error when a symbol/class is absent. Simulator-only; fragile by nature.

typedef CFTypeRef (*CreateDigitizerFn)(CFAllocatorRef, uint64_t, uint32_t,
                                       uint32_t, uint32_t, uint32_t, uint32_t,
                                       double, double, double, double, double,
                                       bool, bool, uint32_t);
typedef CFTypeRef (*CreateFingerFn)(CFAllocatorRef, uint64_t,
                                    uint32_t, uint32_t, uint32_t,
                                    double, double, double, double, double,
                                    bool, bool, uint32_t);
typedef void  (*AppendEventFn)(CFTypeRef, CFTypeRef, uint32_t);
typedef void *(*TrackpadWrapFn)(const void *);
typedef void *(*ServiceFn)(void);
typedef void *(*HIDArbitraryFn)(uint32_t, uint32_t, uint32_t, uint32_t);
typedef id (*MsgSendCtx)(id, SEL, NSString *, NSError **);
typedef id (*MsgSendErr)(id, SEL, NSError **);
typedef id (*MsgSendPlain)(id, SEL);
typedef id (*MsgSendInitDev)(id, SEL, id, NSError **);
// -sendWithMessage:freeWhenDone:completionQueue:completion:
typedef void (*MsgSendHID)(id, SEL, void *, BOOL, id, id);

// Touch-target tag iOS reads to route the event to the digitizer subsystem.
static const uint32_t kTouchTarget = 0x32;
// kIOHIDDigitizerTransducerTypeFinger.
static const uint32_t kTransducerFinger = 2;

static void set_err(char *err, size_t errlen, NSString *msg) {
    if (err && errlen > 0) { strncpy(err, msg.UTF8String ?: "unknown error", errlen - 1); err[errlen - 1] = '\0'; }
}

static NSString *developer_dir(void) {
    NSString *dev = NSProcessInfo.processInfo.environment[@"DEVELOPER_DIR"];
    if (dev.length) return dev;
    FILE *fp = popen("/usr/bin/xcode-select -p 2>/dev/null", "r");
    if (fp) {
        char buf[1024]; NSMutableString *out = [NSMutableString string]; size_t n;
        while ((n = fread(buf, 1, sizeof(buf), fp)) > 0) [out appendString:[[NSString alloc] initWithBytes:buf length:n encoding:NSUTF8StringEncoding]];
        pclose(fp);
        NSString *t = [out stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (t.length) return t;
    }
    return @"/Applications/Xcode.app/Contents/Developer";
}

// Resolved symbols, cached process-wide (write-once on first use).
static CreateDigitizerFn gCreateDigitizer = NULL;
static CreateFingerFn    gCreateFinger    = NULL;
static AppendEventFn     gAppendEvent     = NULL;
static TrackpadWrapFn    gTrackpadWrap    = NULL;
static HIDArbitraryFn    gHidArbitrary    = NULL;
static ServiceFn         gCreatePointerSvc = NULL;
static ServiceFn         gCreateMouseSvc   = NULL;

static void *load_simkit(NSString **reason) {
    static void *simkit = NULL;
    if (simkit) return simkit;
    NSString *dev = developer_dir();
    // IOKit provides the IOHIDEvent* constructors; pull it in explicitly so the
    // symbols are present regardless of what the host process already linked.
    dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    for (NSString *p in @[[dev stringByAppendingString:@"/Library/PrivateFrameworks/CoreSimulator.framework/CoreSimulator"],
                          @"/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator"]) {
        dlopen(p.fileSystemRepresentation, RTLD_NOW);
    }
    void *h = dlopen([[dev stringByAppendingString:@"/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit"] fileSystemRepresentation], RTLD_NOW);
    if (!h) { if (reason) *reason = @"cannot dlopen SimulatorKit"; return NULL; }
    simkit = h; return simkit;
}

// Resolve the IOHIDEvent constructors + the SimulatorKit Indigo builders once.
static int resolve_symbols(NSString **reason) {
    static int resolved = 0;
    if (resolved) return 0;
    void *kit = load_simkit(reason);
    if (!kit) return 1;
    gCreateDigitizer  = (CreateDigitizerFn)dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerEvent");
    gCreateFinger     = (CreateFingerFn)dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerFingerEvent");
    gAppendEvent      = (AppendEventFn)dlsym(RTLD_DEFAULT, "IOHIDEventAppendEvent");
    gTrackpadWrap     = (TrackpadWrapFn)dlsym(kit, "IndigoHIDMessageForTrackpadEventFromHIDEventRef");
    gHidArbitrary     = (HIDArbitraryFn)dlsym(kit, "IndigoHIDMessageForHIDArbitrary");
    gCreatePointerSvc = (ServiceFn)dlsym(kit, "IndigoHIDMessageToCreatePointerService");
    gCreateMouseSvc   = (ServiceFn)dlsym(kit, "IndigoHIDMessageToCreateMouseService");
    if (!gCreateDigitizer || !gCreateFinger || !gAppendEvent) {
        if (reason) *reason = @"IOHIDEventCreateDigitizer* not found (IOKit)"; return 10;
    }
    if (!gTrackpadWrap) {
        if (reason) *reason = @"IndigoHIDMessageForTrackpadEventFromHIDEventRef not found"; return 11;
    }
    resolved = 1;
    return 0;
}

static id device_for_udid(NSString *udid, NSString **reason) {
    Class ctxClass = NSClassFromString(@"SimServiceContext");
    if (!ctxClass) { if (reason) *reason = @"SimServiceContext not found"; return nil; }
    NSError *err = nil;
    id ctx = ((MsgSendCtx)objc_msgSend)((id)ctxClass, NSSelectorFromString(@"sharedServiceContextForDeveloperDir:error:"), developer_dir(), &err);
    if (!ctx) { if (reason) *reason = [NSString stringWithFormat:@"no service context: %@", err]; return nil; }
    id set = ((MsgSendErr)objc_msgSend)(ctx, NSSelectorFromString(@"defaultDeviceSetWithError:"), &err);
    if (!set) { if (reason) *reason = [NSString stringWithFormat:@"no device set: %@", err]; return nil; }
    NSArray *devices = ((MsgSendPlain)objc_msgSend)(set, NSSelectorFromString(@"devices"));
    for (id d in devices) {
        id uuid = ((MsgSendPlain)objc_msgSend)(d, NSSelectorFromString(@"UDID"));
        NSString *s = ((MsgSendPlain)objc_msgSend)(uuid, NSSelectorFromString(@"UUIDString"));
        if ([s caseInsensitiveCompare:udid] == NSOrderedSame) return d;
    }
    if (reason) *reason = [NSString stringWithFormat:@"no simulator with udid %@", udid];
    return nil;
}

// Send one already-built Indigo message through the legacy HID client. The
// client takes ownership of `msg` (freeWhenDone:YES) — a malloc'd buffer from
// the SimulatorKit builders — so the caller must not free it afterwards.
static void hid_send(id client, void *msg) {
    SEL sel = NSSelectorFromString(@"sendWithMessage:freeWhenDone:completionQueue:completion:");
    Class cls = object_getClass(client);
    IMP imp = class_getMethodImplementation(cls, sel);
    if (!imp) return;
    ((MsgSendHID)imp)(client, sel, msg, YES, nil, nil);
}

// Resolve + warm a SimDeviceLegacyHIDClient for a device, cached per udid. The
// client keeps the HID pipeline (pointer + mouse services) alive for its
// lifetime, so we warm it exactly once.
static id hid_client(NSString *udid, NSString **reason) {
    static NSMutableDictionary *cache = nil;
    if (!cache) cache = [NSMutableDictionary dictionary];
    id existing = cache[udid];
    if (existing) return existing;

    if (resolve_symbols(reason) != 0) return nil;
    id device = device_for_udid(udid, reason);
    if (!device) return nil;

    // The class ships under its Swift-mangled name in SimulatorKit.
    Class cls = NSClassFromString(@"_TtC12SimulatorKit24SimDeviceLegacyHIDClient");
    if (!cls) cls = objc_lookUpClass("SimDeviceLegacyHIDClient");
    if (!cls) { if (reason) *reason = @"SimDeviceLegacyHIDClient class not found"; return nil; }

    id allocated = ((MsgSendPlain)objc_msgSend)((id)cls, NSSelectorFromString(@"alloc"));
    if (!allocated) { if (reason) *reason = @"SimDeviceLegacyHIDClient alloc failed"; return nil; }
    NSError *err = nil;
    id client = ((MsgSendInitDev)objc_msgSend)(allocated, NSSelectorFromString(@"initWithDevice:error:"), device, &err);
    if (!client) { if (reason) *reason = [NSString stringWithFormat:@"SimDeviceLegacyHIDClient init failed: %@", err]; return nil; }

    // Warm the HID pipeline: create the pointer + mouse services so the
    // digitizer/keyboard events downstream have somewhere to route.
    if (gCreatePointerSvc) { void *m = gCreatePointerSvc(); if (m) { hid_send(client, m); usleep(20 * 1000); } }
    if (gCreateMouseSvc)   { void *m = gCreateMouseSvc();   if (m) { hid_send(client, m); usleep(20 * 1000); } }

    cache[udid] = client; // retain
    return client;
}

// Monotonic touch identifier; iOS threads a touch sequence by identifier, so a
// down/move/up chain must share one and distinct taps must differ.
static uint32_t next_touch_id(void) {
    static uint32_t counter = 0;
    counter += 1;
    if (counter == 0) counter = 1;
    return counter;
}

// Build a digitizer parent event (with a finger child appended), wrap it into an
// Indigo message, patch the target/edge slots, and dispatch. `phase`: 0=down,
// 1=move, 2=up. Coordinates are normalized 0..1.
static BOOL dispatch_touch(id client, double xr, double yr, uint32_t identifier, int phase, NSString **reason) {
    uint32_t mask = (phase == 2) ? 0x06 /* Touch|Position (lift) */ : 0x07 /* Range|Touch|Position */;
    bool range = (phase != 2);
    bool touch = (phase != 2);
    uint64_t now = mach_absolute_time();

    CFTypeRef parent = gCreateDigitizer(NULL, now, kTransducerFinger,
                                        0, identifier, mask, 0,
                                        xr, yr, 0.0, 0.0, 0.0,
                                        range, touch, 0);
    if (!parent) { if (reason) *reason = @"IOHIDEventCreateDigitizerEvent returned NULL"; return NO; }
    CFTypeRef finger = gCreateFinger(NULL, now,
                                     0, identifier, mask,
                                     xr, yr, 0.0, 0.0, 0.0,
                                     range, touch, 0);
    if (finger) { gAppendEvent(parent, finger, 0); CFRelease(finger); }

    void *msg = gTrackpadWrap(parent);
    CFRelease(parent);
    if (!msg) { if (reason) *reason = @"IndigoHIDMessageForTrackpadEventFromHIDEventRef returned NULL"; return NO; }

    // Patch the target tag (and, on the larger two-record layout, its mirror).
    // Interior touches carry no edge bit, so leave the edge slots zeroed.
    *(uint32_t *)((uint8_t *)msg + 0x6c) = kTouchTarget;
    size_t sz = malloc_size(msg);
    if (sz >= 0x110) *(uint32_t *)((uint8_t *)msg + 0x10c) = kTouchTarget;

    hid_send(client, msg); // client frees msg (freeWhenDone:YES)
    return YES;
}

int reticle_sim_hid_available(const char *udid, char *err, size_t errlen) {
    @autoreleasepool {
        NSString *reason = nil;
        if (!hid_client(@(udid), &reason)) { set_err(err, errlen, reason ?: @"HID client unavailable"); return 1; }
        return 0;
    }
}

int reticle_sim_hid_tap(const char *udid, double x, double y, double w, double h, char *err, size_t errlen) {
    @autoreleasepool {
        NSString *reason = nil;
        id client = hid_client(@(udid), &reason);
        if (!client) { set_err(err, errlen, reason ?: @"HID client unavailable"); return 2; }
        double xr = x / (w > 0 ? w : 1), yr = y / (h > 0 ? h : 1);
        uint32_t id = next_touch_id();
        if (!dispatch_touch(client, xr, yr, id, 0, &reason)) { set_err(err, errlen, reason ?: @"tap down failed"); return 11; }
        usleep(80 * 1000);
        if (!dispatch_touch(client, xr, yr, id, 2, &reason)) { set_err(err, errlen, reason ?: @"tap up failed"); return 12; }
        return 0;
    }
}

int reticle_sim_hid_swipe(const char *udid, double x1, double y1, double x2, double y2,
                          double w, double h, double durationMs, char *err, size_t errlen) {
    @autoreleasepool {
        NSString *reason = nil;
        id client = hid_client(@(udid), &reason);
        if (!client) { set_err(err, errlen, reason ?: @"HID client unavailable"); return 2; }
        double sw = (w > 0 ? w : 1), sh = (h > 0 ? h : 1);
        double dist = hypot(x2 - x1, y2 - y1);
        int steps = (int)ceil(dist / 20.0); if (steps < 1) steps = 1;
        double perStep = (durationMs > 0 ? durationMs : 250.0) / steps;
        uint32_t id = next_touch_id();
        if (!dispatch_touch(client, x1 / sw, y1 / sh, id, 0, &reason)) { set_err(err, errlen, reason ?: @"swipe down failed"); return 11; }
        for (int i = 1; i <= steps; i++) {
            usleep((useconds_t)(perStep * 1000));
            double t = (double)i / steps, x = x1 + (x2 - x1) * t, y = y1 + (y2 - y1) * t;
            int phase = (i < steps) ? 1 : 2;
            if (!dispatch_touch(client, x / sw, y / sh, id, phase, &reason)) { set_err(err, errlen, reason ?: @"swipe step failed"); return 12; }
        }
        return 0;
    }
}

static int ascii_to_keycode(char c, int *shift);

int reticle_sim_hid_type(const char *udid, const char *text, char *err, size_t errlen) {
    @autoreleasepool {
        NSString *reason = nil;
        id client = hid_client(@(udid), &reason);
        if (!client) { set_err(err, errlen, reason ?: @"HID client unavailable"); return 2; }
        if (!gHidArbitrary) { set_err(err, errlen, @"IndigoHIDMessageForHIDArbitrary not found"); return 10; }
        const uint32_t kbPage = 0x07;    // Keyboard/Keypad usage page.
        const uint32_t leftShift = 0xE1; // Left Shift usage on the keyboard page.
        for (const char *p = text; *p; p++) {
            int shift = 0, code = ascii_to_keycode(*p, &shift);
            if (code < 0) continue;
            if (shift) { void *m = gHidArbitrary(kTouchTarget, kbPage, leftShift, 1); if (m) hid_send(client, m); }
            void *d = gHidArbitrary(kTouchTarget, kbPage, (uint32_t)code, 1); if (d) hid_send(client, d);
            void *u = gHidArbitrary(kTouchTarget, kbPage, (uint32_t)code, 2); if (u) hid_send(client, u);
            if (shift) { void *m = gHidArbitrary(kTouchTarget, kbPage, leftShift, 2); if (m) hid_send(client, m); }
            usleep(15 * 1000);
        }
        return 0;
    }
}

static int ascii_to_keycode(char c, int *shift) {
    *shift = 0;
    if (c >= 'a' && c <= 'z') return 4 + (c - 'a');
    if (c >= 'A' && c <= 'Z') { *shift = 1; return 4 + (c - 'A'); }
    if (c >= '1' && c <= '9') return 30 + (c - '1');
    if (c == '0') return 39;
    switch (c) {
        case ' ': return 44; case '\n': return 40; case '\t': return 43;
        case '-': return 45; case '=': return 46; case '.': return 55;
        case ',': return 54; case '/': return 56; case ';': return 51; case '\'': return 52;
        default: return -1;
    }
}

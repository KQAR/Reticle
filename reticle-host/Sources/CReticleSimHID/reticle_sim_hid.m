#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <mach/mach.h>
#import <malloc/malloc.h>
#import <dlfcn.h>
#import "reticle_sim_hid.h"

// Private CoreSimulator/SimulatorKit HID input for the iOS simulator.
//
// Xcode 26 removed the old `SimDeviceLegacyHIDClient sendWithMessage:` path that
// idb / Loupe use; there is no public reference for the replacement. Reverse-
// engineered here (Xcode 26.3): the Indigo message builders still live in
// SimulatorKit, but the message is now delivered over a mach send right obtained
// through the SimDeviceIO port graph:
//
//   SimDeviceIOClient(device, errorQueue, errorHandler)
//     -> ioPorts  (find the port whose descriptor conforms to SimLegacyHIDDescriptor)
//     -> descriptor.legacyHIDEventPort   (an OS_xpc_mach_send)
//     -> xpc_mach_send_copy_right(...)   -> mach_port_t (a send right)
//     -> set the IndigoMessage's mach header + mach_msg(MACH_SEND_MSG).
//
// Everything is resolved dynamically so this links on any Xcode and degrades to a
// clear error when a symbol/class is absent. Simulator-only; fragile by nature.

#pragma pack(push, 4)
typedef struct {
    unsigned int field1, field2, eventMask;
    double xRatio, yRatio, field6, field7, field8;
    unsigned int range, touch, field11, field12, field13;
    double field14, field15, field16, field17, field18;
} IndigoTouch;
typedef struct { double q[16]; } IndigoBig;
typedef union { IndigoTouch touch; IndigoBig big; } IndigoEvent;
typedef struct { unsigned int eventKind; unsigned long long timestamp; unsigned int field3; IndigoEvent event; } IndigoPayload;
typedef struct { mach_msg_header_t header; unsigned int innerSize; unsigned char eventType; IndigoPayload payload; } IndigoMessage;
#pragma pack(pop)

#define DIG_RANGE 0x1
#define DIG_TOUCH 0x2
#define DIG_POSITION 0x4

typedef IndigoMessage *(*MouseFn)(CGPoint *, CGPoint *, int32_t, int32_t, BOOL);
typedef IndigoMessage *(*KeyboardFn)(int32_t, int32_t);
typedef mach_port_t (*XpcCopyRightFn)(id);
typedef id (*MsgSendCtx)(id, SEL, NSString *, NSError **);
typedef id (*MsgSendErr)(id, SEL, NSError **);
typedef id (*MsgSendPlain)(id, SEL);
typedef id (*MsgSendIO)(id, SEL, id, dispatch_queue_t, id);

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

static void *load_simkit(NSString **reason) {
    static void *simkit = NULL;
    if (simkit) return simkit;
    NSString *dev = developer_dir();
    for (NSString *p in @[[dev stringByAppendingString:@"/Library/PrivateFrameworks/CoreSimulator.framework/CoreSimulator"],
                          @"/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator"]) {
        dlopen(p.fileSystemRepresentation, RTLD_NOW);
    }
    void *h = dlopen([[dev stringByAppendingString:@"/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit"] fileSystemRepresentation], RTLD_NOW);
    if (!h) { if (reason) *reason = @"cannot dlopen SimulatorKit"; return NULL; }
    simkit = h; return simkit;
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

// Resolve the legacy-HID mach send right for a device. Caches the IOClient so the
// ports (and the send right) stay alive across calls.
static mach_port_t hid_port(NSString *udid, NSString **reason) {
    static NSMutableDictionary *clientCache = nil;
    static NSMutableDictionary *portCache = nil;
    if (!clientCache) { clientCache = [NSMutableDictionary dictionary]; portCache = [NSMutableDictionary dictionary]; }
    NSNumber *cached = portCache[udid];
    if (cached) return (mach_port_t)cached.unsignedIntValue;

    id device = device_for_udid(udid, reason);
    if (!device) return MACH_PORT_NULL;

    Class ioClass = objc_lookUpClass("SimDeviceIOClient");
    if (!ioClass) { if (reason) *reason = @"SimDeviceIOClient class not found"; return MACH_PORT_NULL; }
    id client = ((MsgSendIO)objc_msgSend)([ioClass alloc],
        NSSelectorFromString(@"initWithDevice:errorQueue:errorHandler:"),
        device, dispatch_get_main_queue(), ^(id e){ (void)e; });
    if (!client) { if (reason) *reason = @"SimDeviceIOClient init failed"; return MACH_PORT_NULL; }
    clientCache[udid] = client; // retain

    NSArray *ports = ((MsgSendPlain)objc_msgSend)(client, NSSelectorFromString(@"ioPorts"));
    SEL portSel = NSSelectorFromString(@"legacyHIDEventPort");
    XpcCopyRightFn copyRight = (XpcCopyRightFn)dlsym(RTLD_DEFAULT, "xpc_mach_send_copy_right");
    if (!copyRight) { if (reason) *reason = @"xpc_mach_send_copy_right unavailable"; return MACH_PORT_NULL; }

    for (id p in ports) {
        id desc = ((MsgSendPlain)objc_msgSend)(p, NSSelectorFromString(@"descriptor"));
        if (!desc || ![desc respondsToSelector:portSel]) continue;
        id evport = ((MsgSendPlain)objc_msgSend)(desc, portSel);
        if (!evport) continue;
        mach_port_t mp = copyRight(evport);
        if (mp != MACH_PORT_NULL) { portCache[udid] = @(mp); return mp; }
    }
    if (reason) *reason = @"no SimLegacyHIDDescriptor port with a legacyHIDEventPort found";
    return MACH_PORT_NULL;
}

// Fill the mach header and send `size` bytes of the Indigo message to the port.
static BOOL send_indigo(mach_port_t port, IndigoMessage *msg, mach_msg_size_t size, NSString **reason) {
    msg->header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
    msg->header.msgh_size = size;
    msg->header.msgh_remote_port = port;
    msg->header.msgh_local_port = MACH_PORT_NULL;
    msg->header.msgh_voucher_port = MACH_PORT_NULL;
    msg->header.msgh_id = 0;
    kern_return_t kr = mach_msg(&msg->header, MACH_SEND_MSG, size, 0, MACH_PORT_NULL, 100, MACH_PORT_NULL);
    if (kr != KERN_SUCCESS) { if (reason) *reason = [NSString stringWithFormat:@"mach_msg send failed: 0x%x %s", kr, mach_error_string(kr)]; return NO; }
    return YES;
}

// Total wire size of the hand-built two-payload single-touch message.
static const mach_msg_size_t kTouchMessageSize = sizeof(IndigoMessage) + sizeof(IndigoPayload);

// Build a single-touch (eventType 0x02) two-payload Indigo message, the known-good
// message body: source a valid IndigoTouch from the SimulatorKit builder, then
// hand-envelope it (eventKind 0xB, timestamp, duplicated 2nd payload with the
// contact markers). The digitizer down/up state is set explicitly.
static IndigoMessage *build_touch(MouseFn mouseFn, double xr, double yr, BOOL down) {
    CGPoint pt = CGPointMake(xr, yr);
    IndigoMessage *source = mouseFn(&pt, NULL, 0x32, down ? 1 : 2, NO);
    if (!source) return NULL;
    source->payload.event.touch.xRatio = xr;
    source->payload.event.touch.yRatio = yr;

    size_t stride = sizeof(IndigoPayload);
    unsigned char *dst = calloc(1, kTouchMessageSize);
    IndigoMessage *msg = (IndigoMessage *)dst;
    msg->innerSize = (unsigned int)sizeof(IndigoPayload);
    msg->eventType = 0x02;
    msg->payload.eventKind = 0x0000000B;
    msg->payload.timestamp = mach_absolute_time();

    memcpy(dst + 0x30, ((unsigned char *)source) + 0x30, sizeof(IndigoTouch));
    free(source);

    IndigoTouch *t = &msg->payload.event.touch;
    t->xRatio = xr; t->yRatio = yr;
    if (down) { t->eventMask = DIG_RANGE | DIG_TOUCH | DIG_POSITION; t->range = 1; t->touch = 1; }
    else { t->eventMask = DIG_RANGE | DIG_POSITION; t->range = 0; t->touch = 0; }

    memcpy(dst + 0x20 + stride, dst + 0x20, stride);
    IndigoPayload *second = (IndigoPayload *)(dst + 0x20 + stride);
    second->event.touch.field1 = 1;
    second->event.touch.field2 = 2;
    return msg;
}

int reticle_sim_hid_available(const char *udid, char *err, size_t errlen) {
    @autoreleasepool {
        NSString *reason = nil;
        if (!load_simkit(&reason)) { set_err(err, errlen, reason); return 1; }
        if (hid_port(@(udid), &reason) == MACH_PORT_NULL) { set_err(err, errlen, reason); return 2; }
        return 0;
    }
}

static int prepare(const char *udid, char *err, size_t errlen, MouseFn *mouse, mach_port_t *port) {
    NSString *reason = nil;
    if (!load_simkit(&reason)) { set_err(err, errlen, reason); return 1; }
    MouseFn m = (MouseFn)dlsym(RTLD_DEFAULT, "IndigoHIDMessageForMouseNSEvent");
    if (!m) { set_err(err, errlen, @"IndigoHIDMessageForMouseNSEvent not found"); return 10; }
    mach_port_t p = hid_port(@(udid), &reason);
    if (p == MACH_PORT_NULL) { set_err(err, errlen, reason); return 2; }
    *mouse = m; *port = p; return 0;
}

int reticle_sim_hid_tap(const char *udid, double x, double y, double w, double h, char *err, size_t errlen) {
    @autoreleasepool {
        MouseFn mouse; mach_port_t port;
        int rc = prepare(udid, err, errlen, &mouse, &port); if (rc) return rc;
        double xr = x / (w > 0 ? w : 1), yr = y / (h > 0 ? h : 1);
        NSString *reason = nil;
        IndigoMessage *d = build_touch(mouse, xr, yr, YES);
        BOOL ok = d && send_indigo(port, d, kTouchMessageSize, &reason); free(d);
        if (!ok) { set_err(err, errlen, reason ?: @"tap down failed"); return 11; }
        usleep(50 * 1000);
        IndigoMessage *u = build_touch(mouse, xr, yr, NO);
        ok = u && send_indigo(port, u, kTouchMessageSize, &reason); free(u);
        if (!ok) { set_err(err, errlen, reason ?: @"tap up failed"); return 12; }
        return 0;
    }
}

int reticle_sim_hid_swipe(const char *udid, double x1, double y1, double x2, double y2,
                          double w, double h, double durationMs, char *err, size_t errlen) {
    @autoreleasepool {
        MouseFn mouse; mach_port_t port;
        int rc = prepare(udid, err, errlen, &mouse, &port); if (rc) return rc;
        NSString *reason = nil;
        double dist = hypot(x2 - x1, y2 - y1);
        int steps = (int)ceil(dist / 20.0); if (steps < 1) steps = 1;
        double perStep = (durationMs > 0 ? durationMs : 250.0) / steps;
        for (int i = 0; i <= steps; i++) {
            double t = (double)i / steps, x = x1 + (x2 - x1) * t, y = y1 + (y2 - y1) * t;
            IndigoMessage *m = build_touch(mouse, x / (w > 0 ? w : 1), y / (h > 0 ? h : 1), i < steps);
            BOOL ok = m && send_indigo(port, m, kTouchMessageSize, &reason); free(m);
            if (!ok) { set_err(err, errlen, reason ?: @"swipe step failed"); return 11; }
            if (i < steps) usleep((useconds_t)(perStep * 1000));
        }
        return 0;
    }
}

static int ascii_to_keycode(char c, int *shift);

int reticle_sim_hid_type(const char *udid, const char *text, char *err, size_t errlen) {
    @autoreleasepool {
        NSString *reason = nil;
        if (!load_simkit(&reason)) { set_err(err, errlen, reason); return 1; }
        KeyboardFn kb = (KeyboardFn)dlsym(RTLD_DEFAULT, "IndigoHIDMessageForKeyboardArbitrary");
        if (!kb) { set_err(err, errlen, @"IndigoHIDMessageForKeyboardArbitrary not found"); return 10; }
        mach_port_t port = hid_port(@(udid), &reason);
        if (port == MACH_PORT_NULL) { set_err(err, errlen, reason); return 2; }
        for (const char *p = text; *p; p++) {
            int shift = 0, code = ascii_to_keycode(*p, &shift);
            if (code < 0) continue;
            if (shift) { IndigoMessage *m = kb(225, 1); send_indigo(port, m, 0x20 + m->innerSize, &reason); free(m); }
            IndigoMessage *d = kb(code, 1); send_indigo(port, d, 0x20 + d->innerSize, &reason); free(d);
            IndigoMessage *u = kb(code, 2); send_indigo(port, u, 0x20 + u->innerSize, &reason); free(u);
            if (shift) { IndigoMessage *m = kb(225, 2); send_indigo(port, m, 0x20 + m->innerSize, &reason); free(m); }
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

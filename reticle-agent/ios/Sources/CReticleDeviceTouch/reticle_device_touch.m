#import "reticle_device_touch.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

static void append(char *out, size_t outlen, const char *fragment) {
    size_t used = strlen(out);
    if (used + strlen(fragment) + 2 >= outlen) return;
    if (used > 0) strlcat(out, ",", outlen);
    strlcat(out, fragment, outlen);
}

static void set_err(char *err, size_t errlen, NSString *message) {
    if (err && errlen) strlcpy(err, message.UTF8String ?: "unknown", errlen);
}

/// Everything the dispatch below needs, named individually so a report says WHICH
/// piece is missing on an OS that moved one.
int reticle_device_touch_probe(char *out, size_t outlen) {
    if (outlen == 0) return 1;
    out[0] = '\0';

    const char *touchSelectors[] = {
        "setWindow:", "setView:", "setPhase:", "setTapCount:", "setTimestamp:",
        "_setIsFirstTouchForView:", "_setLocationInWindow:resetPrevious:",
    };
    bool haveTouch = true;
    for (size_t i = 0; i < sizeof(touchSelectors) / sizeof(touchSelectors[0]); i++) {
        SEL sel = sel_getUid(touchSelectors[i]);
        bool present = class_getInstanceMethod(UITouch.class, sel) != NULL;
        if (!present) haveTouch = false;
        char buf[96];
        snprintf(buf, sizeof(buf), "%stouch:%s", present ? "" : "MISSING ", touchSelectors[i]);
        append(out, outlen, buf);
    }

    UIApplication *app = UIApplication.sharedApplication;
    bool haveEventSource = [app respondsToSelector:sel_getUid("_touchesEvent")];
    append(out, outlen, haveEventSource ? "app:_touchesEvent" : "MISSING app:_touchesEvent");

    Class eventClass = NSClassFromString(@"UITouchesEvent");
    const char *eventSelectors[] = { "_clearTouches", "_addTouch:forDelayedDelivery:", "_setTimestamp:" };
    bool haveEvent = eventClass != nil;
    for (size_t i = 0; eventClass && i < sizeof(eventSelectors) / sizeof(eventSelectors[0]); i++) {
        SEL sel = sel_getUid(eventSelectors[i]);
        bool present = class_getInstanceMethod(eventClass, sel) != NULL;
        // `_clearTouches` is optional (the dispatch skips it when absent); the add is not.
        if (!present && i == 1) haveEvent = false;
        char buf[96];
        snprintf(buf, sizeof(buf), "%sevent:%s", present ? "" : "MISSING ", eventSelectors[i]);
        append(out, outlen, buf);
    }
    if (!eventClass) append(out, outlen, "MISSING class:UITouchesEvent");

    if (strlen(out) == 0) append(out, outlen, "none");
    return (haveTouch && haveEventSource && haveEvent) ? 0 : 2;
}

// MARK: - dispatch
//
// See the header for the route that was tried and rejected (an in-process
// digitizer IOHIDEvent, which UIKit accepts and routes nowhere on a device).

static UIWindow *window_at(CGPoint screenPoint, UIView **hitView, UIEvent *event) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isHidden || w.alpha < 0.01) continue;
            [windows addObject:w];
        }
    }
    // Topmost first: a touch lands in the window that would receive it.
    [windows sortUsingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
        if (a.windowLevel == b.windowLevel) return NSOrderedSame;
        return a.windowLevel > b.windowLevel ? NSOrderedAscending : NSOrderedDescending;
    }];
    for (UIWindow *w in windows) {
        CGPoint inWindow = [w convertPoint:screenPoint fromWindow:nil];
        if (!CGRectContainsPoint(w.bounds, inWindow)) continue;
        // WITH the event, never nil. A view is entitled to inspect the event in
        // `hitTest:withEvent:` and some do: Compose Multiplatform's overlay input
        // layer claims a nil-event hit and then routes nothing, so every tap on a
        // Compose screen dispatched successfully and did nothing. Measured on an
        // iPhone 13 Pro Max / iOS 26 against a KMP app.
        UIView *hit = [w hitTest:inWindow withEvent:event];
        if (hit) { if (hitView) *hitView = hit; return w; }
    }
    return nil;
}

int reticle_device_touch_hit_view(double x, double y, char *out, size_t outlen) {
    @autoreleasepool {
        if (!out || outlen == 0) return 1;
        out[0] = '\0';
        if (!NSThread.isMainThread) {
            set_err(out, outlen, @"must be called on the main thread");
            return 1;
        }
        SEL touchesEvent = sel_getUid("_touchesEvent");
        id event = [UIApplication.sharedApplication respondsToSelector:touchesEvent]
            ? ((id (*)(id, SEL))objc_msgSend)(UIApplication.sharedApplication, touchesEvent)
            : nil;
        UIView *hit = nil;
        UIWindow *window = window_at(CGPointMake(x, y), &hit, event);
        if (!window || !hit) {
            set_err(out, outlen, @"none");
            return 2;
        }
        NSMutableArray<NSString *> *recognizers = [NSMutableArray array];
        for (UIView *v = hit; v != nil; v = v.superview) {
            for (UIGestureRecognizer *g in v.gestureRecognizers) {
                if (g.isEnabled) [recognizers addObject:NSStringFromClass(g.class)];
            }
        }
        set_err(out, outlen, [NSString stringWithFormat:@"%@ in %@ recognizers=[%@]",
                              NSStringFromClass(hit.class), NSStringFromClass(window.class),
                              [recognizers componentsJoinedByString:@" "]]);
        return 0;
    }
}

int reticle_device_touch_send(double x, double y, int phase, char *err, size_t errlen) {
    @autoreleasepool {
        if (!NSThread.isMainThread) {
            set_err(err, errlen, @"must be called on the main thread");
            return 1;
        }
        static UITouch *sTouch = nil;

        SEL setLocation = sel_getUid("_setLocationInWindow:resetPrevious:");
        SEL setWindow = sel_getUid("setWindow:");
        SEL setView = sel_getUid("setView:");
        SEL setPhase = sel_getUid("setPhase:");
        SEL setTapCount = sel_getUid("setTapCount:");
        SEL setTimestamp = sel_getUid("setTimestamp:");
        SEL setFirstTouch = sel_getUid("_setIsFirstTouchForView:");
        SEL touchesEvent = sel_getUid("_touchesEvent");
        SEL clearTouches = sel_getUid("_clearTouches");
        SEL addTouch = sel_getUid("_addTouch:forDelayedDelivery:");
        SEL eventTimestamp = sel_getUid("_setTimestamp:");

        if (!class_getInstanceMethod(UITouch.class, setLocation)
            || !class_getInstanceMethod(UITouch.class, setWindow)
            || ![UIApplication.sharedApplication respondsToSelector:touchesEvent]) {
            set_err(err, errlen, @"UITouch/_touchesEvent private surface is absent");
            return 20;
        }

        // The event is fetched BEFORE the hit test, because the hit test needs it:
        // `hitTest:withEvent:` is allowed to consult the event, and a nil one
        // makes some views answer wrongly (see window_at).
        id event = ((id (*)(id, SEL))objc_msgSend)(UIApplication.sharedApplication, touchesEvent);
        if (!event) {
            set_err(err, errlen, @"_touchesEvent returned nil");
            return 22;
        }

        CGPoint screenPoint = CGPointMake(x, y);
        UIView *hitView = nil;
        UIWindow *window = window_at(screenPoint, &hitView, event);
        if (!window) {
            set_err(err, errlen, @"no window of this process contains that point");
            return 21;
        }
        CGPoint inWindow = [window convertPoint:screenPoint fromWindow:nil];

        if (phase == 0 || !sTouch) {
            sTouch = [[UITouch alloc] init];
            ((void (*)(id, SEL, id))objc_msgSend)(sTouch, setWindow, window);
            ((void (*)(id, SEL, id))objc_msgSend)(sTouch, setView, hitView);
            ((void (*)(id, SEL, NSUInteger))objc_msgSend)(sTouch, setTapCount, 1);
            ((void (*)(id, SEL, BOOL))objc_msgSend)(sTouch, setFirstTouch, YES);
            ((void (*)(id, SEL, CGPoint, BOOL))objc_msgSend)(sTouch, setLocation, inWindow, YES);
        } else {
            ((void (*)(id, SEL, CGPoint, BOOL))objc_msgSend)(sTouch, setLocation, inWindow, NO);
        }
        NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
        ((void (*)(id, SEL, NSTimeInterval))objc_msgSend)(sTouch, setTimestamp, now);
        UITouchPhase uiPhase = (phase == 0) ? UITouchPhaseBegan
                             : (phase == 1) ? UITouchPhaseMoved
                                            : UITouchPhaseEnded;
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(sTouch, setPhase, uiPhase);

        if ([event respondsToSelector:clearTouches]) {
            ((void (*)(id, SEL))objc_msgSend)(event, clearTouches);
        }
        if ([event respondsToSelector:eventTimestamp]) {
            ((void (*)(id, SEL, NSTimeInterval))objc_msgSend)(event, eventTimestamp, now);
        }
        if ([event respondsToSelector:addTouch]) {
            ((void (*)(id, SEL, id, BOOL))objc_msgSend)(event, addTouch, sTouch, NO);
        } else {
            set_err(err, errlen, @"_addTouch:forDelayedDelivery: is absent");
            return 23;
        }
        [UIApplication.sharedApplication sendEvent:event];
        if (phase == 2) sTouch = nil;
        return 0;
    }
}

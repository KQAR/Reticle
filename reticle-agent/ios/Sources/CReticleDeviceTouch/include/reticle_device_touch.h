#pragma once
#include <stddef.h>
#include <stdbool.h>

/// In-process touch synthesis for a REAL DEVICE, where no host-reachable HID
/// surface exists. The agent runs inside the app, so a touch can be delivered
/// through UIKit's own event path — which means hit-testing, gesture recognizers
/// and scroll views behave exactly as they do under a finger. That is what
/// `activate` could never do: it fires a control's action, while most self-drawn
/// rows and every scroll view need an actual touch.
///
/// The mechanism is the one KIF has used for years: build a `UITouch`, put it in
/// the application's own `UITouchesEvent`, and send it through `-sendEvent:`.
///
/// A route TRIED AND REJECTED, recorded so it is not tried again: the digitizer
/// `IOHIDEvent` this repo builds for the simulator can be constructed in-process
/// on a device (IOKit's constructors resolve, and `UIApplication` answers both
/// `_enqueueHIDEvent:` and `_handleHIDEvent:`) — and it is accepted and routed
/// NOWHERE. Measured on an iPhone 13 Pro Max / iOS 26 across all 16 combinations
/// of sink, sender id, display-integrated flag and coordinate space: dispatched
/// with no error, zero effect.
///
/// Everything here is private API, so every entry point is capability-probed: a
/// missing symbol or selector is reported by name rather than silently no-op'ing,
/// the same contract `reticle_sim_hid_available` carries on the simulator side.
#ifdef __cplusplus
extern "C" {
#endif

/// Comma-separated report of which parts of the private surface resolved, written
/// to `out`. Returns 0 when a usable dispatch path exists, non-zero otherwise.
int reticle_device_touch_probe(char *out, size_t outlen);

/// Deliver ONE touch event into this process. `x`/`y` are in SCREEN points — the
/// space every rect Reticle reports lives in. `phase`: 0=down, 1=move, 2=up; a
/// down/move/up chain must be sent in order, since the touch object is threaded
/// across the calls.
///
/// Main thread only: the event is handed to UIKit. Deliberately one event per
/// call — the timing policy (how long a press lasts, how a drag is stepped)
/// belongs to the caller.
int reticle_device_touch_send(double x, double y, int phase, char *err, size_t errlen);

#ifdef __cplusplus
}
#endif

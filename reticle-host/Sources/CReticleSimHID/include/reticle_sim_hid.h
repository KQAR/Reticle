#ifndef RETICLE_SIM_HID_H
#define RETICLE_SIM_HID_H

#include <stddef.h>

// Private CoreSimulator HID input synthesis for the iOS simulator. Every private
// symbol/class is resolved at runtime (dlopen/dlsym/objc_lookUpClass) so this
// target links on any Xcode and a missing/renamed private symbol surfaces as a
// descriptive error rather than a link failure. Simulator-only; fragile across
// Xcode versions by nature (the Indigo wire format is a reverse-engineered ABI).
//
// Each function returns 0 on success. On failure it returns non-zero and copies
// a human-readable reason into `err` (NUL-terminated, truncated to errlen).
//
// Coordinates are in POINTS; widthPoints/heightPoints are the screen size in
// points (Indigo wants a 0..1 top-left ratio, computed here as x/width).

#ifdef __cplusplus
extern "C" {
#endif

int reticle_sim_hid_available(const char *udid, char *err, size_t errlen);

int reticle_sim_hid_tap(const char *udid, double x, double y,
                        double widthPoints, double heightPoints,
                        char *err, size_t errlen);

int reticle_sim_hid_swipe(const char *udid, double x1, double y1, double x2, double y2,
                          double widthPoints, double heightPoints, double durationMs,
                          char *err, size_t errlen);

// Printable-ASCII text only (0x20..0x7E, plus tab/newline). Non-ASCII (CJK,
// emoji, accented Latin) goes through the agent clipboard + paste path.
int reticle_sim_hid_type(const char *udid, const char *asciiText, char *err, size_t errlen);

// Press Cmd+V to paste the focused field's contents from the clipboard (which
// the in-process agent staged via POST /clipboard). The iOS analogue of
// Android's KEYCODE_PASTE, for text the HID keyboard can't emit.
int reticle_sim_hid_paste(const char *udid, char *err, size_t errlen);

#ifdef __cplusplus
}
#endif

#endif /* RETICLE_SIM_HID_H */

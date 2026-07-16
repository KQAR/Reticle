#include <dlfcn.h>
#include "reticle_bootstrap.h"

// Anchor referenced from Swift (ReticleInjection) so the linker keeps this
// translation unit. Without a reference, a constructor-only object gets
// dead-stripped from the dylib and the injection never fires. No-op body.
void reticle_bootstrap_anchor(void) {}

// Load-time bootstrap for the DYLD-injection path. When this dynamic library is
// injected via DYLD_INSERT_LIBRARIES (staged by the host through
// SIMCTL_CHILD_DYLD_INSERT_LIBRARIES), the C runtime runs this constructor
// before the app's own code. It looks up the exported Swift entry point
// `ReticleInjectorStart` (an @_cdecl symbol in the ReticleInjection target,
// resident in the same injected image) and calls it.
//
// The Swift side is responsible for hopping to the main thread and deferring the
// actual server start until the app is initialized — this constructor must stay
// tiny and must not block. dlsym(RTLD_DEFAULT, ...) keeps this decoupled from a
// link-time symbol dependency, so the C target has no build-time reference to
// the Swift runtime.
__attribute__((constructor))
static void reticle_bootstrap(void) {
    void (*start)(void) = (void (*)(void))dlsym(RTLD_DEFAULT, "ReticleInjectorStart");
    if (start != 0) {
        start();
    }
}

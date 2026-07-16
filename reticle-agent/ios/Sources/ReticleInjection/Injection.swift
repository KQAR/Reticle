import Foundation
import ReticleKit
import CReticleBootstrap

// Reference the C anchor so the linker keeps CReticleBootstrap's translation
// unit (and therefore its load-time constructor) in the injected dylib.
private let keepBootstrap: @convention(c) () -> Void = reticle_bootstrap_anchor

// The DYLD-injection entry point. The C constructor in CReticleBootstrap looks
// this symbol up with dlsym and calls it on load. It must return immediately;
// `Reticle.startFromInjection()` defers the real work to the main thread after
// the app finishes launching.
@_cdecl("ReticleInjectorStart")
public func ReticleInjectorStart() {
    _ = keepBootstrap
    Reticle.startFromInjection()
}

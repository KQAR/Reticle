import Foundation

// The simulator path builds this app with SwiftPM, which synthesizes
// `Bundle.module` for the target's `resources:`. The real-device path builds the
// same sources through sample-app-ios/xcode (xcodegen), where there is no
// generated accessor and the same files are copied into the app bundle itself —
// so `Bundle.module` would not compile. Under that build only, point it at the
// main bundle. Guarded by SWIFT_ACTIVE_COMPILATION_CONDITIONS in project.yml, so
// SwiftPM never sees a duplicate declaration.
#if RETICLE_XCODE_APP
extension Bundle {
    static var module: Bundle { .main }
}
#endif

import Testing
import ReticleProtocol
@testable import ReticleHostIos

@Suite("iOS inactive-app warning")
struct IosInactiveAppTests {

    private func snapshot(focused: Bool?) -> Snapshot {
        Snapshot(
            capturedAtMillis: 0,
            platform: "ios",
            screen: ScreenInfo(size: Size(width: 400, height: 800), density: 3, windowFocused: focused),
            rootRef: "r0",
            nodes: [:])
    }

    @Test func anInactiveAppWarnsThatSomethingElseHasInput() async {
        // The failure this exists for: a system prompt owned by ANOTHER PROCESS
        // sits over the app. It is in no tree and in no in-process screenshot, so
        // the only trace it leaves is the app no longer being active — and a tap
        // dispatched into that state can be wholly inert while still reporting
        // success. Measured on a real device against a StoreKit account prompt.
        let warning = IosHelperClient(serial: nil).inactiveWarning(snapshot(focused: false))
        #expect(warning != nil)
        #expect(warning?.contains("NOT active") == true)
        #expect(warning?.contains("system prompt") == true)
    }

    @Test func anActiveAppIsSilent() async {
        #expect(IosHelperClient(serial: nil).inactiveWarning(snapshot(focused: true)) == nil)
    }

    @Test func anUnknownFocusStateIsSilentRatherThanAlarming() async {
        // `windowFocused` is absent on an older agent. Absent is not "inactive":
        // warning on a missing reading would cry wolf on every action.
        #expect(IosHelperClient(serial: nil).inactiveWarning(snapshot(focused: nil)) == nil)
        #expect(IosHelperClient(serial: nil).inactiveWarning(nil) == nil)
    }
}

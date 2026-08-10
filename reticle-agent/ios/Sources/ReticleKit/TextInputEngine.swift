import Foundation
import ReticleProtocol
#if canImport(UIKit)
import UIKit

/// In-process text entry — the on-device "type", and the twin of
/// `ActivationEngine` for keyboards rather than controls.
///
/// The host cannot synthesize HID keys to a physical device, but the agent runs
/// *inside* the app, so it can hand characters to the focused field through the
/// very entry point the system keyboard uses: `UIKeyInput.insertText`. That is
/// what makes this different from `mutate --property text`, which assigns
/// `UITextField.text` directly and fires nothing — here the delegate
/// (`shouldChangeCharactersIn`), `.editingChanged`, and a SwiftUI `TextField`'s
/// binding all run, because UIKit cannot tell this apart from a keypress.
///
/// What it is NOT: a keyboard. It cannot reach another process's UI, or a
/// control that takes raw touches instead of text input (a custom PIN pad).
/// Those report `unsupported_text_target` rather than a silent no-op.
///
/// **The target protocol is `UIKeyInput`, not `UITextInput`.** It used to be the
/// latter, and that excluded every canvas toolkit: Compose Multiplatform and
/// Flutter draw the whole screen into one view and route text through a private
/// off-screen responder that implements only the keyboard's own entry points.
/// Measured on a KMP app (`androidx.compose.ui.window.*InputView`), that made
/// EVERY field on the screen answer `unsupported_text_target` — including one
/// that plainly had focus and a keyboard up. `UIKeyInput` is all the insert /
/// delete path actually needs; `UITextInput` is now optional and only richer
/// behaviour (caret range, delegate veto, read-back) depends on it, degrading to
/// a stated `unavailable` rather than a refusal when it is absent.
@MainActor
struct TextInputEngine {

    /// A field longer than this is not hammered with hundreds of deletes — it is
    /// reported as not cleared and the caller decides. Matches the host's HID
    /// limit (`IosHelperClient.maxClearDeletes`) and Android's.
    static let maxClearDeletes = 64

    /// The resolved field, carried across the main-thread hops the paced typing
    /// loop makes. `@unchecked Sendable` for the same reason as the capture
    /// transport: it is only ever touched back on the main thread.
    struct Target: @unchecked Sendable {
        let field: UIView & UIKeyInput
        let ref: String?
        let typeName: String
        /// How focus was obtained, when it took more than naming the field.
        var focusVia: String?

        /// Present for a UIKit field, absent for a canvas toolkit's private
        /// responder. Everything that reads document state goes through this.
        var document: UITextInput? { field as? UITextInput }
    }

    enum Resolution {
        case ready(Target)
        case failed(TypeTextResult)
    }

    /// Resolve the request's selector to a text input and give it focus. With no
    /// selector the current first responder is used — the same "type into what has
    /// focus" rule the HID path follows.
    func focus(_ request: TypeTextRequest) -> Resolution {
        var resolved = resolveField(request.selector)
        // A canvas toolkit puts no UIKit field under the node a selector names —
        // its responder is created BY the touch. So do what a user does: tap the
        // resolved node, then take whatever became first responder. Only reached
        // when the direct search already came up empty, so a real UIKit field is
        // never re-routed through a synthetic touch.
        if resolved.field == nil, let rect = resolved.frame {
            focusByTap(rect)
            if let view = FirstResponderLookup.current() as? UIView, let focused = asKeyInput(view) {
                resolved.field = focused
                resolved.via = "tap-to-focus"
            } else if let field = windowTextInput() {
                // The toolkit's proxy can hold the text session without being the
                // responder the chain reports; it is still the only thing on the
                // screen that takes characters.
                resolved.field = field
                resolved.via = "tap-to-focus+window-scan"
            }
        }
        guard let field = resolved.field else {
            return .failed(TypeTextResult(
                typed: false, ref: resolved.ref, typeName: resolved.resolvedTypeName,
                message: request.selector == nil
                    ? "no field has focus and no selector was given — name the field with a selector"
                    : resolved.ref == nil
                        ? "no view matched selector \(request.selector!.describe())"
                        : "unsupported_text_target: \(resolved.resolvedTypeName ?? "the resolved node") takes "
                            + "touches, not text — nothing at or under it is a UIKeyInput, and touching "
                            + "it raised no text responder either (first responder after the touch: "
                            + "\(FirstResponderLookup.current().map { NSStringFromClass(type(of: $0)) } ?? "none")) "
                            + "(a custom keypad is driven with `act activate`, not `act type`)"
            ))
        }
        let ref = resolved.ref
        let typeName = NSStringFromClass(type(of: field))
        if !field.isFirstResponder && !field.becomeFirstResponder() {
            return .failed(TypeTextResult(
                typed: false, ref: ref, typeName: typeName,
                message: "field-refused-focus: \(typeName) would not become first responder "
                    + "(disabled, off screen, or another responder holds focus)"
            ))
        }
        return .ready(Target(field: field, ref: ref, typeName: typeName, focusVia: resolved.via))
    }

    /// One character, through the keyboard's own entry point, preceded by the
    /// handshake the keyboard does first.
    ///
    /// Measured on iOS 26 (`TextInputEngineTests`): `insertText` publishes
    /// `.editingChanged` and the text-did-change notification, but it does NOT
    /// call `textField(_:shouldChangeCharactersIn:replacementString:)` — the text
    /// input system does that, and a programmatic insert skips it. Left as-is,
    /// every app that formats, masks or length-limits in that delegate (the
    /// common OTP / card-number shape) would have its rule silently bypassed and
    /// the read-back would still look right.
    ///
    /// So the ask is reproduced here, in UIKit's own order: compute the
    /// replacement range from the caret, ask the delegate, and insert only if it
    /// says yes. A delegate that formats by rewriting the text and returning
    /// false therefore wins, exactly as it does under a real keypress.
    ///
    /// False means nothing landed: either the field lost focus (an app can move
    /// first responder mid-flow) or the delegate refused this character.
    @discardableResult
    func insert(_ text: String, into target: Target) -> Bool {
        guard target.field.isFirstResponder else { return false }
        if let caret = caretRange(target), !delegateAllows(target, replacing: caret, with: text) { return false }
        target.field.insertText(text)
        return true
    }

    /// The range a keypress would replace: the current selection, or the empty
    /// range at the caret. Expressed in the UTF-16 offsets the delegate expects.
    /// Absent for a field that exposes no document (a canvas toolkit's
    /// responder) — there is no caret to read, and no delegate to ask either.
    private func caretRange(_ target: Target) -> NSRange? {
        guard let input = target.document else { return nil }
        guard let selection = input.selectedTextRange else {
            let end = input.offset(from: input.beginningOfDocument, to: input.endOfDocument)
            return NSRange(location: end, length: 0)
        }
        let start = input.offset(from: input.beginningOfDocument, to: selection.start)
        let length = input.offset(from: selection.start, to: selection.end)
        return NSRange(location: start, length: length)
    }

    /// The app's own veto on a text change, asked the way UIKit asks it. No
    /// delegate (or one that does not implement the method) means yes.
    private func delegateAllows(_ target: Target, replacing range: NSRange, with text: String) -> Bool {
        switch target.field {
        case let field as UITextField:
            guard let delegate = field.delegate,
                  delegate.responds(to: #selector(UITextFieldDelegate.textField(_:shouldChangeCharactersIn:replacementString:)))
            else { return true }
            return delegate.textField?(field, shouldChangeCharactersIn: range, replacementString: text) ?? true
        case let textView as UITextView:
            guard let delegate = textView.delegate,
                  delegate.responds(to: #selector(UITextViewDelegate.textView(_:shouldChangeTextIn:replacementText:)))
            else { return true }
            return delegate.textView?(textView, shouldChangeTextIn: range, replacementText: text) ?? true
        default:
            return true
        }
    }

    /// Empty the field with one delete per character it actually holds, then read
    /// it back. Deleting what is there (rather than a fixed count) and proving the
    /// result is what stops `--clear` claiming work it did not do — the same
    /// contract the HID path carries.
    func clear(_ target: Target) -> TypeClearOutcome {
        // Measured: `deleteBackward` on a field that is not the first responder is
        // a silent no-op (and `insertText` on one assigns the text while firing
        // NOTHING — no delegate, no `.editingChanged`). Focus is what makes this a
        // keypress rather than a `mutate`, so refuse rather than report a clear
        // that never happened.
        guard target.field.isFirstResponder else {
            return TypeClearOutcome(emptied: false, before: readText(target),
                                    after: readText(target), unavailable: "field-not-focused")
        }
        guard let before = readText(target) else {
            return TypeClearOutcome(emptied: false, unavailable: "field-exposes-no-text")
        }
        if before.isEmpty {
            return TypeClearOutcome(emptied: true, before: before, after: before)
        }
        if before.count > Self.maxClearDeletes {
            return TypeClearOutcome(
                emptied: false, before: before, after: before,
                unavailable: "field-too-long (\(before.count) chars, limit \(Self.maxClearDeletes))"
            )
        }
        for _ in 0..<before.count {
            // A backspace is a text change like any other, so the app gets the
            // same veto it gets from the keyboard. One that refuses (a field
            // that will not let its prefix be deleted) stops the clear here and
            // the read-back below reports it as not emptied.
            if let caret = caretRange(target) {
                let deleted = caret.length > 0
                    ? caret
                    : NSRange(location: max(caret.location - 1, 0), length: caret.location > 0 ? 1 : 0)
                guard delegateAllows(target, replacing: deleted, with: "") else { break }
            }
            target.field.deleteBackward()
        }
        let after = readText(target)
        return TypeClearOutcome(
            emptied: after?.isEmpty == true, before: before, after: after,
            deletes: before.count, unavailable: after == nil ? "field-exposes-no-text" : nil
        )
    }

    /// Fire the return key's action without a return key: what UIKit itself does
    /// when Return is pressed in a `UITextField` — ask the delegate, then send
    /// `.editingDidEndOnExit`. This is the iOS answer to Android's
    /// `/editor-action`. A `UITextView` has no return action; its Return inserts
    /// a newline, so that is what it gets.
    ///
    /// **A SwiftUI `TextField` is a measured miss.** Its delegate is SwiftUI's
    /// own `PlatformTextFieldCoordinator`, and on iOS 26 `.onSubmit` fired from
    /// NONE of the routes tried: `textFieldShouldReturn` (which returns true),
    /// `.editingDidEndOnExit`, `.primaryActionTriggered`, `.editingDidEnd`,
    /// `textFieldDidEndEditing(reason: .committed)`, `resignFirstResponder`, or
    /// inserting a newline. Since the delegate answers yes either way, the
    /// invocation cannot be checked from here — so the coordinator is named in
    /// the result rather than left to read as a submit that worked. On a device,
    /// drive a SwiftUI submit through its button with `act activate`.
    func submit(_ target: Target) -> String {
        guard let field = target.field as? UITextField else {
            target.field.insertText("\n")
            return "newline"
        }
        var via: [String] = []
        if field.delegate?.textFieldShouldReturn?(field) == true { via.append("textFieldShouldReturn") }
        if field.allControlEvents.contains(.editingDidEndOnExit) {
            field.sendActions(for: .editingDidEndOnExit)
            via.append("editingDidEndOnExit")
        }
        if via.isEmpty { return "no-return-action" }
        if let delegate = field.delegate,
           NSStringFromClass(type(of: delegate)).hasPrefix("SwiftUI.") {
            return via.joined(separator: "+")
                + " (swiftui-coordinator: measured NOT to reach .onSubmit — verify, or activate the submit button)"
        }
        return via.joined(separator: "+")
    }

    /// The field's current value. Secure fields are masked here exactly as the
    /// capture masks them, so an evidence trail never carries a password.
    func readText(_ target: Target) -> String? {
        let raw: String?
        switch target.field {
        case let field as UITextField: raw = field.text
        case let textView as UITextView: raw = textView.text
        default:
            guard let input = target.document,
                  let range = input.textRange(from: input.beginningOfDocument, to: input.endOfDocument) else {
                return nil
            }
            raw = input.text(in: range)
        }
        guard let raw else { return nil }
        return isSecure(target) ? String(repeating: "•", count: raw.count) : raw
    }

    func isSecure(_ target: Target) -> Bool {
        (target.field as? UITextField)?.isSecureTextEntry == true
    }

    // MARK: - resolution

    /// What the selector found: the field to type into, plus — when there is
    /// none — the node that WAS matched, so the refusal can name it instead of
    /// answering "nothing here" for a view that is plainly on screen.
    private struct Resolved {
        var ref: String?
        var resolvedTypeName: String?
        var field: (UIView & UIKeyInput)?
        /// The matched node's rect in window coordinates, kept so a node with no
        /// UIKit field under it can still be focused the way a user focuses it.
        var frame: CGRect?
        var via: String?
    }

    private func resolveField(_ selector: ReticleProtocol.Selector?) -> Resolved {
        guard let selector else {
            if let view = FirstResponderLookup.current() as? UIView, let focused = asKeyInput(view) {
                return Resolved(field: focused)
            }
            // A canvas toolkit reports its touch layer as the responder while the
            // text session lives on an invisible proxy, so "focused" and "takes
            // characters" are two different views there.
            return Resolved(field: windowTextInput(), via: "window-scan")
        }
        let (snapshot, index, axIndex) = SnapshotCapture().captureWithIndexes()
        // A SwiftUI `TextField` surfaces as an axElement whose element IS the
        // backing UIKit field, so the ax index is worth asking first.
        if let (ref, element) = NodeResolver.axElement(selector, snapshot: snapshot, axIndex: axIndex) {
            let view = element as? UIView
            return Resolved(
                ref: ref,
                resolvedTypeName: NSStringFromClass(type(of: element)),
                field: view.flatMap { textInput(in: $0) },
                frame: rect(of: ref, in: snapshot)
            )
        }
        guard let (ref, view) = NodeResolver.view(selector, snapshot: snapshot, index: index) else {
            // A DOM node resolves to no UIView by construction — it lives inside
            // the web view — but it has a rect, and touching that rect is how a
            // web input takes focus. Without this a `--css` type reported "no
            // view matched" for a field the same selector could tap.
            if let ref = selector.ref, let rect = rect(of: ref, in: snapshot) {
                return Resolved(ref: ref, resolvedTypeName: snapshot.nodes[ref]?.typeName, frame: rect)
            }
            // The point the HOST resolved, which is the only handle that survives
            // a re-render: a ref indexes the snapshot it came from, and this
            // capture is a newer one. Also the raw `--point` path.
            if let point = selector.point {
                return Resolved(ref: selector.ref,
                                frame: CGRect(x: CGFloat(point.x), y: CGFloat(point.y), width: 0, height: 0))
            }
            return Resolved()
        }
        return Resolved(ref: ref, resolvedTypeName: NSStringFromClass(type(of: view)),
                        field: textInput(in: view), frame: rect(of: ref, in: snapshot))
    }

    private func rect(of ref: String, in snapshot: Snapshot) -> CGRect? {
        guard let frame = snapshot.nodes[ref]?.frame else { return nil }
        return CGRect(x: CGFloat(frame.x), y: CGFloat(frame.y),
                      width: CGFloat(frame.width), height: CGFloat(frame.height))
    }

    /// `UIKeyInput` at RUNTIME rather than by declared conformance.
    ///
    /// `WKWebView` is the case that forces this: focus a field in a web page and
    /// it becomes the first responder and answers `insertText:` — but it does not
    /// publish the protocol, so `as? UIKeyInput` refuses it and a web form is
    /// untypable while the same selector can tap it. UIKeyInput is an ObjC
    /// protocol, so responding to all three of its members IS satisfying it as
    /// far as dispatch is concerned; the cast only re-labels a class that already
    /// implements every method that will be called on it.
    private func asKeyInput(_ view: UIView) -> (UIView & UIKeyInput)? {
        if let declared = view as? UIView & UIKeyInput { return declared }
        guard view.responds(to: #selector(UIKeyInput.insertText(_:))),
              view.responds(to: #selector(UIKeyInput.deleteBackward)),
              view.responds(to: #selector(getter: UIKeyInput.hasText))
        else { return nil }
        return unsafeBitCast(view, to: (UIView & UIKeyInput).self)
    }

    /// Every app window, searched for a text input. The last resort behind a
    /// selector and the responder chain, and stated as such in the result.
    private func windowTextInput() -> (UIView & UIKeyInput)? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        for window in windows.reversed() {
            if let field = textInput(in: window) { return field }
        }
        return nil
    }

    /// Touch the node so the toolkit creates its own responder, then let the run
    /// loop turn — the keyboard session is set up asynchronously.
    private func focusByTap(_ rect: CGRect) {
        let point = rect.isEmpty ? rect.origin : CGPoint(x: rect.midX, y: rect.midY)
        try? DeviceTouch.tap(at: point)
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }

    /// The text input at or under (failing that, above) a resolved view. A
    /// SwiftUI `TextField` and a UIKit form row both put the real field one or
    /// more levels away from the node a selector names. A full `UITextInput`
    /// wins over a bare `UIKeyInput` at the same distance — the richer one gives
    /// caret range, delegate veto and read-back.
    /// **Hidden views are searched too.** A canvas toolkit's text input is an
    /// invisible proxy — Compose Multiplatform parks a zero-alpha responder
    /// off-screen and draws the field itself — so skipping it on visibility (as
    /// this used to) meant the only real input on the screen was the one thing
    /// never looked at. Visibility ranks candidates; it no longer excludes them.
    func textInput(in view: UIView) -> (UIView & UIKeyInput)? {
        var visibleKeyInput: (UIView & UIKeyInput)?
        var hiddenDocument: (UIView & UITextInput)?
        var hiddenKeyInput: (UIView & UIKeyInput)?

        func consider(_ candidate: UIView, visible: Bool) -> (UIView & UITextInput)? {
            guard let field = asKeyInput(candidate), field.canBecomeFirstResponder else { return nil }
            let document = field as? UIView & UITextInput
            if visible {
                if let document { return document }
                if visibleKeyInput == nil { visibleKeyInput = field }
            } else if let document {
                if hiddenDocument == nil { hiddenDocument = document }
            } else if hiddenKeyInput == nil {
                hiddenKeyInput = field
            }
            return nil
        }

        if let field = consider(view, visible: true) { return field }
        var queue = view.subviews.map { (view: $0, visible: true) }
        while !queue.isEmpty {
            let next = queue.removeFirst()
            let visible = next.visible && !next.view.isHidden && next.view.alpha >= 0.01
            if let field = consider(next.view, visible: visible) { return field }
            queue.append(contentsOf: next.view.subviews.map { (view: $0, visible: visible) })
        }
        var ancestor = view.superview
        while let current = ancestor {
            if let field = consider(current, visible: true) { return field }
            ancestor = current.superview
        }
        return visibleKeyInput ?? hiddenDocument ?? hiddenKeyInput
    }
}

/// Drives one `/type` request from the server thread: every UIKit touch hops to
/// main, and the pacing between characters happens HERE rather than on main —
/// the main thread has to stay free to run the formatter, the binding update and
/// the keyboard animation that a `--type-delay` exists to wait for.
enum TextInputSession {

    /// Per-character pacing is clamped: a delay long enough to look like a hang
    /// would hold the caller's HTTP request open with no way to say why.
    static let maxPerCharDelayMs = 2000

    static func run(_ request: TypeTextRequest) -> TypeTextResult {
        let resolution = MainThread.sync { TextInputEngine().focus(request) }
        guard case .ready(let target) = resolution else {
            if case .failed(let result) = resolution { return result }
            return TypeTextResult(typed: false, message: "unreachable")
        }

        let before = MainThread.sync { TextInputEngine().readText(target) }
        let secure = MainThread.sync { TextInputEngine().isSecure(target) }

        var cleared: TypeClearOutcome? = nil
        if request.clear {
            let outcome = MainThread.sync { TextInputEngine().clear(target) }
            cleared = outcome
            if !outcome.emptied {
                return TypeTextResult(
                    typed: false, ref: target.ref, typeName: target.typeName,
                    before: before, after: outcome.after, secure: secure, cleared: outcome,
                    message: "--clear did not empty the field, so typing now would APPEND to what is "
                        + "still there and report success — refusing"
                )
            }
        }

        let delay = min(max(request.perCharDelayMs ?? 0, 0), maxPerCharDelayMs)
        for (offset, character) in request.text.enumerated() {
            let landed = MainThread.sync { TextInputEngine().insert(String(character), into: target) }
            guard landed else {
                let after = MainThread.sync { TextInputEngine().readText(target) }
                return TypeTextResult(
                    typed: false, ref: target.ref, typeName: target.typeName, via: target.focusVia.map { "insertText+\($0)" } ?? "insertText",
                    before: before, after: after, secure: secure, cleared: cleared,
                    message: "focus-lost-after \(offset) of \(request.text.count) character(s): the field "
                        + "stopped being first responder mid-type (a formatter moving to the next box, or "
                        + "something else taking focus). The characters that landed are in `after`"
                )
            }
            if delay > 0 { Thread.sleep(forTimeInterval: Double(delay) / 1000.0) }
        }

        var submitted: String? = nil
        if request.submit {
            // A beat first: the app's own change handler runs on the main thread,
            // and a submit that races it reads the value before last keystroke.
            Thread.sleep(forTimeInterval: 0.05)
            submitted = MainThread.sync { TextInputEngine().submit(target) }
        }

        // Let the run loop turn once before reading back — a SwiftUI binding
        // lands on the next update, not inside `insertText`.
        Thread.sleep(forTimeInterval: 0.05)
        let after = MainThread.sync { TextInputEngine().readText(target) }
        return TypeTextResult(
            typed: true, ref: target.ref, typeName: target.typeName, via: target.focusVia.map { "insertText+\($0)" } ?? "insertText",
            before: before, after: after, secure: secure, cleared: cleared, submitted: submitted
        )
    }
}
#endif

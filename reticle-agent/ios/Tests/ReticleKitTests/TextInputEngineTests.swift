import XCTest
@testable import ReticleKit

/// In-process typing is only worth anything if the app cannot tell it from a
/// keypress — that is the whole difference between this and `mutate`, which
/// assigns `.text` and fires nothing. So these pin the SIDE EFFECTS (delegate,
/// `.editingChanged`, the return action), not just the resulting string.
@MainActor
final class TextInputEngineTests: XCTestCase {

    private var window: UIWindow!
    private var root: UIView!

    override func setUp() async throws {
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        root = window.rootViewController!.view
    }

    override func tearDown() async throws {
        window.resignKey()
        window.isHidden = true
        window = nil
        root = nil
    }

    private func makeField(secure: Bool = false) -> UITextField {
        let field = UITextField(frame: CGRect(x: 0, y: 0, width: 200, height: 40))
        field.isSecureTextEntry = secure
        root.addSubview(field)
        return field
    }

    /// Measured, and the reason `focus()` is not optional: `insertText` into a
    /// field that is NOT the first responder still lands the characters, but
    /// fires NOTHING — no `shouldChangeCharactersIn`, no `.editingChanged`, and
    /// `deleteBackward` does nothing at all. That is `mutate` behaviour wearing a
    /// keypress's name, so every test that asserts a side effect focuses first.
    private func focusedField(secure: Bool = false) throws -> UITextField {
        let field = makeField(secure: secure)
        guard field.becomeFirstResponder() else {
            throw XCTSkip("this process would not give the field first responder")
        }
        addTeardownBlock { @MainActor in field.resignFirstResponder() }
        return field
    }

    private func target(_ field: UIView & UITextInput) -> TextInputEngine.Target {
        TextInputEngine.Target(field: field, ref: "r1", typeName: NSStringFromClass(type(of: field)))
    }

    func testInsertGoesThroughTheDelegateAndEditingChanged() throws {
        let field = try focusedField()
        let delegate = RecordingDelegate()
        field.delegate = delegate
        var changes = 0
        field.addAction(UIAction { _ in changes += 1 }, for: .editingChanged)

        let engine = TextInputEngine()
        for character in "42" { engine.insert(String(character), into: target(field)) }

        XCTAssertEqual(field.text, "42")
        // The evidence that this is a keypress and not an assignment: UIKit asked
        // the delegate whether each character was allowed, and published the change.
        XCTAssertEqual(delegate.shouldChangeCalls, 2)
        XCTAssertEqual(changes, 2)
        // The range each ask carried is the caret's, advancing with the text —
        // a delegate that length-limits or masks reads it.
        XCTAssertEqual(delegate.ranges, [NSRange(location: 0, length: 0), NSRange(location: 1, length: 0)])
    }

    func testADelegateThatRejectsInputKeepsTheFieldEmpty() throws {
        // The honest failure mode: an app that filters keystrokes filters these
        // too, so the read-back — not the request — is what says what landed.
        let field = try focusedField()
        let delegate = RecordingDelegate()
        delegate.allow = false
        field.delegate = delegate

        XCTAssertFalse(TextInputEngine().insert("9", into: target(field)))
        XCTAssertEqual(field.text ?? "", "")
        XCTAssertEqual(delegate.shouldChangeCalls, 1)
    }

    func testClearEmptiesAndReportsWhatItDeleted() throws {
        let field = try focusedField()
        field.text = "123456"

        let outcome = TextInputEngine().clear(target(field))

        XCTAssertTrue(outcome.emptied)
        XCTAssertEqual(outcome.before, "123456")
        XCTAssertEqual(outcome.after, "")
        XCTAssertEqual(outcome.deletes, 6)
        XCTAssertEqual(field.text ?? "", "")
    }

    func testClearRefusesAFieldLongerThanTheDeleteLimit() throws {
        let field = try focusedField()
        field.text = String(repeating: "x", count: TextInputEngine.maxClearDeletes + 1)

        let outcome = TextInputEngine().clear(target(field))

        XCTAssertFalse(outcome.emptied)
        XCTAssertEqual(outcome.deletes, 0)
        XCTAssertTrue(outcome.unavailable?.hasPrefix("field-too-long") == true)
        // Refused, not half-done — the field still holds what it held.
        XCTAssertEqual(field.text?.count, TextInputEngine.maxClearDeletes + 1)
    }

    func testASecureFieldReadsBackMasked() throws {
        let field = try focusedField(secure: true)
        let engine = TextInputEngine()
        for character in "hunter2" { engine.insert(String(character), into: target(field)) }

        XCTAssertEqual(engine.readText(target(field)), "•••••••")
        XCTAssertTrue(engine.isSecure(target(field)))
    }

    func testSubmitFiresTheReturnKeysActionWithoutAReturnKey() throws {
        let field = try focusedField()
        let delegate = RecordingDelegate()
        field.delegate = delegate
        var exits = 0
        field.addAction(UIAction { _ in exits += 1 }, for: .editingDidEndOnExit)

        let via = TextInputEngine().submit(target(field))

        XCTAssertEqual(delegate.shouldReturnCalls, 1)
        XCTAssertEqual(exits, 1)
        XCTAssertEqual(via, "textFieldShouldReturn+editingDidEndOnExit")
    }

    func testSubmitSaysSoWhenTheFieldHasNoReturnAction() {
        // No delegate, no target: nothing to fire. Reported, not invented.
        XCTAssertEqual(TextInputEngine().submit(target(makeField())), "no-return-action")
    }

    func testATextViewSubmitInsertsTheNewlineItsReturnKeyWould() throws {
        let textView = UITextView(frame: CGRect(x: 0, y: 0, width: 200, height: 80))
        root.addSubview(textView)
        textView.text = "line"
        guard textView.becomeFirstResponder() else {
            throw XCTSkip("this process would not give the text view first responder")
        }
        defer { textView.resignFirstResponder() }

        XCTAssertEqual(TextInputEngine().submit(target(textView)), "newline")
        XCTAssertEqual(textView.text, "line\n")
    }

    func testTheFieldIsFoundUnderTheViewASelectorNames() {
        // A SwiftUI TextField and a UIKit form row both put the real field below
        // the node a selector resolves to.
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 60))
        let inner = UIView(frame: container.bounds)
        let field = UITextField(frame: CGRect(x: 0, y: 0, width: 200, height: 40))
        inner.addSubview(field)
        container.addSubview(inner)
        root.addSubview(container)

        XCTAssertTrue(TextInputEngine().textInput(in: container) === field)
    }

    func testAHiddenFieldIsUsedWhenItIsTheOnlyOne() {
        // This used to assert nil. A canvas toolkit's text input is an INVISIBLE
        // proxy — Compose Multiplatform parks a hidden `IntermediateTextInputUIView`
        // and draws the field itself — so excluding hidden views meant the only
        // real input on such a screen was the one thing never looked at, and every
        // field on it answered `unsupported_text_target`. Measured on a KMP app on
        // an iPhone 13 Pro Max / iOS 26.
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 60))
        let field = UITextField(frame: CGRect(x: 0, y: 0, width: 200, height: 40))
        field.isHidden = true
        container.addSubview(field)
        root.addSubview(container)

        XCTAssertTrue(TextInputEngine().textInput(in: container) === field)
    }

    func testAVisibleFieldWinsOverAHiddenOne() {
        // Visibility still RANKS candidates — it just no longer excludes them.
        // A form row that happens to contain a hidden field must not have the
        // typing aimed at it while the visible one sits beside it.
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 120))
        let hidden = UITextField(frame: CGRect(x: 0, y: 0, width: 200, height: 40))
        hidden.isHidden = true
        let visible = UITextField(frame: CGRect(x: 0, y: 60, width: 200, height: 40))
        container.addSubview(hidden)
        container.addSubview(visible)
        root.addSubview(container)

        XCTAssertTrue(TextInputEngine().textInput(in: container) === visible)
    }

    func testInsertRefusesAnUnfocusedFieldRatherThanAssignTextSilently() {
        let field = makeField()

        XCTAssertFalse(TextInputEngine().insert("9", into: target(field)))
        XCTAssertEqual(field.text ?? "", "")
    }

    func testClearAsksTheDelegateForEachBackspaceAndStopsWhenItRefuses() throws {
        let field = try focusedField()
        let delegate = RecordingDelegate()
        delegate.allow = false
        field.delegate = delegate
        field.text = "1234"

        let outcome = TextInputEngine().clear(target(field))

        XCTAssertFalse(outcome.emptied)
        XCTAssertEqual(delegate.replacements, [""])
        XCTAssertEqual(field.text, "1234")
    }

    func testClearRefusesAnUnfocusedFieldInsteadOfReportingAnEmptyOneItNeverEmptied() {
        // The measured trap this guards (see `focusedField`): `deleteBackward` on
        // an unfocused field is a no-op, so a clear that did not run must not read
        // like one that did.
        let field = makeField()
        field.text = "123456"

        let outcome = TextInputEngine().clear(target(field))

        XCTAssertFalse(outcome.emptied)
        XCTAssertEqual(outcome.unavailable, "field-not-focused")
        XCTAssertEqual(field.text, "123456")
    }

    func testAPlainViewIsNotATextTarget() {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 40))
        root.addSubview(view)

        XCTAssertNil(TextInputEngine().textInput(in: view))
    }
}

private final class RecordingDelegate: NSObject, UITextFieldDelegate {
    var shouldChangeCalls = 0
    var shouldReturnCalls = 0
    var ranges: [NSRange] = []
    var replacements: [String] = []
    var allow = true

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange,
                   replacementString string: String) -> Bool {
        shouldChangeCalls += 1
        ranges.append(range)
        replacements.append(string)
        return allow
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        shouldReturnCalls += 1
        return true
    }
}

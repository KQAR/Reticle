import Testing
@testable import ReticleHostCore

@Suite("iOS text typeability gate")
struct IosTextTests {
    @Test func printableAsciiIncludingSymbolsIsHidTypeable() {
        // The whole 0x20..0x7E range — letters, digits, and every symbol the
        // broadened HID keycode table now covers — must go through the HID path.
        #expect(IosText.isHidTypeable("Hello, World!"))
        #expect(IosText.isHidTypeable("aB3@#!_+:?/(x)[]{}|~`^&*=<>\"'"))
        #expect(IosText.isHidTypeable(" "))
    }

    @Test func nonAsciiIsNotHidTypeable() {
        // CJK, emoji, and accented Latin can't be emitted by the keyboard, so they
        // must route through the clipboard + paste path instead of being dropped.
        #expect(!IosText.isHidTypeable("中文测试"))
        #expect(!IosText.isHidTypeable("🎉"))
        #expect(!IosText.isHidTypeable("café"))
        #expect(!IosText.isHidTypeable("abc中"))
    }

    @Test func controlCharsAndEmptyAreNotHidTypeable() {
        // Newline/tab are below 0x20 (mirrors Android's gate); empty types nothing.
        #expect(!IosText.isHidTypeable("line1\nline2"))
        #expect(!IosText.isHidTypeable(""))
    }
}

import Foundation
import Testing
@testable import ReticleHostIos

/// The two devicectl JSON shapes `doctor` reads, and where it starts warning.
/// Field names are the ones devicectl printed on iOS 26.
@Suite("xctest attachments doctor check")
struct IosXCTestAttachmentsTests {

    @Test func keepsOnlyReachablePhysicalIOSDevices() {
        let json = """
        {"result":{"devices":[
          {"hardwareProperties":{"udid":"PHONE-1","platform":"iOS","reality":"physical"},
           "connectionProperties":{"tunnelState":"disconnected"},"deviceProperties":{"name":"Phone"}},
          {"hardwareProperties":{"udid":"PHONE-2","platform":"iOS","reality":"physical"},
           "connectionProperties":{"tunnelState":"unavailable"}},
          {"hardwareProperties":{"udid":"VM-1","platform":"iOS","reality":"virtual"},
           "connectionProperties":{"tunnelState":"connected"}},
          {"hardwareProperties":{"udid":"WATCH-1","platform":"watchOS","reality":"physical"},
           "connectionProperties":{"tunnelState":"connected"}}
        ]}}
        """
        let devices = IosXCTestAttachments.physicalDevices(fromList: Data(json.utf8))
        #expect(devices.map(\.0) == ["PHONE-1"])
        #expect(devices.first?.1 == "Phone")
    }

    @Test func sumsFilesUnderEitherAttachmentsRoot() {
        let json = """
        {"result":{"files":[
          {"relativePath":"Attachments","resources":{"isDirectory":true},"metadata":{}},
          {"relativePath":"Attachments/A/video.mp4","resources":{"isDirectory":false},"metadata":{"size":900000000}},
          {"relativePath":"Attachments/B/video.mp4","resources":{"isDirectory":false},"metadata":{"size":300000000}},
          {"relativePath":"tmp/Attachments/C.mp4","resources":{"isDirectory":false},"metadata":{"size":5}},
          {"relativePath":"Library/other.plist","resources":{"isDirectory":false},"metadata":{"size":7}}
        ]}}
        """
        let bytes = IosXCTestAttachments.bytesByRoot(fromFiles: Data(json.utf8))
        #expect(bytes == ["Attachments": 1_200_000_000, "tmp/Attachments": 5])
    }

    @Test func warnsOnlyAboveTheThresholdAndNamesEachRoot() {
        let small = IosXCTestAttachments.Finding(udid: "U", name: "N", bytesByRoot: ["Attachments": 10])
        #expect(IosXCTestAttachments.advice(small).isEmpty)

        let big = IosXCTestAttachments.Finding(udid: "U", name: "N",
                                               bytesByRoot: ["Attachments": 2_000_000_000])
        let lines = IosXCTestAttachments.advice(big)
        #expect(lines.first?.contains("2.0 GB") == true)
        #expect(lines.contains { $0.contains("--destination Attachments --remove-existing-content true") })
        #expect(!lines.contains { $0.contains("tmp/Attachments") })
    }

    @Test func anUnreadableDeviceIsReportedNotThrown() {
        let f = IosXCTestAttachments.Finding(udid: "U", name: "N", bytesByRoot: [:], error: "boom")
        #expect(IosXCTestAttachments.advice(f) == ["  N (U): xctest attachments unknown — boom"])
    }
}

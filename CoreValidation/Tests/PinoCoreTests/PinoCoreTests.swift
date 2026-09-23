import XCTest
@testable import PinoCore

final class PinoCoreTests: XCTestCase {
    func testActualHC24SNegativeService22Frame() throws {
        let raw = "22\r83 F1 11 7F 22 11 37\r>"
        let frames = KWPFrameParser.parseAll(raw)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].source, 0x11)
        XCTAssertEqual(frames[0].target, 0xF1)
        XCTAssertEqual(frames[0].negativeRequestSID, 0x22)
        XCTAssertEqual(frames[0].negativeResponseCode, 0x11)

        let c = KWPFrameParser.classify(command: "22", raw: raw)
        XCTAssertEqual(c.kind, .negative)
        XCTAssertEqual(c.nrc, 0x11)
    }

    func testActualHC24STesterPresentPositive() throws {
        let raw = "3E\r81 F1 11 7E 01\r>"
        let frames = KWPFrameParser.parseAll(raw)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].service, 0x7E)

        let c = KWPFrameParser.classify(command: "3E", raw: raw)
        XCTAssertEqual(c.kind, .positive)
    }

    func testAllObservedHC24SChecksums() {
        let frames = [
            "83 F1 11 7F 01 11 16",
            "83 F1 11 7F 10 11 25",
            "83 F1 11 7F 1A 11 2F",
            "83 F1 11 7F 21 11 36",
            "83 F1 11 7F 22 11 37",
            "83 F1 11 7F 23 11 38",
            "81 F1 11 7E 01"
        ]
        for f in frames {
            XCTAssertEqual(KWPFrameParser.parseAll(f).count, 1, "Failed: \(f)")
        }
    }

    func testDelayedMixedOutputStillFindsKWP() {
        let raw = """
        OKELM327 v2.1
        >
        BUS INIT:
        83 F1 11 7F 21 11 36
        >
        """
        let f = KWPFrameParser.parseAll(raw)
        XCTAssertEqual(f.count, 1)
        XCTAssertEqual(f[0].negativeRequestSID, 0x21)
    }

    func testCompactFrame() {
        let raw = "81F1117E01>"
        let f = KWPFrameParser.parseAll(raw)
        XCTAssertEqual(f.count, 1)
        XCTAssertEqual(f[0].service, 0x7E)
    }

    func testBadChecksumRejected() {
        XCTAssertTrue(KWPFrameParser.parseAll("83 F1 11 7F 22 11 00").isEmpty)
    }
}

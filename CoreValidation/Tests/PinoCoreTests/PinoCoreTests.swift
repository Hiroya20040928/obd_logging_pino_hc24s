import XCTest
@testable import PinoCore

final class PinoCoreTests: XCTestCase {
    func testActualHC24SNegativeService21Frame() {
        let raw = "83 F1 11 7F 21 11 36"
        let c = KWPFrameParser.classify(
            command: "2100",
            raw: raw
        )

        XCTAssertEqual(c.kind, .negative)
        XCTAssertEqual(c.nrc, 0x11)
    }

    func testActualHC24STesterPresentFrame() {
        let raw = "81 F1 11 7E 01"
        let c = KWPFrameParser.classify(
            command: "3E",
            raw: raw
        )

        XCTAssertEqual(c.kind, .positive)
        XCTAssertEqual(c.responseSID, 0x7E)
    }

    func testPayloadOnlyStartCommunicationPositive() {
        let c = KWPFrameParser.classify(
            command: "81",
            raw: "C1 8F EA\r>"
        )

        XCTAssertEqual(c.kind, .positive)
        XCTAssertEqual(c.responseSID, 0xC1)
    }

    func testPayloadOnly2100Positive() {
        var payload: [UInt8] = [0x61, 0x00]
        payload += Array(repeating: 0x00, count: 65)

        let raw = payload.map {
            String(format: "%02X", $0)
        }.joined()

        let c = KWPFrameParser.classify(
            command: "2100",
            raw: raw
        )

        XCTAssertEqual(c.kind, .positive)
        XCTAssertEqual(c.responseSID, 0x61)
    }

    func testSuzukiGenericDecode() {
        var data = Array(repeating: UInt8(0), count: 65)

        // 2000 rpm => raw 8000 => 0x1F40
        data[20] = 0x1F
        data[21] = 0x40
        data[14] = 120  // 80 C
        data[22] = 60
        data[24] = 65   // 25 C
        data[27] = 128
        data[41] = 200  // 100 kPa
        data[49] = 180  // 14.112 V

        let payload = [UInt8(0x61), 0x00] + data
        let raw = payload.map {
            String(format: "%02X", $0)
        }.joined()

        let s = SuzukiGenericLiveSnapshot.decode2100(
            raw: raw
        )

        XCTAssertNotNil(s)
        XCTAssertEqual(s?.rpm, 2000)
        XCTAssertEqual(s?.coolantC, 80)
        XCTAssertEqual(s?.speedKmh, 60)
        XCTAssertEqual(s?.intakeC, 25)
        XCTAssertEqual(s?.baroKpa, 100)
        XCTAssertEqual(s?.sanityScore, 6)
    }

    func testActualHC24SBadChecksumRejected() {
        XCTAssertTrue(
            KWPFrameParser.parseAll(
                "83 F1 11 7F 01 11 8B"
            ).isEmpty
        )
    }

    func testLongKWPFrameParsing() {
        let payload = [UInt8(0x61), 0x00]
            + Array(repeating: UInt8(0x01), count: 65)

        var frame: [UInt8] = [
            0x80,
            0xF1,
            0x11,
            UInt8(payload.count)
        ]
        frame += payload

        let checksum = UInt8(
            frame.reduce(0) {
                ($0 + Int($1)) & 0xFF
            }
        )
        frame.append(checksum)

        let raw = frame.map {
            String(format: "%02X", $0)
        }.joined(separator: " ")

        let parsed = KWPFrameParser.parseAll(raw)

        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].payload.first, 0x61)
        XCTAssertEqual(parsed[0].payload.count, 67)
    }
}

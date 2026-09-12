import XCTest
@testable import PinoCore

final class PinoCoreTests: XCTestCase {
    func makeFrame() -> String {
        var b = [UInt8](repeating: 0, count: 65)
        b[13] = 128; b[14] = 128; b[19] = 45
        let rpmRaw = Int(3200.0 / 0.25); b[20] = UInt8((rpmRaw >> 8) & 0xFF); b[21] = UInt8(rpmRaw & 0xFF)
        b[22] = 60; b[23] = 84; b[24] = 70
        let maf = 350; b[25] = UInt8((maf >> 8) & 0xFF); b[26] = UInt8(maf & 0xFF)
        b[27] = 51; b[29] = 160; b[35] = 80; b[36] = 40
        let pw1 = 2500; b[37] = UInt8((pw1 >> 8) & 0xFF); b[38] = UInt8(pw1 & 0xFF)
        let pw2 = 2600; b[39] = UInt8((pw2 >> 8) & 0xFF); b[40] = UInt8(pw2 & 0xFF)
        b[41] = 200; b[42] = 64; b[49] = 180
        return "61 00 " + b.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    func testDecodesKnownFrame() throws {
        let f = try XCTUnwrap(EngineFrame.decode(makeFrame()))
        XCTAssertEqual(f.payload.count, 65)
        XCTAssertEqual(f.rpm!, 3200, accuracy: 0.1)
        XCTAssertEqual(f.speedKmh!, 60, accuracy: 0.1)
        XCTAssertEqual(f.coolantC!, 88, accuracy: 0.1)
        XCTAssertEqual(f.mafGps!, 3.5, accuracy: 0.01)
        XCTAssertEqual(f.batteryV!, 14.112, accuracy: 0.001)
    }

    func testRejectsNegativeResponse() { XCTAssertNil(EngineFrame.decode("7F 21 12")) }
    func testNoiseDoesNotCorruptFrame() { XCTAssertNotNil(EngineFrame.decode("2100\rSEARCHING...\r" + makeFrame() + "\r>")) }
    func testCompactATS0FrameDecodes() {
        let compact = makeFrame().replacingOccurrences(of: " ", with: "")
        XCTAssertNotNil(EngineFrame.decode(compact + ">"))
    }
}

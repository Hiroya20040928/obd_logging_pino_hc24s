import XCTest
@testable import PinoCoreTests

fileprivate extension PinoCoreTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__PinoCoreTests = [
        ("testActualHC24SNegativeService22Frame", testActualHC24SNegativeService22Frame),
        ("testActualHC24STesterPresentPositive", testActualHC24STesterPresentPositive),
        ("testAllObservedHC24SChecksums", testAllObservedHC24SChecksums),
        ("testBadChecksumRejected", testBadChecksumRejected),
        ("testCompactFrame", testCompactFrame),
        ("testDelayedMixedOutputStillFindsKWP", testDelayedMixedOutputStillFindsKWP)
    ]
}
@available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
func __PinoCoreTests__allTests() -> [XCTestCaseEntry] {
    return [
        testCase(PinoCoreTests.__allTests__PinoCoreTests)
    ]
}
import XCTest
@testable import PocketAgentCore

/// The hat decoder is the one piece of input handling that differs between the two C-mode
/// variants, so it is pinned against the values actually captured in Phase 0.
final class HIDMappingTests: XCTestCase {
    // MARK: - Hat switch

    func testXInputVariantHatDecoding() {
        // Phase 0 §6.3: logical range [1,8], 0 = centred, odd values only.
        let min = 1, max = 8
        XCTAssertEqual(HIDMapping.direction(forHatValue: 1, logicalMin: min, logicalMax: max), .up)
        XCTAssertEqual(HIDMapping.direction(forHatValue: 3, logicalMin: min, logicalMax: max), .right)
        XCTAssertEqual(HIDMapping.direction(forHatValue: 5, logicalMin: min, logicalMax: max), .down)
        XCTAssertEqual(HIDMapping.direction(forHatValue: 7, logicalMin: min, logicalMax: max), .left)
        XCTAssertNil(HIDMapping.direction(forHatValue: 0, logicalMin: min, logicalMax: max), "0 is centred")
    }

    func testGenericVariantHatDecoding() {
        // Phase 0 §6.8: logical range [0,7], 15 = centred, even values only.
        let min = 0, max = 7
        XCTAssertEqual(HIDMapping.direction(forHatValue: 0, logicalMin: min, logicalMax: max), .up)
        XCTAssertEqual(HIDMapping.direction(forHatValue: 2, logicalMin: min, logicalMax: max), .right)
        XCTAssertEqual(HIDMapping.direction(forHatValue: 4, logicalMin: min, logicalMax: max), .down)
        XCTAssertEqual(HIDMapping.direction(forHatValue: 6, logicalMin: min, logicalMax: max), .left)
        XCTAssertNil(HIDMapping.direction(forHatValue: 15, logicalMin: min, logicalMax: max), "15 is centred")
    }

    func testDiagonalsAreNotGuessed() {
        // Values 2/4/6/8 exist in the XInput ring but this hardware never produced them.
        let min = 1, max = 8
        XCTAssertNil(HIDMapping.direction(forHatValue: 2, logicalMin: min, logicalMax: max))
        XCTAssertEqual(HIDMapping.direction(forHatValue: 2, logicalMin: min, logicalMax: max), nil)
    }

    func testHatDecodingRejectsImpossibleRange() {
        XCTAssertNil(HIDMapping.direction(forHatValue: 3, logicalMin: 5, logicalMax: 4))
    }

    // MARK: - Buttons

    func testButtonUsages() {
        XCTAssertEqual(HIDMapping.button(forButtonUsage: HIDMapping.buttonAUsage), .a)
        XCTAssertEqual(HIDMapping.button(forButtonUsage: HIDMapping.buttonBUsage), .b)
    }

    func testPairingKeyIsNeverMapped() {
        // Phase 0 Q7: the pairing key *is* exposed (usage 0x0d) but it switches the device variant
        // and powers the controller off, so it must stay unmapped.
        XCTAssertNil(HIDMapping.button(forButtonUsage: HIDMapping.pairingKeyUsage))
    }

    func testUnknownUsagesAreIgnored() {
        XCTAssertNil(HIDMapping.button(forButtonUsage: 0x00))
        XCTAssertNil(HIDMapping.button(forButtonUsage: 0xFF))
    }

    // MARK: - Value sanity

    func testOutOfRangeValuesAreRejected() {
        // Observed in H mode: a vendor element packed 82 and 44 into 21036 while logical max is 255.
        XCTAssertFalse(HIDMapping.isValueInRange(21036, logicalMin: 0, logicalMax: 255))
        XCTAssertTrue(HIDMapping.isValueInRange(128, logicalMin: 0, logicalMax: 255))
        XCTAssertTrue(HIDMapping.isValueInRange(0, logicalMin: 0, logicalMax: 255))
        XCTAssertTrue(HIDMapping.isValueInRange(255, logicalMin: 0, logicalMax: 255))
    }

    // MARK: - Device identity

    func testSupportedProducts() {
        XCTAssertTrue(HIDMapping.isSupportedProduct("Xbox Wireless Controller"))
        XCTAssertTrue(HIDMapping.isSupportedProduct("Wireless Controller"))
        XCTAssertFalse(HIDMapping.isSupportedProduct("IINE_keyboard"), "H mode is out of scope")
        XCTAssertFalse(HIDMapping.isSupportedProduct("DUALSHOCK 4"))
    }
}

import XCTest
@testable import PocketAgentCore

final class EventResolverTests: XCTestCase {
    private let resolver = EventResolver()

    func testTapAndHoldBothCancel() {
        XCTAssertEqual(resolver.triggers(for: .gesture(.tap(.b))), [.press(.cancelOrInterrupt)])
        XCTAssertEqual(resolver.triggers(for: .gesture(.hold(.b))), [.press(.cancelOrInterrupt)])
    }

    func testChordMappingTable() {
        XCTAssertEqual(
            resolver.triggers(for: .gesture(.chord(modifier: .b, key: .up))), [.press(.newChat)])
        XCTAssertEqual(
            resolver.triggers(for: .gesture(.chord(modifier: .b, key: .down))), [.press(.openTerminal)])
        XCTAssertEqual(
            resolver.triggers(for: .gesture(.chord(modifier: .b, key: .left))), [.press(.openModelPicker)])
        XCTAssertEqual(
            resolver.triggers(for: .gesture(.chord(modifier: .b, key: .right))), [.press(.queueFollowUp)])
        XCTAssertEqual(
            resolver.triggers(for: .gesture(.chord(modifier: .b, key: .a))), [.press(.inspectChanges)])
    }

    func testBaseLayerDirectionsMapToHeldActions() {
        XCTAssertEqual(resolver.triggers(for: .keyDown(.up)), [.down(.navigateUp)])
        XCTAssertEqual(resolver.triggers(for: .keyUp(.up)), [.up(.navigateUp)])
        XCTAssertEqual(resolver.triggers(for: .keyDown(.left)), [.down(.navigateLeft)])
        XCTAssertEqual(resolver.triggers(for: .keyUp(.right)), [.up(.navigateRight)])
    }

    func testSubmitIsAPressNotAHeldAction() {
        XCTAssertEqual(resolver.triggers(for: .keyDown(.a)), [.down(.submit)])
        XCTAssertEqual(resolver.triggers(for: .keyUp(.a)), [.up(.submit)])
    }

    func testRepeatPolicyMatchesSpec19() {
        for action in [AgentAction.navigateUp, .navigateDown, .navigateLeft, .navigateRight] {
            XCTAssertTrue(action.allowsRepeat, "\(action) may repeat")
        }
        let nonRepeating: [AgentAction] = [
            .submit, .cancelOrInterrupt, .queueFollowUp, .openModelPicker, .inspectChanges,
            .toggleFastMode, .openPermissionModeMenu, .newChat, .archiveChat, .pinThread,
            .forkThread, .openSideChat, .openTerminal,
        ]
        for action in nonRepeating {
            XCTAssertFalse(action.allowsRepeat, "\(action) must not repeat")
        }
    }

    func testOnlyNavigationCarriesNavigationRisk() {
        for action in AgentAction.allCases where action.allowsRepeat {
            XCTAssertEqual(action.risk, .navigation)
        }
        XCTAssertEqual(AgentAction.submit.risk, .normal)
        XCTAssertEqual(AgentAction.cancelOrInterrupt.risk, .normal)
        XCTAssertEqual(AgentAction.openPermissionModeMenu.risk, .sensitive)
    }

    func testApproveAndRejectShareSubmitAndCancel() {
        // Deliberate: Codex and Claude both approve with Enter and decline with Escape, so adding
        // separate approve/reject actions would mean two actions competing for one key.
        XCTAssertFalse(AgentAction.allCases.contains { $0.rawValue == "approve" })
        XCTAssertFalse(AgentAction.allCases.contains { $0.rawValue == "reject" })
    }

    func testPermissionModeIsNoLongerNamedAsACycle() {
        XCTAssertNil(AgentAction(rawValue: "cyclePermissionMode"), "renamed to openPermissionModeMenu")
        XCTAssertNotNil(AgentAction(rawValue: "openPermissionModeMenu"))
    }

    func testUnknownBindingsProduceNothing() {
        let resolver = EventResolver(bindings: GestureBindings(base: [:], bLayer: [:]))
        XCTAssertEqual(resolver.triggers(for: .keyDown(.up)), [])
        XCTAssertEqual(resolver.triggers(for: .gesture(.tap(.b))), [])
    }
}

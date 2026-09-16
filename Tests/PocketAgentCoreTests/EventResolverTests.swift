import XCTest
@testable import PocketAgentCore

final class EventResolverTests: XCTestCase {
    private let resolver = EventResolver()

    func testBHasTwoGesturesWithDifferentMeanings() {
        // Changed on 2026-09-16: a tap of B is still Escape/decline, but a *hold* is now the
        // cross-app switch. Both gestures come from the same button, so this is the test that
        // pins down which one does what.
        XCTAssertEqual(resolver.triggers(for: .gesture(.tap(.b))), [.press(.cancelOrInterrupt)])
        XCTAssertEqual(resolver.triggers(for: .gesture(.hold(.b))), [.press(.focusOtherAgent)])
    }

    func testBHoldFallsBackToTheBaseBindingWhenUnset() {
        // `bHold` is optional so a caller that builds bindings by hand keeps the old behaviour
        // instead of silently losing the hold gesture.
        let bindings = GestureBindings(
            base: [.b: .cancelOrInterrupt],
            bLayer: [.up: .goToRecentChat1],
            bHold: nil
        )
        let resolver = EventResolver(bindings: bindings)
        XCTAssertEqual(resolver.triggers(for: .gesture(.hold(.b))), [.press(.cancelOrInterrupt)])
        XCTAssertEqual(resolver.triggers(for: .gesture(.tap(.b))), [.press(.cancelOrInterrupt)])
    }

    func testChordMappingTable() {
        // Default map: two recent chats plus the three permanently useful commands.
        XCTAssertEqual(
            resolver.triggers(for: .gesture(.chord(modifier: .b, key: .up))), [.press(.goToRecentChat1)])
        XCTAssertEqual(
            resolver.triggers(for: .gesture(.chord(modifier: .b, key: .down))), [.press(.goToRecentChat2)])
        XCTAssertEqual(
            resolver.triggers(for: .gesture(.chord(modifier: .b, key: .left))), [.press(.openMenu)])
        XCTAssertEqual(
            resolver.triggers(for: .gesture(.chord(modifier: .b, key: .right))), [.press(.nextChatNeedingAttention)])
        XCTAssertEqual(
            resolver.triggers(for: .gesture(.chord(modifier: .b, key: .a))), [.press(.inspectChanges)])
    }

    func testDefaultBLayerCoversEverySecondaryKey() {
        // Every key that can form a chord must appear in the default B layer, or a gesture would
        // silently do nothing.
        for key in PhysicalButton.allCases where key != .b {
            XCTAssertNotNil(GestureBindings.default.bLayer[key], "B + \(key.rawValue) is unbound")
        }
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

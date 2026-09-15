import XCTest
@testable import PocketAgentCore

/// Covers the gesture cases required by spec §20.1, plus the timing edges the thresholds create.
final class GestureRecognizerTests: XCTestCase {
    private let tapMax = 0.220
    private let hold = 0.450

    // MARK: - Tap

    func testBTapIsATap() {
        let harness = Harness()
        harness.press(.b)
        harness.advance(to: 0.100)
        harness.release(.b)

        XCTAssertEqual(harness.gestures, [.tap(.b)])
        XCTAssertEqual(harness.emitted, [.gesture(.tap(.b))])
    }

    func testBSlowReleaseBecomesAHold() {
        let harness = Harness()
        harness.press(.b)
        harness.advance(to: 0.300) // past tapMax, before the hold threshold
        harness.release(.b)

        XCTAssertEqual(harness.gestures, [.hold(.b)])
    }

    func testBHeldPastThresholdThenReleasedIsAHold() {
        let harness = Harness()
        harness.press(.b)
        harness.advance(to: 0.500) // hold timer fires: B becomes a modifier
        XCTAssertEqual(harness.gestures, [], "becoming a modifier emits nothing on its own")

        harness.release(.b)
        XCTAssertEqual(harness.gestures, [.hold(.b)])
    }

    func testBHeldAtExactlyTapThresholdIsStillATap() {
        let harness = Harness()
        harness.press(.b)
        harness.advance(to: tapMax)
        harness.release(.b)

        XCTAssertEqual(harness.gestures, [.tap(.b)])
    }

    // MARK: - Chords (spec §6.2)

    func testBPlusUpIsNewChat() {
        assertChord(.up, resolvesTo: .newChat)
    }

    func testBPlusDownIsOpenTerminal() {
        assertChord(.down, resolvesTo: .openTerminal)
    }

    func testBPlusLeftIsModelPicker() {
        assertChord(.left, resolvesTo: .openModelPicker)
    }

    func testBPlusRightIsQueueFollowUp() {
        assertChord(.right, resolvesTo: .queueFollowUp)
    }

    func testBPlusAIsInspectChanges() {
        assertChord(.a, resolvesTo: .inspectChanges)
    }

    func testChordDoesNotEmitEscape() {
        let harness = Harness()
        harness.press(.b)
        harness.advance(to: 0.050)
        harness.press(.up)
        harness.advance(to: 0.100)
        harness.release(.up)
        harness.advance(to: 0.120)
        harness.release(.b)

        XCTAssertEqual(harness.gestures, [.chord(modifier: .b, key: .up)])
        XCTAssertFalse(
            harness.emitted.contains(.gesture(.tap(.b))) || harness.emitted.contains(.gesture(.hold(.b))),
            "a chord must suppress B's own Escape"
        )
    }

    func testHeldChordFiresExactlyOnce() {
        let harness = Harness()
        harness.press(.b)
        harness.press(.up) // chord fires here
        harness.advance(to: 5.0) // keep holding both well past every threshold

        XCTAssertEqual(harness.gestures, [.chord(modifier: .b, key: .up)])
        XCTAssertEqual(harness.emitted.count, 1, "a held chord must not repeat")
    }

    func testChordWorksBeforeTheModifierThreshold() {
        let harness = Harness()
        harness.press(.b)
        harness.press(.up) // immediate: BPending is enough per spec §18
        XCTAssertEqual(harness.gestures, [.chord(modifier: .b, key: .up)])
    }

    func testExtraKeysDuringAChordAreIgnored() {
        let harness = Harness()
        harness.press(.b)
        harness.press(.up)
        harness.press(.down)
        harness.press(.a)
        harness.release(.b)
        harness.release(.down)
        harness.release(.a)
        harness.release(.up)

        XCTAssertEqual(harness.gestures, [.chord(modifier: .b, key: .up)])
    }

    /// Verified on hardware 2026-09-16: holding B and tapping several directions in turn fires one
    /// chord per tap, because the modifier is still down when each new key goes down. The B layer
    /// therefore behaves like a held modifier (Shift-style), not like a one-shot prefix.
    func testHoldingBAllowsSeveralChordsInSequence() {
        let harness = Harness()
        harness.press(.b)
        harness.press(.down)
        harness.release(.down)
        harness.press(.left)
        harness.release(.left)
        harness.press(.right)
        harness.release(.right)
        harness.release(.b)

        XCTAssertEqual(harness.gestures, [
            .chord(modifier: .b, key: .down),
            .chord(modifier: .b, key: .left),
            .chord(modifier: .b, key: .right),
        ])
        XCTAssertFalse(
            harness.emitted.contains(.gesture(.hold(.b))),
            "a B release after chords must not also emit Escape"
        )
    }

    // MARK: - Base layer

    func testDirectionProducesKeyDownAndKeyUp() {
        let harness = Harness()
        harness.press(.up)
        XCTAssertEqual(harness.emitted, [.keyDown(.up)])

        harness.advance(to: 1.0)
        harness.release(.up)
        XCTAssertEqual(harness.emitted, [.keyDown(.up), .keyUp(.up)])
    }

    func testRepeatedDirectionPressIsNotDuplicated() {
        let harness = Harness()
        harness.press(.up)
        harness.press(.up) // e.g. a noisy duplicate report
        XCTAssertEqual(harness.emitted, [.keyDown(.up)])
    }

    func testSubmitIsAOneShotPressThatCanNeverRepeat() {
        let harness = Harness()
        harness.press(.a)
        XCTAssertEqual(harness.emitted, [.keyDown(.a), .keyUp(.a)])

        harness.advance(to: 10.0) // A is still held
        XCTAssertEqual(harness.emitted.count, 2, "holding A must not repeat a submit")

        harness.release(.a)
        XCTAssertEqual(harness.emitted.count, 2)
    }

    func testDirectionHeldBeforeBIsReleasedNormally() {
        let harness = Harness()
        harness.press(.up)
        harness.press(.b) // B arrives while a direction is already down: not a chord
        harness.release(.up)

        XCTAssertEqual(harness.emitted, [.keyDown(.up), .keyUp(.up)])
        XCTAssertEqual(harness.gestures, [], "no chord, because the direction did not go down during B")
    }

    // MARK: - Reset (spec §17/§18: reconnect, sleep, focus loss)

    func testResetReleasesHeldDirections() {
        let harness = Harness()
        harness.press(.up)
        harness.press(.left)

        let released = harness.recognizer.reset()

        XCTAssertEqual(released, [.keyUp(.left), .keyUp(.up)])
    }

    func testResetClearsPendingBSoItsReleaseEmitsNothing() {
        let harness = Harness()
        harness.press(.b)
        harness.recognizer.reset()
        harness.release(.b)

        XCTAssertEqual(harness.gestures, [], "after a reset, a stale B release must not fire Escape")
    }

    func testResetCancelsTheHoldTimer() {
        let harness = Harness()
        harness.press(.b)
        harness.recognizer.reset()
        harness.advance(to: 5.0)
        harness.release(.b)

        XCTAssertEqual(harness.emitted, [])
    }

    func testResetAfterAChordIsIdempotent() {
        let harness = Harness()
        harness.press(.b)
        harness.press(.up)
        _ = harness.recognizer.reset()
        _ = harness.recognizer.reset()

        harness.advance(to: 5.0)
        XCTAssertEqual(harness.gestures, [.chord(modifier: .b, key: .up)])
    }

    // MARK: - Helpers

    private func assertChord(
        _ key: PhysicalButton,
        resolvesTo action: AgentAction,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let harness = Harness()
        harness.press(.b)
        harness.advance(to: 0.100)
        harness.press(key)
        harness.advance(to: 0.150)

        XCTAssertEqual(harness.gestures, [.chord(modifier: .b, key: key)], file: file, line: line)

        let resolver = EventResolver()
        let actions = resolver.triggers(for: harness.emitted).map { $0.action }
        XCTAssertEqual(actions, [action], file: file, line: line)
    }
}

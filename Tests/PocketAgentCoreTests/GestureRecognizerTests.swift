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

    func testBSlowReleaseBeforeTheHoldThresholdIsStillATap() {
        // `tapMaxMs` no longer decides tap-vs-hold on its own: `holdMs` does, because a hold now
        // switches applications. 300 ms is a slow tap, not a hold — and definitely not an app switch.
        let harness = Harness()
        harness.press(.b)
        harness.advance(to: 0.300) // past tapMax, before the hold threshold
        harness.release(.b)

        XCTAssertEqual(harness.gestures, [.tap(.b)])
    }

    func testBReleasedExactlyAtTheHoldThresholdIsAHold() {
        let harness = Harness()
        harness.press(.b)
        harness.advance(to: hold) // the hold timer fires here
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

    func testFinishVoiceInputAfterALongBHoldDoesNotAlsoEmitEscape() {
        // Found while fixing the app-switch threshold (2026-09-16): once B passes `holdMs` the state
        // is "ready because the timer fired", and a chord that then takes the press used to leave
        // that flag set, so releasing B fired the hold *and* the chord emitted a stray Escape at the
        // end of a voice input.
        let harness = Harness()
        harness.press(.b)
        harness.advance(to: 0.600)        // past holdMs: B is a modifier now
        harness.press(.a)                 // push-to-talk chord
        harness.advance(to: 0.700)
        harness.release(.a)
        harness.advance(to: 1.400)
        harness.release(.b)

        XCTAssertEqual(harness.actionGestures, [.chord(modifier: .b, key: .a)])
        XCTAssertFalse(
            harness.emitted.contains(.gesture(.hold(.b))),
            "a chord takes the press from B: the hold timer firing first must not still switch apps"
        )
        XCTAssertFalse(
            harness.emitted.contains(.gesture(.tap(.b))),
            "finishing a chord must not also send Escape"
        )
    }

    func testPushToTalkWorksWhenBWasHeldWellPastTheThreshold() {
        // Reconstructed from a real session (2026-09-16): the user holds B for ~840 ms and only then
        // presses A — the natural push-to-talk grip, and the one they had been using all along.
        // Once a hold meant "switch applications", the 450 ms timer fired long before A arrived, so
        // every one of those attempts switched apps instead of starting voice input. The chord has to
        // win over the hold timer, however long B has been down.
        let harness = Harness()
        harness.press(.b)
        harness.advance(to: 0.840)          // hold timer fired at 0.450
        harness.press(.a)
        harness.advance(to: 0.900)
        harness.release(.a)
        harness.advance(to: 1.500)
        harness.release(.b)

        XCTAssertEqual(harness.actionGestures, [.chord(modifier: .b, key: .a)])
        XCTAssertFalse(
            harness.emitted.contains(.gesture(.hold(.b))),
            "a long B press that becomes a chord must never also switch applications"
        )
    }

    func testBIsIgnoredWhileAIsAlreadyHeld() {
        // The mirror image: release A during push-to-talk, then press and release B. B used to start
        // its own press here, so the tail of a voice input ended in an app switch.
        let harness = Harness()
        harness.press(.b)
        harness.advance(to: 0.050)
        harness.press(.a)
        harness.advance(to: 0.100)
        harness.release(.a)
        harness.advance(to: 0.120)
        harness.press(.b)                 // spurious; A was held when this arrived
        harness.advance(to: 1.000)
        harness.release(.b)

        XCTAssertFalse(
            harness.emitted.contains(.gesture(.hold(.b))),
            "a B press that arrives while A is down must not become an app switch"
        )
    }

    func testBPlusUpJumpsToRecentChat1() {
        assertChord(.up, resolvesTo: .goToRecentChat1)
    }

    func testBPlusDownJumpsToRecentChat2() {
        assertChord(.down, resolvesTo: .goToRecentChat2)
    }

    func testBPlusLeftOpensTheMenu() {
        // Changed 2026-09-16: 新建会话 moved into the menu, and this chord now opens it. The menu
        // is how the gesture set stops being the ceiling on what the controller can reach.
        assertChord(.left, resolvesTo: .openMenu)
    }

    func testBPlusRightJumpsToTheChatNeedingAttention() {
        assertChord(.right, resolvesTo: .nextChatNeedingAttention)
    }

    func testBPlusAInspectsChanges() {
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

        XCTAssertEqual(harness.actionGestures, [.chord(modifier: .b, key: .up)])
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

        XCTAssertEqual(harness.actionGestures, [.chord(modifier: .b, key: .up)])
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

        XCTAssertEqual(harness.actionGestures, [
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

    // MARK: - Chord release (held bindings only)

    /// A held binding — e.g. `⌥⇧` for an input method's voice input — needs to know when the chord
    /// ends. Semantic-action chords must ignore it, which is what keeps them one-shot.
    func testReleasingTheChordKeyEmitsAChordRelease() {
        let harness = Harness()
        harness.press(.b)
        harness.press(.a)
        harness.release(.a)

        XCTAssertEqual(harness.actionGestures, [.chord(modifier: .b, key: .a)])
        XCTAssertEqual(harness.chordReleases, [.chordReleased(modifier: .b, key: .a)])
    }

    func testChordReleaseIsNotEmittedWhenThereWasNoChord() {
        let harness = Harness()
        harness.press(.a) // no B involved
        harness.release(.a)
        XCTAssertEqual(harness.chordReleases, [])
    }

    func testDisconnectMidChordReleasesTheHeldChord() {
        // Otherwise a modifier-only binding stays held forever and the user's keyboard is stuck.
        let harness = Harness()
        harness.press(.b)
        harness.press(.a)

        let released = harness.recognizer.reset()

        XCTAssertEqual(released, [.gesture(.chordReleased(modifier: .b, key: .a))])
    }

    func testDisconnectReleasesBothAHeldDirectionAndAHeldChord() {
        let harness = Harness()
        harness.press(.left)
        harness.press(.b)
        harness.press(.a)

        let released = harness.recognizer.reset()

        XCTAssertEqual(released, [
            .gesture(.chordReleased(modifier: .b, key: .a)),
            .keyUp(.left),
        ])
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

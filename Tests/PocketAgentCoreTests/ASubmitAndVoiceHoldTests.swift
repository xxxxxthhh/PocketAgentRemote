import XCTest
@testable import PocketAgentCore

/// A's two lives (D-A): a one-shot `submit` and a held push-to-talk, told apart by `aHoldMs`.
///
/// The question this suite settles is **when** each one commits, and whether the two can ever
/// overlap — a stray `Enter` in the middle of voice input, or a voice modifier left down after the
/// press that started it is over. Both halves are pinned here:
///
/// - the timing edges go through the recognizer alone (`Harness`), because a threshold race has no
///   business depending on the dispatcher;
/// - the pairing promises go through the real engine and dispatcher with a `SpyEmitter`, because a
///   modifier that stays down is only observable at the emitter.
///
/// Note on the clock: an event's `timestamp` does **not** move `ManualScheduler`. That is the point
/// of `testAtTheThresholdTheReleaseWinsWhenItArrivesFirst` — the two can disagree, and which one
/// the recognizer believes decides whether the press was a submit or a hold.
final class ASubmitAndVoiceHoldTests: XCTestCase {
    /// `GestureConfiguration.default.aHoldMs`, in seconds.
    private let threshold: TimeInterval = 0.220

    // MARK: - Recognizer-only: the threshold edges

    private func voiceHarness() -> Harness {
        let harness = Harness()
        harness.recognizer.aHoldEnabled = true
        return harness
    }

    /// One millisecond short of the threshold is still a submit, and the hold gesture never starts.
    func testReleasingOneMillisecondBeforeTheThresholdIsASubmit() {
        let harness = voiceHarness()
        harness.press(.a)
        harness.advance(to: threshold - 0.001)
        harness.release(.a)

        XCTAssertEqual(harness.emitted, [.keyDown(.a), .keyUp(.a)], "just inside the window is a submit")
        XCTAssertEqual(harness.gestures, [], "no hold gesture may have started")
    }

    /// At the threshold with the timer arriving first: a hold, and no submit for that press.
    func testAtTheThresholdTheTimerWinsWhenItFiresFirst() {
        let harness = voiceHarness()
        harness.press(.a)
        harness.advance(to: threshold)          // the timer fires here
        harness.release(.a)

        XCTAssertEqual(harness.gestures, [.holdBegan(.a), .holdEnded(.a)])
        XCTAssertFalse(harness.emitted.contains(.keyDown(.a)), "a hold must never submit")
    }

    /// At the threshold with the *release* arriving first: a submit, and the timer that fires
    /// afterwards must find nothing to do — one press can produce one outcome, never both.
    func testAtTheThresholdTheReleaseWinsWhenItArrivesFirst() {
        let harness = voiceHarness()
        harness.press(.a)
        // Straight to the recognizer: the event carries the threshold timestamp, but the scheduler
        // has not moved, so the release is what the recognizer sees first.
        harness.recognizer.handle(.released(.a, timestamp: threshold))
        harness.advance(to: threshold)          // the timer now runs, too late to matter

        XCTAssertEqual(harness.emitted, [.keyDown(.a), .keyUp(.a)])
        XCTAssertEqual(harness.gestures, [], "the timer must not start a hold for a finished press")
    }

    /// Released well past the threshold: still exactly one `holdBegan`/`holdEnded` pair.
    func testReleasingLongAfterTheThresholdIsOnlyAHold() {
        let harness = voiceHarness()
        harness.press(.a)
        harness.advance(to: 3.0)
        harness.release(.a)

        XCTAssertEqual(harness.gestures, [.holdBegan(.a), .holdEnded(.a)])
        XCTAssertFalse(harness.emitted.contains(.keyDown(.a)))
    }

    /// A second A press with no release in between (a source that repeats, or a flaky pad) must not
    /// double anything up: one press down, one gesture, one end.
    func testARepeatedAPressWhileTheFirstIsStillDownIsNotDuplicated() {
        let harness = voiceHarness()
        harness.press(.a)
        harness.advance(to: 0.100)
        harness.press(.a)                       // no release in between
        harness.advance(to: threshold)

        // The threshold is measured from the *first* press: a repeat that re-armed the timer would
        // push it out to 0.100 + 0.220 and the hold would not have started yet.
        XCTAssertEqual(
            harness.gestures, [.holdBegan(.a)],
            "the repeat must not re-arm the hold timer"
        )

        harness.advance(to: 3.0)
        harness.release(.a)

        XCTAssertEqual(
            harness.gestures, [.holdBegan(.a), .holdEnded(.a)],
            "a repeated press must not start a second hold"
        )
        XCTAssertFalse(harness.emitted.contains(.keyDown(.a)), "and must not submit either")
    }

    /// The same repeat, but arriving after the hold has already begun — the case that can emit a
    /// second `holdBegan` and leave the modifier's down/up unpaired.
    func testARepeatedAPressDuringAHoldDoesNotStartASecondHold() {
        let harness = voiceHarness()
        harness.press(.a)
        harness.advance(to: threshold)          // holdBegan
        harness.press(.a)                       // repeat while already holding
        harness.advance(to: 3.0)
        harness.release(.a)

        XCTAssertEqual(
            harness.gestures, [.holdBegan(.a), .holdEnded(.a)],
            "one physical press is one hold: began once, ended once"
        )
    }

    // MARK: - Engine + dispatcher: what actually reaches the app

    private let codex = "com.openai.codex"
    private let claude = "com.anthropic.claudefordesktop"
    /// The default `a.hold` binding: hold right ⌥ for the whole press.
    private let voiceKey = KeyStroke(modifiers: [.rightOption])

    private func makeRig() -> EngineRig { makeEngineRig(frontmostBundleID: codex) }

    /// Holds A past the threshold and checks the voice key went down — the starting point for every
    /// "…and then something changed" case below.
    private func startVoiceHold(_ rig: EngineRig) {
        rig.press(.a, at: 0)
        XCTAssertEqual(rig.emitter.emissions, [], "A's press must not submit while it may become a hold")
        rig.scheduler.advance(to: threshold)
        XCTAssertEqual(
            rig.emitter.emissions, [.init(phase: .down, stroke: voiceKey)],
            "crossing the threshold must hold the voice key. Log: \(rig.log())"
        )
    }

    /// Exactly one down/up pair of the voice key, and never an Enter.
    private func assertVoiceKeyPaired(
        _ rig: EngineRig,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            rig.emitter.emissions,
            [.init(phase: .down, stroke: voiceKey), .init(phase: .up, stroke: voiceKey)],
            "\(message). Log: \(rig.log())",
            file: file, line: line
        )
        XCTAssertFalse(
            rig.emitter.strokes.contains(KeyStroke(.enter)),
            "\(message): a hold must never submit",
            file: file, line: line
        )
    }

    /// The acceptance line for a short tap: nothing on the way down, exactly one Enter pair on the
    /// way up. The submit is *decided and sent on release* — see the report's ① accounting.
    func testShortTapSendsNoEnterOnTheWayDownAndExactlyOnePairOnRelease() {
        let rig = makeRig()
        defer { rig.engine.stop() }

        rig.press(.a, at: 0)
        XCTAssertEqual(rig.emitter.emissions, [], "zero Enter while A is down. Log: \(rig.log())")

        rig.release(.a, at: 0.08)
        XCTAssertEqual(
            rig.emitter.emissions,
            [.init(phase: .down, stroke: .key(.enter)), .init(phase: .up, stroke: .key(.enter))],
            "exactly one Enter down/up pair, on release. Log: \(rig.log())"
        )
    }

    /// A press cancelled before the threshold (reset: menu opened, sleep, focus loss) must not
    /// submit — not then, and not when the physical release finally arrives.
    func testCancellingAPendingPressNeverSubmits() {
        let rig = makeRig()
        defer { rig.engine.stop() }

        rig.press(.a, at: 0)
        rig.engine.recognizer.resetAndEmit()
        XCTAssertEqual(rig.emitter.emissions, [], "a cancelled press must not submit. Log: \(rig.log())")

        rig.release(.a, at: 0.08)
        XCTAssertEqual(rig.emitter.emissions, [], "nor may its release. Log: \(rig.log())")
    }

    /// A reset *during* the hold has to release the voice key, once — the modifier is already down
    /// in the target app, so dropping the state silently would strand it.
    func testResetDuringAHoldReleasesTheVoiceKeyExactlyOnce() {
        let rig = makeRig()
        defer { rig.engine.stop() }

        startVoiceHold(rig)
        rig.engine.recognizer.resetAndEmit()
        assertVoiceKeyPaired(rig, "a reset mid-hold must release the voice key")

        rig.release(.a, at: 2.0)
        assertVoiceKeyPaired(rig, "the real release must not release it a second time")
    }

    /// The controller vanishing before the threshold: nothing was sent, so nothing may be.
    func testDetachDuringAPendingPressEmitsNothing() {
        let rig = makeRig()
        defer { rig.engine.stop() }

        rig.press(.a, at: 0)
        rig.source.onDetach?("Wireless Controller")
        XCTAssertEqual(rig.emitter.emissions, [], "a detach must not submit. Log: \(rig.log())")

        rig.release(.a, at: 0.08)
        XCTAssertEqual(rig.emitter.emissions, [], "nor may the release that follows it")
    }

    /// The controller vanishing *during* the hold: the voice key must come back up, or the user's
    /// session inherits a stuck ⌥.
    func testDetachDuringAHoldReleasesTheVoiceKeyExactlyOnce() {
        let rig = makeRig()
        defer { rig.engine.stop() }

        startVoiceHold(rig)
        rig.source.onDetach?("Wireless Controller")
        assertVoiceKeyPaired(rig, "a detach mid-hold must release the voice key")

        rig.release(.a, at: 2.0)
        assertVoiceKeyPaired(rig, "the release after the detach must not emit again")
    }

    // MARK: - ③ The binding changing while the hold is in flight

    /// The frontmost app moves mid-hold but the table is unchanged: the voice key is a global
    /// modifier-only stroke, so it is still released normally.
    func testFrontmostChangingMidHoldStillReleasesTheVoiceKey() {
        let rig = makeRig()
        defer { rig.engine.stop() }

        startVoiceHold(rig)
        rig.frontmost.bundleID = claude
        rig.release(.a, at: 2.0)

        assertVoiceKeyPaired(rig, "a frontmost change must not strand the voice key")
    }

    /// The binding is *re-pointed* mid-hold (config reload, manual profile switch). The release must
    /// use the stroke that actually went down, not whatever the table says now.
    func testOverrideRepointedMidHoldStillReleasesTheStrokeThatWentDown() {
        let rig = makeRig()
        defer { rig.engine.stop() }

        startVoiceHold(rig)
        rig.engine.gestureOverrides = [
            "a.hold": GestureOverride(stroke: KeyStroke(modifiers: [.option]), isHeld: true)
        ]
        rig.release(.a, at: 2.0)

        assertVoiceKeyPaired(rig, "the release must key-up the stroke that went down (right ⌥)")
    }

    /// The binding is *removed* mid-hold. The press still has a key down in the target app, so its
    /// release cannot simply resolve to nothing.
    func testOverrideRemovedMidHoldStillReleasesTheStroke() {
        let rig = makeRig()
        defer { rig.engine.stop() }

        startVoiceHold(rig)
        rig.engine.gestureOverrides = [:]
        rig.release(.a, at: 2.0)

        assertVoiceKeyPaired(rig, "losing the binding must not strand the voice key")
    }

    /// The automatic-profile path: the table is re-resolved from the frontmost app before every
    /// event, so moving to an app with a different `a.hold` swaps the table between `holdBegan` and
    /// `holdEnded` without anyone touching the config.
    func testAutomaticProfileSwitchMidHoldStillReleasesTheStrokeThatWentDown() {
        let rig = makeRig()
        defer { rig.engine.stop() }

        let perApp: [String: [String: GestureOverride]] = [
            codex: ["a.hold": GestureOverride(stroke: KeyStroke(modifiers: [.rightOption]), isHeld: true)],
            claude: ["a.hold": GestureOverride(stroke: KeyStroke(modifiers: [.option]), isHeld: true)],
        ]
        rig.engine.gestureOverridesProvider = { [weak rigFrontmost = rig.frontmost] in
            perApp[rigFrontmost?.bundleID ?? ""] ?? [:]
        }

        startVoiceHold(rig)
        rig.frontmost.bundleID = claude          // the next event re-resolves the table
        rig.release(.a, at: 2.0)

        assertVoiceKeyPaired(rig, "a profile switch mid-hold must still release right ⌥ (not the left one)")
    }
}

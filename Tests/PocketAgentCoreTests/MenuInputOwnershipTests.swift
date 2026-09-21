import XCTest
@testable import PocketAgentCore

/// Who owns a button press once a menu is involved (D-MENU).
///
/// The rule under test is "whoever consumed the press finishes it": a press that opened, navigated,
/// or ran the menu must not also reach the app behind it, and its *release* — which arrives after
/// the recognizer's state was already cleared, or after the menu is gone entirely — must produce
/// nothing at all. The one exception is cleanup: a key this process actually put down (a held
/// direction, a held voice modifier) has to come back up exactly once when the menu takes over.
///
/// Everything runs through the real `ControllerEngine`, the real `GestureRecognizer` and the real
/// `ActionDispatcher` (the shared `EngineRig`), with the recording emitter as the only stand-in: the
/// leaks this pins are made of the wiring *between* those three, so replacing any of them with a
/// stub would test the stub.
final class MenuInputOwnershipTests: XCTestCase {
    private let codex = "com.openai.codex"
    private let safari = "com.apple.Safari"

    private func makeRig(configure: (inout AppConfig) -> Void = { _ in }) -> EngineRig {
        makeEngineRig(frontmostBundleID: codex, configure: configure)
    }

    // MARK: - Injection helpers

    /// Opens the command menu the way the user does: hold B, tap ←. Leaves both buttons **down**.
    private func openWithBLeft(_ rig: EngineRig) {
        rig.press(.b, at: 0)
        rig.press(.left, at: 0.05)
        XCTAssertTrue(rig.engine.isMenuOpen, "B+← must open the menu. Log: \(rig.log())")
    }

    // MARK: - Assertion helpers

    /// Nothing reached the app since `baseline`, and the recognizer is not holding anything either.
    private func assertQuiet(
        _ rig: EngineRig,
        since baseline: Int,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let added = Array(rig.emitter.emissions.dropFirst(baseline))
        XCTAssertEqual(
            added, [],
            "\(message). Leaked: \(added). Log: \(rig.log())",
            file: file, line: line
        )
        XCTAssertTrue(
            rig.engine.recognizer.hasNothingInFlight,
            "\(message): the recognizer still believes a button is down. Log: \(rig.log())",
            file: file, line: line
        )
    }

    /// Exactly one key went down and came back up, with the same stroke — a paired navigation press.
    private func assertPairedKey(
        _ rig: EngineRig,
        since baseline: Int,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let added = Array(rig.emitter.emissions.dropFirst(baseline))
        guard added.count == 2 else {
            XCTFail(
                "\(message): expected one down/up pair, got \(added). Log: \(rig.log())",
                file: file, line: line
            )
            return
        }
        XCTAssertEqual(added[0].phase, .down, message, file: file, line: line)
        XCTAssertEqual(added[1].phase, .up, message, file: file, line: line)
        XCTAssertEqual(
            added[0].stroke, added[1].stroke,
            "\(message): the release must use the stroke that went down",
            file: file, line: line
        )
    }

    /// Ordinary navigation still reaches the app: a plain ↓ is a paired key again.
    private func assertNavigationRecovered(_ rig: EngineRig, at t: TimeInterval) {
        let baseline = rig.emitter.emissions.count
        rig.press(.down, at: t)
        rig.release(.down, at: t + 0.1)
        assertPairedKey(rig, since: baseline, "after the menu is gone, ↓ must be ordinary navigation")
    }

    // MARK: - ② The release order of the opening chord

    /// B comes up first, then the direction. Neither release is input any more: the chord's press
    /// was consumed by opening the menu, and the reset at open already ended it.
    func testReleasingBBeforeTheDirectionEmitsNothing() {
        let rig = makeRig()
        defer { rig.engine.stop() }

        openWithBLeft(rig)
        assertQuiet(rig, since: 0, "opening the menu must type nothing")

        rig.release(.b, at: 0.10)
        rig.release(.left, at: 0.15)

        assertQuiet(rig, since: 0, "the opening chord's releases must not reach the app")
        XCTAssertTrue(rig.engine.isMenuOpen, "letting go of B leaves the menu up")
    }

    /// The direction comes up first, then B — the other order, same promise.
    func testReleasingTheDirectionBeforeBEmitsNothing() {
        let rig = makeRig()
        defer { rig.engine.stop() }

        openWithBLeft(rig)
        rig.release(.left, at: 0.10)
        rig.release(.b, at: 0.15)

        assertQuiet(rig, since: 0, "the opening chord's releases must not reach the app")
        XCTAssertTrue(rig.engine.isMenuOpen)
    }

    // MARK: - ②④ Working the menu with B still held

    /// Directions pressed while B is *still down* drive the list and nothing else — and the reset
    /// that every selection change triggers (`onMenuChanged` → `resetAndEmit`) must not turn into
    /// an action of its own.
    func testNavigatingWhileBIsHeldEmitsNothingAndEachSelectionResetIsSilent() {
        let rig = makeRig()
        defer { rig.engine.stop() }

        openWithBLeft(rig)
        let start = rig.dispatcher.openMenu?.selection

        var t = 0.20
        for step in 1...3 {
            rig.press(.down, at: t)
            assertQuiet(rig, since: 0, "↓ #\(step) in the menu must not reach the app")
            rig.release(.down, at: t + 0.05)
            assertQuiet(rig, since: 0, "the release of ↓ #\(step) must not reach the app")
            t += 0.15
        }

        XCTAssertNotEqual(rig.dispatcher.openMenu?.selection, start, "↓ must have moved the selection")
        XCTAssertTrue(rig.engine.isMenuOpen, "navigating must not close or reopen the menu")

        rig.release(.b, at: t)
        assertQuiet(rig, since: 0, "B's own release must not reach the app either")
    }

    /// A is pressed with B still held: the row runs once, and the two releases that follow are
    /// silent — no Enter from A, no Escape or app switch from B.
    func testRunningARowWithBHeldEmitsOnlyThatRecipeAndTheLateReleasesAreSilent() {
        let rig = makeRig()
        defer { rig.engine.stop() }

        openWithBLeft(rig)
        guard let action = rig.dispatcher.openMenu?.selectedItem?.action,
              let stroke = rig.stroke(for: action) else {
            return XCTFail("the first row must be a runnable command. Log: \(rig.log())")
        }

        rig.press(.a, at: 0.20)

        XCTAssertFalse(rig.engine.isMenuOpen, "running a row closes the menu")
        XCTAssertEqual(
            rig.emitter.emissions, [.init(phase: .press, stroke: stroke)],
            "exactly the chosen row's recipe, exactly once. Log: \(rig.log())"
        )

        let afterRun = rig.emitter.emissions.count
        rig.release(.a, at: 0.30)
        assertQuiet(rig, since: afterRun, "A's release ran the row already; it must not also submit")
        rig.release(.b, at: 0.40)
        assertQuiet(rig, since: afterRun, "B's release must not become Escape or an app switch")

        assertNavigationRecovered(rig, at: 0.60)
    }

    // MARK: - ③ Closing, then the stale tail, then a new operation

    /// B closes the menu. Its own release arrives with the menu already gone and must stay silent —
    /// this is the press that would otherwise reach the app as `cancelOrInterrupt`.
    func testBClosesTheMenuAndItsOwnReleaseIsSilent() {
        let rig = makeRig()
        defer { rig.engine.stop() }

        openWithBLeft(rig)
        rig.release(.left, at: 0.10)
        rig.release(.b, at: 0.15)

        rig.press(.b, at: 0.30)
        XCTAssertFalse(rig.engine.isMenuOpen, "B must close the menu")
        assertQuiet(rig, since: 0, "the B that closed the menu must not reach the app")

        rig.release(.b, at: 0.40)
        assertQuiet(rig, since: 0, "the release of the closing B must not become Escape")

        assertNavigationRecovered(rig, at: 0.60)
    }

    /// The app takes the menu down for its own reasons (focus moved off the agent) while both
    /// buttons are still physically down. The two releases that follow belong to a session that no
    /// longer exists.
    func testExternalCloseLeavesTheStaleReleasesWithNoOwnerAndTheyEmitNothing() {
        let rig = makeRig()
        defer { rig.engine.stop() }

        openWithBLeft(rig)
        rig.engine.closeMenu()
        XCTAssertFalse(rig.engine.isMenuOpen)
        assertQuiet(rig, since: 0, "closing the menu from the app side must type nothing")

        rig.release(.left, at: 0.20)
        rig.release(.b, at: 0.30)
        assertQuiet(rig, since: 0, "releases left over from the closed menu must not reach the app")

        assertNavigationRecovered(rig, at: 0.50)
    }

    /// Focus moved while the menu was up: choosing a row is refused, nothing is injected into the
    /// app that is in front *now*, and A's release is still silent.
    func testFocusMovingAwayRefusesTheRowAndInjectsNothing() {
        let rig = makeRig()
        defer { rig.engine.stop() }

        openWithBLeft(rig)
        rig.frontmost.bundleID = safari

        rig.press(.a, at: 0.20)
        XCTAssertFalse(rig.engine.isMenuOpen, "a refused row still takes the menu down")
        assertQuiet(rig, since: 0, "a row refused for the wrong frontmost app must inject nothing")
        XCTAssertTrue(
            rig.log().contains { $0.contains("menu item refused") },
            "the refusal must be reported. Log: \(rig.log())"
        )

        rig.release(.a, at: 0.30)
        rig.release(.b, at: 0.40)
        assertQuiet(rig, since: 0, "the releases of a refused choice must not reach Safari")

        rig.frontmost.bundleID = codex
        assertNavigationRecovered(rig, at: 0.60)
    }

    /// The controller vanishes with the menu up. The menu goes away, and the releases the device (or
    /// the user, on reconnect) sends afterwards are not a gesture.
    func testDisconnectClosesTheMenuAndTheStaleReleasesEmitNothing() {
        let rig = makeRig()
        defer { rig.engine.stop() }

        openWithBLeft(rig)
        rig.source.onDetach?("Wireless Controller")

        XCTAssertFalse(rig.engine.isMenuOpen, "a detach must take the menu down")
        assertQuiet(rig, since: 0, "the detach itself must type nothing")

        rig.release(.left, at: 0.20)
        rig.release(.b, at: 0.30)
        assertQuiet(rig, since: 0, "releases arriving after the detach must not reach the app")

        assertNavigationRecovered(rig, at: 0.50)
    }

    // MARK: - ③ Cleanup releases: allowed, but exactly once and paired

    /// A direction that was already held when the menu opened is the one thing the reset *must*
    /// emit: its key-down went to the app, so its key-up has to as well. Exactly once — the
    /// physical release afterwards is swallowed by the menu.
    func testHeldDirectionIsReleasedExactlyOnceWhenTheChordOpensTheMenu() {
        let rig = makeRig()
        defer { rig.engine.stop() }

        rig.press(.down, at: 0)
        XCTAssertEqual(rig.emitter.emissions.count, 1, "a held ↓ goes down in the app. Log: \(rig.log())")

        rig.press(.b, at: 0.10)
        rig.press(.left, at: 0.15)
        XCTAssertTrue(rig.engine.isMenuOpen)

        assertPairedKey(rig, since: 0, "opening the menu must release the held ↓ exactly once")

        let afterCleanup = rig.emitter.emissions.count
        rig.release(.down, at: 0.30)
        rig.release(.left, at: 0.35)
        rig.release(.b, at: 0.40)
        assertQuiet(rig, since: afterCleanup, "the real ↓ release must not key-up a second time")
    }

    /// Same promise through the menu-bar entry point, which resets the recognizer before the
    /// dispatcher is ever asked to open anything.
    func testHeldDirectionIsReleasedExactlyOnceWhenTheMenuBarOpensTheMenu() {
        let rig = makeRig()
        defer { rig.engine.stop() }

        rig.press(.down, at: 0)
        rig.engine.openMenu()
        XCTAssertTrue(rig.engine.isMenuOpen, "the menu-bar entry point must open the menu")

        assertPairedKey(rig, since: 0, "opening the menu must release the held ↓ exactly once")

        let afterCleanup = rig.emitter.emissions.count
        rig.release(.down, at: 0.30)
        assertQuiet(rig, since: afterCleanup, "the real ↓ release must not key-up a second time")
    }

    /// Push-to-talk on one button: the voice modifier is down when the menu opens, so the reset has
    /// to release it — once, paired, and without ever sending Enter.
    func testHeldVoiceModifierIsReleasedExactlyOnceWhenTheMenuOpens() {
        let rig = makeRig()
        defer { rig.engine.stop() }

        rig.press(.a, at: 0)
        rig.scheduler.advance(to: 1.0)          // cross aHoldMs: the voice key goes down
        let option = KeyStroke(modifiers: [.rightOption])
        XCTAssertEqual(
            rig.emitter.emissions, [.init(phase: .down, stroke: option)],
            "holding A must hold the voice key. Log: \(rig.log())"
        )

        rig.engine.openMenu()
        XCTAssertTrue(rig.engine.isMenuOpen)
        XCTAssertEqual(
            rig.emitter.emissions,
            [.init(phase: .down, stroke: option), .init(phase: .up, stroke: option)],
            "opening the menu must release the voice key exactly once. Log: \(rig.log())"
        )

        let afterCleanup = rig.emitter.emissions.count
        rig.release(.a, at: 2.0)
        assertQuiet(rig, since: afterCleanup, "A's real release must not release the key twice")
        XCTAssertFalse(
            rig.emitter.strokes.contains(KeyStroke(.enter)),
            "a held A must never submit, menu or not. Log: \(rig.log())"
        )
    }

    /// ④ The reentrant case with a *held chord* override: `b.a` is push-to-talk, so the modifier is
    /// down when the menu opens. The reset runs while the chord is still in flight and must resolve
    /// its release against the table the chord started with — one paired key-up, no new action.
    func testHeldChordOverrideIsReleasedExactlyOnceWhenTheMenuOpens() {
        let rig = makeRig { config in
            config.gestureKeyOverrides["b.a"] = AppConfig.KeyBinding(modifiers: [.rightOption], hold: true)
        }
        defer { rig.engine.stop() }
        let option = KeyStroke(modifiers: [.rightOption])

        rig.press(.b, at: 0)
        rig.press(.a, at: 0.05)
        XCTAssertEqual(
            rig.emitter.emissions, [.init(phase: .down, stroke: option)],
            "B+A must hold the voice key. Log: \(rig.log())"
        )

        rig.engine.openMenu()
        XCTAssertTrue(rig.engine.isMenuOpen)
        XCTAssertEqual(
            rig.emitter.emissions,
            [.init(phase: .down, stroke: option), .init(phase: .up, stroke: option)],
            "the reset at open must end the chord it found, and add nothing. Log: \(rig.log())"
        )

        let afterCleanup = rig.emitter.emissions.count
        rig.release(.a, at: 0.30)
        rig.release(.b, at: 0.40)
        assertQuiet(rig, since: afterCleanup, "the chord's real releases must not emit again")
    }
}

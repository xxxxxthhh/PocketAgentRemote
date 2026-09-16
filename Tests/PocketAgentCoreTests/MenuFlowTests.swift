import XCTest
@testable import PocketAgentCore

/// End-to-end through the real recognizer *and* the real dispatcher, because that is where the
/// menu's two halves meet. An earlier round of bugs lived exactly here: the recognizer's view of
/// which buttons are down and the dispatcher's view of whether a menu is open.
final class MenuFlowTests: XCTestCase {
    /// Records what was emitted **and on which method**.
    ///
    /// A held binding and a one-shot press produce the same kind of event through different calls
    /// (`keyDown`/`keyUp` versus `press`), and several of the bugs found here lived exactly in that
    /// distinction — so the phase is part of the record rather than being flattened away.
    private final class SpyEmitter: InputEmitting {
        enum Phase: Equatable { case press, down, up }
        struct Emission: Equatable {
            let phase: Phase
            let stroke: KeyStroke
        }

        private(set) var emissions: [Emission] = []

        var strokes: [KeyStroke] { emissions.map(\.stroke) }

        func reset() { emissions.removeAll() }

        func press(_ stroke: KeyStroke) { emissions.append(Emission(phase: .press, stroke: stroke)) }
        func keyDown(_ stroke: KeyStroke) { emissions.append(Emission(phase: .down, stroke: stroke)) }
        func keyUp(_ stroke: KeyStroke) { emissions.append(Emission(phase: .up, stroke: stroke)) }
        func releaseAll() {}
    }

    private final class FixedFrontmost: FrontmostAppProviding {
        var bundleID: String? = "com.openai.codex"
        func frontmostBundleID() -> String? { bundleID }
    }

    private final class FakeSource: ControllerInputSource {
        let transport: ControllerTransport = .rawHID
        var onEvent: ((InputEvent) -> Void)?
        var onAttach: ((String) -> Void)?
        var onDetach: ((String) -> Void)?
        var onWillDetach: (() -> Void)?
        func start() {}
        func stop() {}
    }

    private struct Rig {
        let engine: ControllerEngine
        let dispatcher: ActionDispatcher
        let source: FakeSource
        let emitter: SpyEmitter
        /// The injected clock, so a test can cross a hold threshold deterministically.
        let scheduler: ManualScheduler
        let log: () -> [String]
    }

    private func makeRig(configure: (inout AppConfig) -> Void = { _ in }) -> Rig {
        var config = AppConfig()
        config.profileMode = .auto
        configure(&config)
        let emitter = SpyEmitter()
        let frontmost = FixedFrontmost()
        let dispatcher = ActionDispatcher(
            configProvider: { config },
            frontmost: frontmost,
            emitter: emitter
        )
        dispatcher.menuBuilder = { bundleID in
            AgentMenuBuilder.menu(for: config, frontmostBundleID: bundleID, frontmostName: "Codex")
        }
        let source = FakeSource()
        let scheduler = ManualScheduler()
        let engine = ControllerEngine(
            dispatcher: dispatcher,
            // The real resolved table, so the `a.hold` push-to-talk default is in play here too.
            gestureOverrides: config.gestureOverrides(for: config.activeProfile),
            scheduler: scheduler,
            coordinator: ControllerInputCoordinator(gameController: FakeSource(), hid: source)
        )
        var diagnostics: [String] = []
        dispatcher.onDiagnostic = { diagnostics.append("DISP \($0)") }
        engine.onDiagnostic = { diagnostics.append("ENG  \($0)") }
        engine.onGesture = { events in
            diagnostics.append("GESTURE \(events)")
        }
        engine.frontmost = frontmost
        engine.start()
        return Rig(
            engine: engine,
            dispatcher: dispatcher,
            source: source,
            emitter: emitter,
            scheduler: scheduler,
            log: { diagnostics }
        )
    }

    private func press(_ rig: Rig, _ button: PhysicalButton, at t: TimeInterval) {
        rig.source.onEvent?(.pressed(button, timestamp: t))
    }
    private func release(_ rig: Rig, _ button: PhysicalButton, at t: TimeInterval) {
        rig.source.onEvent?(.released(button, timestamp: t))
    }

    private func state(_ rig: Rig) -> String {
        "menu=\(rig.engine.isMenuOpen) idle=\(rig.engine.recognizer.hasNothingInFlight)"
    }

    /// The reported flow: open with B+←, navigate with ↑↓ after letting go of B, run a row, then
    /// navigate again.
    func testNavigationWorksAfterRunningARow() {
        let rig = makeRig()
        defer { rig.engine.stop() }

        // B+← opens it.
        press(rig, .b, at: 0)
        press(rig, .left, at: 0.05)
        release(rig, .left, at: 0.10)
        release(rig, .b, at: 0.15)
        XCTAssertTrue(rig.engine.isMenuOpen, "B+← must open the menu")

        // Let go of B and navigate — this is the reported usage.
        press(rig, .down, at: 0.30)
        release(rig, .down, at: 0.40)
        XCTAssertEqual(rig.dispatcher.openMenu?.selection, 1, "↓ must move the selection")

        press(rig, .down, at: 0.50)
        release(rig, .down, at: 0.60)
        XCTAssertEqual(rig.dispatcher.openMenu?.selection, 2)

        // Run the highlighted row.
        press(rig, .a, at: 0.70)
        release(rig, .a, at: 0.80)
        XCTAssertFalse(rig.engine.isMenuOpen, "running a row closes the menu")

        // And now a plain ↓ must go back to being ordinary navigation, not a menu reopen.
        let before = rig.emitter.strokes.count
        press(rig, .down, at: 1.00)
        release(rig, .down, at: 1.10)
        XCTAssertEqual(
            rig.emitter.strokes.count, before + 2,
            "after the menu closes, ↓ must be an ordinary keyDown/keyUp again. Log: \(rig.log())"
        )
    }

    /// The same flow, but navigating while B is *still held*. Worth pinning: it is what the log
    /// showed, and it must not reopen the menu either.
    func testNavigationWhileBIsStillHeldDoesNotReopenTheMenu() {
        let rig = makeRig()
        defer { rig.engine.stop() }

        press(rig, .b, at: 0)
        press(rig, .left, at: 0.05)
        release(rig, .left, at: 0.10)
        XCTAssertTrue(rig.engine.isMenuOpen)

        // B still down: another ← must not "open" the menu a second time, and ↑/↓ must navigate.
        press(rig, .up, at: 0.20)
        release(rig, .up, at: 0.30)
        XCTAssertEqual(rig.dispatcher.openMenu?.selection, 4, "↑ wraps to the last row while B is held")

        release(rig, .b, at: 0.40)
        XCTAssertTrue(rig.engine.isMenuOpen, "letting go of B leaves the menu up")
    }

    /// The exact shape from the user's session: open with B+← and **keep B held** while working the
    /// menu, run a row, then press a direction with B released.
    ///
    /// This is the flow that broke: the recognizer was left believing a button was still down (it
    /// received nothing while the menu was up, so B's release never reached it), and the next ↓ was
    /// then swallowed — which felt like "I have to press B once to unlock the arrows".
    func testDirectionsWorkAfterRunningARowWhenBWasHeldThroughout() {
        let rig = makeRig()
        defer { rig.engine.stop() }

        press(rig, .b, at: 0)
        press(rig, .left, at: 0.05)          // opens the menu; B stays down
        XCTAssertTrue(rig.engine.isMenuOpen)

        // Work the list while still holding B — this is what the log showed happening.
        press(rig, .down, at: 0.20)
        release(rig, .down, at: 0.30)
        press(rig, .up, at: 0.40)
        release(rig, .up, at: 0.50)
        XCTAssertNotNil(rig.dispatcher.openMenu)

        // Run the highlighted row.
        press(rig, .a, at: 0.60)
        release(rig, .a, at: 0.70)
        XCTAssertFalse(rig.engine.isMenuOpen, "running a row closes the menu")
        release(rig, .b, at: 0.80)           // B finally comes up, after the menu is gone

        let before = rig.emitter.strokes.count
        press(rig, .down, at: 0.95)
        release(rig, .down, at: 1.05)
        XCTAssertEqual(
            rig.emitter.strokes.count, before + 2,
            "↓ must be an ordinary keyDown/keyUp again — no 'press B to unlock'."
        )
    }

    /// The failure the log showed after the menu had been used once: every later `B+A` produced a
    /// bare `Enter` instead of voice input, because B was being ignored.
    ///
    /// Chain of blame: releasing A while the recognizer had *nothing in flight* (exactly what the
    /// menu leaves behind — it opens by resetting the recognizer's view of what is down) was dropped
    /// by an over-broad "cleanup, not input" guard. `aIsDown` then stayed true for good, and the
    /// "ignore B while A is held" rule refused every subsequent B press.
    ///
    /// The menu is simulated by an explicit detach-free reset, which is the state the real menu
    /// leaves: nothing in flight.
    func testVoiceStillWorksAfterTheMenuHasBeenUsed() {
        let rig = makeRig()
        defer { rig.engine.stop() }

        // Reproduce the state the menu leaves behind, then let A go.
        rig.engine.closeMenu()               // also how an externally closed menu ends up
        rig.source.onEvent?(.pressed(.a, timestamp: 0))
        requireChordAfterAReset(rig)
    }

    private func requireChordAfterAReset(_ rig: Rig) {
        // The recognizer is empty here, as it is right after the menu opens/closes.
        rig.source.onEvent?(.released(.a, timestamp: 0.1))

        rig.emitter.reset()
        rig.source.onEvent?(.pressed(.b, timestamp: 1.0))
        rig.source.onEvent?(.pressed(.a, timestamp: 1.2))
        rig.source.onEvent?(.released(.a, timestamp: 1.6))
        rig.source.onEvent?(.released(.b, timestamp: 1.8))

        XCTAssertFalse(
            rig.emitter.strokes.contains(KeyStroke(.enter)),
            "B must not be ignored: a bare Enter here is what killed voice input. Log: \(rig.log())"
        )
    }

    /// A held A is push-to-talk on one button: the voice key goes down when the threshold is crossed
    /// and comes back up on release. No Enter is ever sent for that press.
    ///
    /// The case is driven end to end through the real recognizer and dispatcher; the hold timer is
    /// the injected `ManualScheduler`, and any later event advances it past the threshold.
    func testHoldingADrivesTheVoiceBindingAndNeverSubmits() {
        let rig = makeRig()
        defer { rig.engine.stop() }

        press(rig, .a, at: 0)
        XCTAssertTrue(rig.emitter.strokes.isEmpty, "the press alone must not submit")

        // Crossing the threshold: the recognizer's hold timer fires and the binding goes down.
        rig.scheduler.advance(to: 1.0)

        let option = KeyStroke(modifiers: [.rightOption])
        XCTAssertEqual(
            rig.emitter.emissions,
            [.init(phase: .down, stroke: option)],
            "holding A must hold the voice key. Log: \(rig.log())"
        )

        release(rig, .a, at: 2.0)

        XCTAssertEqual(
            rig.emitter.emissions.last,
            .init(phase: .up, stroke: option),
            "releasing A must release the voice key"
        )
        XCTAssertFalse(
            rig.emitter.emissions.contains { $0.stroke == KeyStroke(.enter) },
            "holding A must never submit. Log: \(rig.log())"
        )
    }

    /// And a quick tap is still an approval, sent immediately.
    func testTappingAStillSubmitsImmediately() {
        let rig = makeRig()
        defer { rig.engine.stop() }

        press(rig, .a, at: 0)
        release(rig, .a, at: 0.08)

        // `submit` is a *held* action (down/up), which is what makes it repeat-free and lets the
        // release be recorded and honoured even if the frontmost app changes mid-press.
        XCTAssertEqual(
            rig.emitter.emissions,
            [.init(phase: .down, stroke: .key(.enter)), .init(phase: .up, stroke: .key(.enter))]
        )
    }

    /// The old two-button grip keeps working: `a.hold` is a *default*, so a config that still binds
    /// `b.a` keeps that binding too — adding the one-button trigger removes nothing.
    func testTheOldTwoButtonVoiceGripStillWorks() {
        let rig = makeRig { config in
            config.gestureKeyOverrides["b.a"] = AppConfig.KeyBinding(modifiers: [.rightOption], hold: true)
        }
        defer { rig.engine.stop() }
        let option = KeyStroke(modifiers: [.rightOption])

        press(rig, .b, at: 0)
        press(rig, .a, at: 0.05)
        release(rig, .b, at: 0.10)
        release(rig, .a, at: 1.50)

        XCTAssertEqual(
            rig.emitter.emissions,
            [.init(phase: .down, stroke: option), .init(phase: .up, stroke: option)],
            "B+A must still be push-to-talk. Log: \(rig.log())"
        )
    }

    /// Running the row that the log showed (`切换模型`), then navigating.
    func testRunningModelPickerThenNavigating() {
        let rig = makeRig()
        defer { rig.engine.stop() }

        press(rig, .b, at: 0)
        press(rig, .left, at: 0.05)
        release(rig, .left, at: 0.10)
        release(rig, .b, at: 0.15)

        // Selection starts at 新建会话; move to 切换模型 (index 3).
        for step in 0..<3 {
            press(rig, .down, at: 0.20 + Double(step) * 0.1)
            release(rig, .down, at: 0.25 + Double(step) * 0.1)
        }
        XCTAssertEqual(rig.dispatcher.openMenu?.selectedItem?.action, .openModelPicker)

        press(rig, .a, at: 0.60)
        release(rig, .a, at: 0.70)
        // ⌃⇧M is what Codex binds the model picker to.
        XCTAssertTrue(rig.emitter.strokes.contains(KeyStroke(.m, modifiers: [.control, .shift])))

        let before = rig.emitter.strokes.count
        press(rig, .down, at: 0.90)
        release(rig, .down, at: 1.00)
        XCTAssertEqual(rig.emitter.strokes.count, before + 2, "↓ must be an ordinary keyDown/keyUp again")
    }
}

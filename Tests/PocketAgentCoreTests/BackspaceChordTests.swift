import XCTest
@testable import PocketAgentCore

/// `B+A` is backspace, held for the life of the chord and auto-repeated while held.
///
/// Voice input puts the transcript straight into the composer; this is the one way to fix a
/// misheard word without reaching for the keyboard. The whole thing runs through the real engine,
/// recognizer and dispatcher: the release-without-a-down and the down-without-a-release are wiring
/// bugs between those three, not bugs inside any of them.
final class BackspaceChordTests: XCTestCase {
    private let backspace = KeyStroke.key(.delete)
    private func down(_ s: KeyStroke) -> RecordingEmitter.Emission { .init(phase: .down, stroke: s) }
    private func up(_ s: KeyStroke) -> RecordingEmitter.Emission { .init(phase: .up, stroke: s) }

    // MARK: - Chord shape

    func testBPlusASendsBackspaceDownAndReleasingASendsTheUp() {
        let rig = makeEngineRig()
        defer { rig.engine.stop() }

        rig.press(.b, at: 0)
        rig.press(.a, at: 0.05)
        XCTAssertEqual(rig.emitter.emissions, [down(backspace)], "the chord itself is the key-down. Log: \(rig.log())")

        rig.release(.a, at: 0.10)
        XCTAssertEqual(rig.emitter.emissions, [down(backspace), up(backspace)])

        rig.release(.b, at: 0.15)
        XCTAssertEqual(rig.emitter.emissions.count, 2, "B was consumed by the chord: no Escape on its release")
    }

    func testReleasingBFirstKeepsBackspaceHeldUntilAComesUp() {
        let rig = makeEngineRig()
        defer { rig.engine.stop() }

        rig.press(.b, at: 0)
        rig.press(.a, at: 0.05)
        rig.release(.b, at: 0.10)
        XCTAssertEqual(rig.emitter.emissions, [down(backspace)], "same lifetime rule as push-to-talk had on this chord")

        rig.release(.a, at: 0.20)
        XCTAssertEqual(rig.emitter.emissions, [down(backspace), up(backspace)])
    }

    func testItWorksInABrowserBecauseBackspaceIsAnEditingKey() {
        let rig = makeEngineRig(frontmostBundleID: "com.apple.Safari")
        defer { rig.engine.stop() }

        rig.press(.b, at: 0)
        rig.press(.a, at: 0.05)
        rig.release(.a, at: 0.10)

        XCTAssertEqual(rig.emitter.emissions, [down(backspace), up(backspace)])
        XCTAssertFalse(rig.log().contains { $0.hasPrefix("DENY") }, "Log: \(rig.log())")
    }

    func testAOnItsOwnIsStillSubmit() {
        let rig = makeEngineRig()
        defer { rig.engine.stop() }

        rig.press(.a, at: 0)
        rig.release(.a, at: 0.05)
        // `submit` is a held down/up pair (so it can never repeat), decided on release.
        XCTAssertEqual(rig.emitter.emissions, [down(.key(.enter)), up(.key(.enter))])
        rig.scheduler.advance(to: 5)
        XCTAssertEqual(rig.emitter.emissions.count, 2, "Enter never auto-repeats")
    }

    // MARK: - Auto-repeat

    func testHoldingRepeatsAfterTheDelayAtTheInterval() {
        let rig = makeEngineRig()
        defer { rig.engine.stop() }

        rig.press(.b, at: 0)
        rig.press(.a, at: 0.05)   // the clock is still at 0: timestamps do not advance it

        rig.scheduler.advance(to: ActionDispatcher.repeatDelay - 0.001)
        XCTAssertEqual(rig.emitter.emissions, [down(backspace)], "nothing before the delay")

        rig.scheduler.advance(to: ActionDispatcher.repeatDelay)
        XCTAssertEqual(rig.emitter.emissions, [down(backspace), down(backspace)], "first repeat at the delay")

        rig.scheduler.advance(to: ActionDispatcher.repeatDelay + ActionDispatcher.repeatInterval)
        XCTAssertEqual(rig.emitter.emissions.count, 3, "then one per interval")

        rig.release(.a, at: 0.5)
        XCTAssertEqual(rig.emitter.emissions.last, up(backspace))
        let countAtRelease = rig.emitter.emissions.count

        rig.scheduler.advance(to: 5)
        XCTAssertEqual(rig.emitter.emissions.count, countAtRelease, "release stops the repeat for good")
    }

    func testDirectionsRepeatTheSameWay() {
        let rig = makeEngineRig()
        defer { rig.engine.stop() }
        let left = KeyStroke.key(.leftArrow)

        rig.press(.left, at: 0)
        // Stepped, not jumped: each tick schedules the next relative to the clock it fired on.
        rig.scheduler.advance(to: ActionDispatcher.repeatDelay)
        rig.scheduler.advance(to: ActionDispatcher.repeatDelay + ActionDispatcher.repeatInterval)
        XCTAssertEqual(rig.emitter.emissions, [down(left), down(left), down(left)])

        rig.release(.left, at: 0.6)
        XCTAssertEqual(rig.emitter.emissions.last, up(left))
        rig.scheduler.advance(to: 5)
        XCTAssertEqual(rig.emitter.emissions.count, 4)
    }

    func testATapNeverRepeats() {
        let rig = makeEngineRig()
        defer { rig.engine.stop() }

        rig.press(.b, at: 0)
        rig.press(.up, at: 0.05)   // ⌥⌘1: a one-shot jump
        rig.scheduler.advance(to: 5)
        XCTAssertEqual(rig.emitter.emissions.count, 1, "a one-shot chord is sent once however long it is held")
    }

    func testRepeatStopsWhenTheFrontmostAppChangesButTheReleaseStillLands() {
        let rig = makeEngineRig()
        defer { rig.engine.stop() }

        rig.press(.b, at: 0)
        rig.press(.a, at: 0.05)
        rig.scheduler.advance(to: ActionDispatcher.repeatDelay)
        XCTAssertEqual(rig.emitter.emissions.count, 2)

        rig.frontmost.bundleID = "com.apple.Safari"
        rig.scheduler.advance(to: 5)
        XCTAssertEqual(rig.emitter.emissions.count, 2, "no more repeats into the app that came next")

        rig.release(.a, at: 6)
        XCTAssertEqual(rig.emitter.emissions.last, up(backspace), "the key that went down still comes up")
    }

    func testDisconnectStopsTheRepeatAndReleasesTheKeyOnce() {
        let rig = makeEngineRig()
        defer { rig.engine.stop() }

        rig.press(.b, at: 0)
        rig.press(.a, at: 0.05)
        rig.scheduler.advance(to: ActionDispatcher.repeatDelay)
        XCTAssertEqual(rig.emitter.emissions.count, 2)

        rig.source.onDetach?("Xbox Wireless Controller")
        let ups = rig.emitter.emissions.filter { $0.phase == .up }
        XCTAssertEqual(ups, [up(backspace)], "exactly one key-up on disconnect. Log: \(rig.log())")

        rig.scheduler.advance(to: 5)
        XCTAssertEqual(rig.emitter.emissions.filter { $0.phase == .down }.count, 2, "no repeats after the controller is gone")
    }

    // MARK: - Config

    func testBackspaceHasAConfigName() throws {
        let data = Data(#"{"key": "backspace"}"#.utf8)
        let binding = try JSONDecoder().decode(AppConfig.KeyBinding.self, from: data)
        XCTAssertEqual(binding.key, .delete)
        XCTAssertEqual(Key.delete.keyCode, 51)
        XCTAssertEqual(Key.forwardDelete.keyCode, 117)
    }

    func testTheOldVoiceGrabOnBPlusAIsMigratedAway() {
        var config = AppConfig()
        config.gestureKeyOverrides = [
            "b.a": AppConfig.KeyBinding(modifiers: [.rightOption], hold: true),
            "b.right": AppConfig.KeyBinding(key: .k, modifiers: [.command]),
        ]
        config.profileGestureKeyOverrides = [
            "codex": ["b.a": AppConfig.KeyBinding(modifiers: [.rightOption], hold: true)],
        ]

        XCTAssertTrue(ConfigMigrations.adoptBackspaceChord(&config))
        XCTAssertNil(config.gestureKeyOverrides["b.a"])
        XCTAssertNotNil(config.gestureKeyOverrides["b.right"], "only b.a is touched")
        XCTAssertNil(config.profileGestureKeyOverrides["codex"], "an emptied profile entry is dropped")
        XCTAssertFalse(ConfigMigrations.adoptBackspaceChord(&config), "idempotent")

        // And the chord now resolves to backspace, not to the override.
        XCTAssertNil(config.gestureOverrides(for: .codex)["b.a"])
    }

    func testATapStyleOverrideOnBPlusAOwnsTheReleaseToo() {
        // Resolver level: an override on the chord means the semantic backspace underneath must not
        // key-up on release — the override was sent in full on the press.
        let resolver = EventResolver(gestureOverrides: [
            "b.a": GestureOverride(stroke: KeyStroke(.delete, modifiers: [.option])),
        ])
        XCTAssertEqual(
            resolver.releaseTriggers(for: .gesture(.chordReleased(modifier: .b, key: .a))), [])

        // Engine level, in Codex: exactly one press, nothing on release, nothing on repeat.
        let rig = makeEngineRig { config in
            config.gestureKeyOverrides = ["b.a": AppConfig.KeyBinding(key: .delete, modifiers: [.option])]
        }
        defer { rig.engine.stop() }
        rig.press(.b, at: 0)
        rig.press(.a, at: 0.05)
        rig.scheduler.advance(to: 5)
        rig.release(.a, at: 5.1)
        rig.release(.b, at: 5.2)
        XCTAssertEqual(rig.emitter.emissions, [.init(phase: .press, stroke: KeyStroke(.delete, modifiers: [.option]))],
                       "Log: \(rig.log())")
    }

    func testADeliberateBPlusAOverrideIsLeftAlone() {
        var config = AppConfig()
        config.gestureKeyOverrides = [
            "b.a": AppConfig.KeyBinding(key: .delete, modifiers: [.option]),   // delete a word instead
        ]
        XCTAssertFalse(ConfigMigrations.adoptBackspaceChord(&config))
        XCTAssertNotNil(config.gestureKeyOverrides["b.a"])
    }
}

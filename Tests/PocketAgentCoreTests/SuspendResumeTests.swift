import XCTest
@testable import PocketAgentCore

/// F10: what the engine does around a sleep.
///
/// The failure this pins down is invisible until the lid opens again: a direction that was down when
/// the machine slept stays down in the target application for the whole sleep, the armed B hold timer
/// fires on the far side of it (and holding B now *switches applications*), and the releases the
/// controller sends on its way out would be read as the user finishing a gesture they never started.
///
/// So `suspend()` runs exactly the teardown a detach runs, and everything the controller says between
/// that and `resume()` is dropped — which is what makes the first press after the wake an ordinary
/// first press.
final class SuspendResumeTests: XCTestCase {
    private let codex = "com.openai.codex"
    private let claude = "com.anthropic.claudefordesktop"
    private let safari = "com.apple.Safari"

    private var apps: [RunningApp] {
        [RunningApp(bundleID: codex, name: "Codex"),
         RunningApp(bundleID: claude, name: "Claude"),
         RunningApp(bundleID: safari, name: "Safari")]
    }

    private final class SpyActivator: AppActivating {
        func activate(bundleID: String, completion: @escaping (AppActivationOutcome) -> Void) {
            completion(AppActivationOutcome(
                succeeded: true, bundleID: bundleID, method: .appleScript, elapsedMs: 5,
                attempts: [AppActivationAttempt(method: .appleScript, succeeded: true, elapsedMs: 5)]))
        }
    }

    /// Everything the recognizer emitted, chained onto whatever the rig already records.
    private final class GestureSpy {
        private(set) var events: [ResolvedEvent] = []

        init(_ rig: EngineRig) {
            let existing = rig.engine.onGesture
            rig.engine.onGesture = { [self] batch in
                existing?(batch)
                events.append(contentsOf: batch)
            }
        }

        var gestures: [ControllerGesture] {
            events.compactMap { if case .gesture(let gesture) = $0 { return gesture } else { return nil } }
        }
    }

    private func down(_ stroke: KeyStroke) -> RecordingEmitter.Emission {
        RecordingEmitter.Emission(phase: .down, stroke: stroke)
    }
    private func up(_ stroke: KeyStroke) -> RecordingEmitter.Emission {
        RecordingEmitter.Emission(phase: .up, stroke: stroke)
    }

    // MARK: - Teardown on the way in

    func testSuspendReleasesAHeldDirectionExactlyOnce() {
        let rig = makeEngineRig()
        defer { rig.engine.stop() }
        let arrow = rig.stroke(for: .navigateUp)!

        rig.press(.up, at: 0)
        XCTAssertEqual(rig.emitter.emissions, [down(arrow)], "the direction is held down in the target app")

        rig.engine.suspend()
        XCTAssertEqual(rig.emitter.emissions, [down(arrow), up(arrow)],
                       "the lid closing must release it, once")

        // The auto-repeat timer went with it. Without that, the ticks queued before the sleep land
        // on the far side of it and type into whatever is in front then.
        rig.scheduler.advance(to: 600)
        XCTAssertEqual(rig.emitter.emissions, [down(arrow), up(arrow)],
                       "no repeat tick may survive the sleep")
    }

    func testSuspendClosesAnOpenMenu() {
        let rig = makeEngineRig()
        defer { rig.engine.stop() }

        rig.press(.b, at: 0)
        rig.press(.left, at: 0.05)
        XCTAssertTrue(rig.engine.isMenuOpen, "B+← opens the menu")

        rig.engine.suspend()
        XCTAssertFalse(rig.engine.isMenuOpen, "an overlay must not be left on screen across a sleep")
        XCTAssertTrue(rig.emitter.emissions.isEmpty, "and taking it down must not type anything")
    }

    func testTheTeardownProducesNoGestureAndNoAction() {
        let rig = makeEngineRig(switcherApps: apps, activator: SpyActivator())
        defer { rig.engine.stop() }
        let spy = GestureSpy(rig)

        // B is down — the one press that is destructive to guess at: a tap is Escape, a hold opens
        // the app switcher, and the user is merely holding the controller when the lid closes.
        rig.press(.b, at: 0)
        rig.engine.suspend()

        XCTAssertTrue(spy.gestures.isEmpty, "the teardown must not be recognised as a tap or a hold")
        XCTAssertTrue(rig.emitter.emissions.isEmpty, "and it must send nothing")
        XCTAssertFalse(rig.engine.isMenuOpen, "nor open the switcher")

        // The finger comes off B after the machine has gone. Still cleanup, still not input.
        rig.release(.b, at: 0.2)
        XCTAssertTrue(spy.gestures.isEmpty)
        XCTAssertTrue(rig.emitter.emissions.isEmpty)
        XCTAssertFalse(rig.engine.isMenuOpen)
    }

    func testSuspendingTwiceIsIdempotent() {
        let rig = makeEngineRig()
        defer { rig.engine.stop() }
        let arrow = rig.stroke(for: .navigateUp)!

        rig.press(.up, at: 0)
        rig.engine.suspend()
        XCTAssertEqual(rig.emitter.emissions, [down(arrow), up(arrow)])

        rig.engine.suspend()
        XCTAssertEqual(rig.emitter.emissions, [down(arrow), up(arrow)],
                       "a second willSleep must not key-up a key that is already up")
        XCTAssertTrue(rig.engine.isSuspended)

        rig.engine.resume()
        XCTAssertFalse(rig.engine.isSuspended)
        XCTAssertEqual(rig.emitter.emissions, [down(arrow), up(arrow)], "and the wake sends nothing either")
    }

    // MARK: - The B hold timer

    func testHoldingBAcrossASleepCannotOpenTheSwitcher() {
        let rig = makeEngineRig(switcherApps: apps, activator: SpyActivator())
        defer { rig.engine.stop() }

        rig.press(.b, at: 0)
        rig.engine.suspend()
        rig.scheduler.advance(to: 600)        // ten minutes with the lid shut, far past holdMs
        rig.engine.resume()
        rig.release(.b, at: 600)              // the finger that was on B comes off after the wake
        rig.scheduler.advance(to: 601)

        XCTAssertFalse(rig.engine.isMenuOpen, "an armed hold timer must not survive the sleep")
        XCTAssertTrue(rig.emitter.emissions.isEmpty, "and the stray release must not become a B tap")
    }

    /// The control for the test above: the same gesture, no sleep, does open the switcher — so the
    /// assertion there is about the sleep and not about the rig being unable to open one at all.
    func testHoldingBWithNoSleepStillOpensTheSwitcher() {
        let rig = makeEngineRig(switcherApps: apps, activator: SpyActivator())
        defer { rig.engine.stop() }

        rig.press(.b, at: 0)
        rig.scheduler.advance(to: 1.0)
        rig.release(.b, at: 1.0)

        XCTAssertTrue(rig.engine.isMenuOpen)
        XCTAssertEqual(rig.dispatcher.openMenu?.layout, .strip)
    }

    // MARK: - The first press after the wake

    func testTheFirstPressAfterAResumeIsAnOrdinaryPairedPress() {
        let rig = makeEngineRig()
        defer { rig.engine.stop() }
        let arrow = rig.stroke(for: .navigateDown)!

        rig.press(.up, at: 0)
        rig.engine.suspend()
        // The controller keeps talking on the way into the sleep. None of it may stick: the release
        // belongs to a press the teardown already ended, and the press belongs to a machine that is
        // no longer listening.
        rig.release(.up, at: 0.1)
        rig.press(.down, at: 0.2)
        rig.engine.resume()

        let before = rig.emitter.emissions.count
        rig.press(.down, at: 600)
        rig.release(.down, at: 600.1)

        XCTAssertEqual(Array(rig.emitter.emissions.dropFirst(before)), [down(arrow), up(arrow)],
                       "the first press after the wake is a plain keyDown/keyUp pair")
    }

    /// `hasNothingInFlight` does not cover `aIsDown`, and a stuck `aIsDown` makes the recognizer
    /// ignore **every** later B press as "B while A is down" — push-to-talk's own failure mode.
    func testAnAReleasedWhileAsleepDoesNotSwallowTheNextBPress() {
        let rig = makeEngineRig()
        defer { rig.engine.stop() }

        rig.press(.a, at: 0)              // `a.hold` is on by default, so A is still undecided here
        rig.engine.suspend()
        XCTAssertTrue(rig.emitter.emissions.isEmpty, "an undecided A sends nothing on the way out")

        rig.release(.a, at: 0.1)          // dropped: the engine is asleep
        rig.engine.resume()

        rig.press(.b, at: 600)
        rig.release(.b, at: 600.1)
        XCTAssertEqual(rig.emitter.emissions,
                       [RecordingEmitter.Emission(phase: .press, stroke: KeyStroke(.escape))],
                       "a B tap after the wake must still be Escape")
    }
}

import XCTest
@testable import PocketAgentCore

/// Engine-level behaviour that the dispatcher/recognizer tests cannot see on their own: what happens
/// when the *controller* disappears mid-gesture.
///
/// Written after a review pass on 2026-09-16 found that a disconnect was being interpreted as a
/// gesture: the HID path releases everything it believes is held before reporting the detach, and
/// once "hold B" meant "switch applications", losing the controller could switch windows by itself.
final class EngineTests: XCTestCase {
    private final class FakeSource: ControllerInputSource {
        let transport: ControllerTransport = .rawHID
        var onEvent: ((InputEvent) -> Void)?
        var onAttach: ((String) -> Void)?
        var onDetach: ((String) -> Void)?
        var onWillDetach: (() -> Void)?
        func start() {}
        func stop() {}
    }

    /// Records triggers and answers `releaseHeldStrokes`, so the engine's contract is honoured.
    private final class RecordingDispatcher: ActionDispatching {
        private(set) var triggers: [ActionTrigger] = []
        private(set) var releaseHeldCalls = 0

        func dispatch(_ trigger: ActionTrigger) { triggers.append(trigger) }
        func releaseHeldStrokes() { releaseHeldCalls += 1 }
    }

    private func makeEngine() -> (ControllerEngine, RecordingDispatcher, FakeSource) {
        let source = FakeSource()
        let dispatcher = RecordingDispatcher()
        let engine = ControllerEngine(
            dispatcher: dispatcher,
            scheduler: ManualScheduler(),
            coordinator: ControllerInputCoordinator(gameController: FakeSource(), hid: source)
        )
        engine.start()
        return (engine, dispatcher, source)
    }

    func testDisconnectWhileBHeldProducesNoGestureAndClearsBookkeeping() {
        let (engine, dispatcher, source) = makeEngine()
        defer { engine.stop() }

        source.onEvent?(.pressed(.b, timestamp: 0))
        source.onDetach?("Wireless Controller")

        XCTAssertTrue(
            dispatcher.triggers.isEmpty,
            "a detach must not be recognised as a tap or a hold (which would switch apps)"
        )
        XCTAssertEqual(dispatcher.releaseHeldCalls, 1, "the dispatcher's held-key bookkeeping is dropped on detach")
    }

    /// The coordinator-level half of the same guarantee: a source that *does* synthesise releases
    /// around its detach must not have them forwarded as input. (`HIDInputSource` no longer does,
    /// but the rule is enforced here so no source can reintroduce the bug.)
    func testEventsEmittedDuringDetachAreDropped() {
        final class ChattySource: ControllerInputSource {
            let transport: ControllerTransport = .rawHID
            var onEvent: ((InputEvent) -> Void)?
            var onAttach: ((String) -> Void)?
            var onDetach: ((String) -> Void)?
            var onWillDetach: (() -> Void)?
            func start() {}
            func stop() {}
        }

        let chatty = ChattySource()
        let coordinator = ControllerInputCoordinator(gameController: ChattySource(), hid: chatty)
        var forwarded: [InputEvent] = []
        var detaches = 0
        coordinator.onEvent = { forwarded.append($0) }
        coordinator.onDetach = { _ in detaches += 1 }

        chatty.onEvent?(.pressed(.b, timestamp: 0))
        // Exactly what the old HID cleanup did, in the order it did it: the synthetic release comes
        // *before* the detach. `onWillDetach` is what makes this order-independent.
        chatty.onWillDetach?()
        chatty.onEvent?(.released(.b, timestamp: 0.5))
        chatty.onDetach?("Wireless Controller")

        XCTAssertEqual(detaches, 1)
        XCTAssertEqual(forwarded, [.pressed(.b, timestamp: 0)], "cleanup releases must not reach the recognizer")
    }

    func testAStrayReleaseAfterADetachIsStillNotAGesture() {
        // Belt and braces at the engine level: even if a source delivered a release *after* the
        // detach was processed, a vanished controller must not be able to fire a B tap or hold.
        let (engine, dispatcher, source) = makeEngine()
        defer { engine.stop() }

        source.onEvent?(.pressed(.b, timestamp: 0))
        source.onDetach?("Wireless Controller")
        source.onEvent?(.released(.b, timestamp: 0.5))

        XCTAssertTrue(dispatcher.triggers.isEmpty, "a post-detach release must not switch applications")
    }

    func testARealGestureStillReachesTheDispatcher() {
        // Guard against the disconnect fix being too wide and swallowing normal input.
        let (engine, dispatcher, source) = makeEngine()
        defer { engine.stop() }

        source.onEvent?(.pressed(.b, timestamp: 0))
        source.onEvent?(.released(.b, timestamp: 0.1))

        XCTAssertEqual(dispatcher.triggers, [.press(.cancelOrInterrupt)])
    }

    func testDisconnectWhileHoldingAChordReleasesTheModifierItHeld() {
        // The push-to-talk case: the chord is down, the controller vanishes. The recognizer must
        // report the chord release so the injected ⌥ does not stay down in the user's session.
        let source = FakeSource()
        let dispatcher = RecordingDispatcher()
        let engine = ControllerEngine(
            dispatcher: dispatcher,
            scheduler: ManualScheduler(),
            coordinator: ControllerInputCoordinator(gameController: FakeSource(), hid: source)
        )
        let option = KeyStroke(modifiers: [.rightOption])
        var overrides: [String: GestureOverride] = ["b.a": GestureOverride(stroke: option, isHeld: true)]
        engine.gestureOverridesProvider = { overrides }
        engine.start()
        defer { engine.stop() }

        source.onEvent?(.pressed(.b, timestamp: 0))
        source.onEvent?(.pressed(.a, timestamp: 0.05))

        source.onDetach?("Wireless Controller")

        XCTAssertEqual(dispatcher.triggers, [.raw(option, .down), .raw(option, .up)])
    }

    func testChordReleaseUsesTheTableItStartedWith() {
        // A held binding that disappears mid-chord — profile switch, config reload, frontmost app
        // change — must still be released. The release is routed through the frozen table, so even
        // with the override gone the ⌥ comes up.
        let source = FakeSource()
        let dispatcher = RecordingDispatcher()
        let engine = ControllerEngine(
            dispatcher: dispatcher,
            scheduler: ManualScheduler(),
            coordinator: ControllerInputCoordinator(gameController: FakeSource(), hid: source)
        )
        let option = KeyStroke(modifiers: [.rightOption])
        var overrides: [String: GestureOverride] = ["b.a": GestureOverride(stroke: option, isHeld: true)]
        engine.gestureOverridesProvider = { overrides }
        engine.start()
        defer { engine.stop() }

        source.onEvent?(.pressed(.b, timestamp: 0))
        source.onEvent?(.pressed(.a, timestamp: 0.05))
        overrides = [:]                     // the new profile has no voice binding
        source.onEvent?(.released(.a, timestamp: 0.2))

        XCTAssertEqual(
            dispatcher.triggers,
            [.raw(option, .down), .raw(option, .up)],
            "profile changes must not erase the release of the original binding"
        )
    }
}

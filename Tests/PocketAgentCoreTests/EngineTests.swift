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
        /// When true, `handleMenuEvent` reports `.ignored`, simulating the menu having gone away for
        /// a reason the engine was not told about.
        var menuVetoesItself = false
        /// Menu events the engine routed here while a menu was open.
        private(set) var menuEvents: [InputEvent] = []
        var menuResult: MenuEventResult = .handled

        /// Minimal menu state, so engine routing can be tested without AppKit.
        var openMenu: AgentMenu?
        var menuBuilder: ((String?) -> AgentMenu?)?
        var onMenuChanged: ((AgentMenu?) -> Void)?

        func dispatch(_ trigger: ActionTrigger) { triggers.append(trigger) }
        func releaseHeldStrokes() { releaseHeldCalls += 1 }
        @discardableResult func openMenu(frontmostBundleID: String?) -> Bool {
            guard let menu = menuBuilder?(frontmostBundleID) else { return false }
            openMenu = menu
            onMenuChanged?(menu)
            return true
        }
        func closeMenu() {
            openMenu = nil
            onMenuChanged?(nil)
        }
        func handleMenuEvent(_ event: InputEvent) -> MenuEventResult {
            if menuVetoesItself {
                openMenu = nil          // the dispatcher drops it…
                return .ignored         // …and says the event was never ours
            }
            guard openMenu != nil else { return .ignored }
            menuEvents.append(event)
            return menuResult
        }
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

    func testAMenuOwnsTheControllerWhileItIsOpen() {
        // The events are injected by this process, so anything not consumed here would land in the
        // chat window as real arrow keys and Enter. This pins down that the recognizer never sees
        // them: no gesture, no dispatch.
        let (engine, dispatcher, source) = makeEngine()
        defer { engine.stop() }
        let menu = AgentMenu(bundleID: "com.openai.codex", title: "Codex", items: [
            MenuItem(action: .newChat, title: "新建会话"),
            MenuItem(action: .inspectChanges, title: "查看变更"),
        ])
        dispatcher.menuBuilder = { _ in menu }
        engine.frontmost = FixedFrontmost("com.openai.codex")

        XCTAssertTrue(engine.openMenu())
        XCTAssertEqual(dispatcher.openMenu?.items.count, 2)
        XCTAssertTrue(engine.isMenuOpen)

        source.onEvent?(.pressed(.down, timestamp: 0))
        source.onEvent?(.pressed(.a, timestamp: 0.1))

        XCTAssertEqual(dispatcher.menuEvents.count, 2, "the menu sees the events")
        XCTAssertTrue(dispatcher.triggers.isEmpty, "and the recognizer sees none of them")
    }

    func testAControllerDisconnectClosesTheMenu() {
        let (engine, dispatcher, source) = makeEngine()
        defer { engine.stop() }
        dispatcher.menuBuilder = { bundleID in
            AgentMenu(bundleID: bundleID, title: "Codex", items: [MenuItem(action: .newChat, title: "x")])
        }
        engine.frontmost = FixedFrontmost("com.openai.codex")
        XCTAssertTrue(engine.openMenu())

        source.onDetach?("Wireless Controller")

        XCTAssertFalse(engine.isMenuOpen, "a menu whose controller is gone cannot be driven")
    }

    func testOpeningTheMenuResetsHalfFinishedGestureState() {
        // The menu opens *because* of a gesture (B+←). If that gesture's state survived, its later
        // release would be interpreted as the tail of something no longer being tracked.
        let (engine, dispatcher, source) = makeEngine()
        defer { engine.stop() }
        dispatcher.menuBuilder = { bundleID in
            AgentMenu(bundleID: bundleID, title: "Codex", items: [MenuItem(action: .newChat, title: "x")])
        }
        engine.frontmost = FixedFrontmost("com.openai.codex")

        source.onEvent?(.pressed(.b, timestamp: 0))
        XCTAssertTrue(engine.openMenu())
        source.onEvent?(.released(.b, timestamp: 0.1))

        XCTAssertTrue(dispatcher.triggers.isEmpty, "the B release must not fire a gesture")
        XCTAssertEqual(dispatcher.menuEvents.count, 1)
    }

    func testAStaleMenuStateNeverLeaksAKeyToTheApp() {
        // The regression behind "上下键没反应": the overlay closed the menu on its own, the dispatcher
        // dropped the session, but the engine still believed a menu was up. The dispatcher then
        // reported the event as not-ours and the engine passed it on, so ↑ went to Codex as a real
        // arrow key — the caret moved instead of the selection. Either half of the fix catches it:
        // the engine asks the dispatcher whether a menu is open, and it swallows an unclaimed event
        // while it thought one was.
        let (engine, dispatcher, source) = makeEngine()
        defer { engine.stop() }
        dispatcher.menuBuilder = { bundleID in
            AgentMenu(bundleID: bundleID, title: "Codex", items: [MenuItem(action: .newChat, title: "x")])
        }
        engine.frontmost = FixedFrontmost("com.openai.codex")
        XCTAssertTrue(engine.openMenu())

        dispatcher.menuVetoesItself = true
        source.onEvent?(.pressed(.down, timestamp: 0))

        XCTAssertTrue(
            dispatcher.triggers.isEmpty,
            "a navigation key must never reach the app because the menu state was stale"
        )
    }

    private final class FixedFrontmost: FrontmostAppProviding {
        var bundleID: String?
        init(_ bundleID: String?) { self.bundleID = bundleID }
        func frontmostBundleID() -> String? { bundleID }
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

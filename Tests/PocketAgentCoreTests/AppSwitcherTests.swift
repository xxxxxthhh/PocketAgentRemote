import XCTest
@testable import PocketAgentCore

/// The app switcher: what holding B opens, how ←/→ move through it, and what A does.
///
/// It shares the menu session with the command menu, so the promises the menu makes (the controller
/// belongs to the overlay while it is up, nothing leaks to the app behind) are inherited. These tests
/// pin what is different: the strip layout, the horizontal axis, the "previous app" start position,
/// and that choosing a row activates an app instead of typing anything.
final class AppSwitcherTests: XCTestCase {
    private let codex = "com.openai.codex"
    private let claude = "com.anthropic.claudefordesktop"
    private let safari = "com.apple.Safari"

    private final class SpyEmitter: InputEmitting {
        private(set) var strokes: [KeyStroke] = []
        func press(_ stroke: KeyStroke) { strokes.append(stroke) }
        func keyDown(_ stroke: KeyStroke) { strokes.append(stroke) }
        func keyUp(_ stroke: KeyStroke) { strokes.append(stroke) }
        func releaseAll() {}
    }

    private final class StubFrontmost: FrontmostAppProviding {
        var bundleID: String?
        init(_ bundleID: String?) { self.bundleID = bundleID }
        func frontmostBundleID() -> String? { bundleID }
    }

    private final class SpyActivator: AppActivating {
        private(set) var requested: [String] = []
        func activate(bundleID: String) -> AppActivationOutcome {
            requested.append(bundleID)
            return AppActivationOutcome(
                succeeded: true, bundleID: bundleID, method: .appleScript, elapsedMs: 5,
                attempts: [AppActivationAttempt(method: .appleScript, succeeded: true, elapsedMs: 5)])
        }
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

    /// Three apps, most recent first: the user is in Codex, was in Claude before, Safari before that.
    private var apps: [RunningApp] {
        [RunningApp(bundleID: codex, name: "Codex"),
         RunningApp(bundleID: claude, name: "Claude"),
         RunningApp(bundleID: safari, name: "Safari")]
    }

    private func makeDispatcher(
        apps: [RunningApp]? = nil,
        activator: AppActivating? = SpyActivator()
    ) -> (ActionDispatcher, SpyEmitter, StubFrontmost) {
        var config = AppConfig()
        config.profileMode = .auto
        let emitter = SpyEmitter()
        let frontmost = StubFrontmost(codex)
        let dispatcher = ActionDispatcher(
            configProvider: { config }, frontmost: frontmost, emitter: emitter, activator: activator)
        let list = apps ?? self.apps
        dispatcher.switcherBuilder = { bundleID in
            AppSwitcherBuilder.menu(apps: list, frontmostBundleID: bundleID)
        }
        return (dispatcher, emitter, frontmost)
    }

    // MARK: - Builder

    func testStripStartsOnThePreviousAppSoHoldBThenAJumpsBack() {
        let menu = AppSwitcherBuilder.menu(apps: apps, frontmostBundleID: codex)
        XCTAssertEqual(menu?.layout, .strip)
        XCTAssertEqual(menu?.selection, 1, "the highlight starts on the app used before this one")
        XCTAssertEqual(menu?.selectedItem?.appBundleID, claude)
        XCTAssertNil(menu?.selectedItem?.action, "a switcher row is not a command")
        XCTAssertEqual(menu?.items.map(\.title), ["Codex", "Claude", "Safari"])
        XCTAssertEqual(menu?.bundleID, codex, "the strip remembers what was in front when it opened")
        XCTAssertTrue(menu?.hint.contains("←→") ?? false)
    }

    func testFewerThanTwoAppsMeansNoStrip() {
        XCTAssertNil(AppSwitcherBuilder.menu(apps: [], frontmostBundleID: codex))
        XCTAssertNil(AppSwitcherBuilder.menu(apps: [apps[0]], frontmostBundleID: codex),
                     "one app leaves nowhere to switch to")
        XCTAssertNotNil(AppSwitcherBuilder.menu(apps: Array(apps.prefix(2)), frontmostBundleID: codex))
    }

    // MARK: - Dispatcher

    func testOpenAppSwitcherPublishesTheStripAndTypesNothing() {
        let (dispatcher, emitter, _) = makeDispatcher()
        var published: [AgentMenu?] = []
        dispatcher.onMenuChanged = { published.append($0) }

        dispatcher.dispatch(.press(.openAppSwitcher))

        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(published[0]?.layout, .strip)
        XCTAssertNotNil(dispatcher.openMenu)
        XCTAssertTrue(emitter.strokes.isEmpty)
    }

    func testOpenAppSwitcherIsSkippedWithNothingToSwitchTo() {
        let (dispatcher, emitter, _) = makeDispatcher(apps: [apps[0]])
        var unsupported: [(AgentAction, String)] = []
        dispatcher.onUnsupported = { unsupported.append(($0, $1)) }

        dispatcher.dispatch(.press(.openAppSwitcher))

        XCTAssertNil(dispatcher.openMenu)
        // Structured, so the app can tell the user why nothing appeared — exactly one notification.
        XCTAssertEqual(unsupported.count, 1, "\(unsupported)")
        XCTAssertEqual(unsupported.first?.0, .openAppSwitcher)
        XCTAssertEqual(unsupported.first?.1, "fewer than two apps to switch between")
        XCTAssertTrue(emitter.strokes.isEmpty, "a failure must type nothing")
    }

    func testLeftAndRightMoveTheHighlightAndWrap() {
        let (dispatcher, emitter, _) = makeDispatcher()
        dispatcher.dispatch(.press(.openAppSwitcher))

        XCTAssertEqual(dispatcher.handleMenuEvent(.pressed(.right, timestamp: 0)), .handled)
        XCTAssertEqual(dispatcher.openMenu?.selection, 2)
        XCTAssertEqual(dispatcher.handleMenuEvent(.pressed(.right, timestamp: 0.1)), .handled)
        XCTAssertEqual(dispatcher.openMenu?.selection, 0, "→ past the end wraps to the first app")
        XCTAssertEqual(dispatcher.handleMenuEvent(.pressed(.left, timestamp: 0.2)), .handled)
        XCTAssertEqual(dispatcher.openMenu?.selection, 2, "← before the start wraps to the last app")
        XCTAssertTrue(emitter.strokes.isEmpty, "←→ must never reach the app behind the strip")
    }

    func testUpAndDownAreSwallowedByTheStrip() {
        let (dispatcher, emitter, _) = makeDispatcher()
        dispatcher.dispatch(.press(.openAppSwitcher))

        XCTAssertEqual(dispatcher.handleMenuEvent(.pressed(.up, timestamp: 0)), .handled)
        XCTAssertEqual(dispatcher.handleMenuEvent(.pressed(.down, timestamp: 0.1)), .handled)
        XCTAssertEqual(dispatcher.openMenu?.selection, 1, "↑↓ have no meaning in a horizontal strip")
        XCTAssertTrue(emitter.strokes.isEmpty)
    }

    func testAActivatesTheHighlightedAppAndSendsNoKeystroke() {
        let activator = SpyActivator()
        let (dispatcher, emitter, _) = makeDispatcher(activator: activator)
        var activations: [(AgentAction, AppActivationOutcome)] = []
        dispatcher.onActivation = { activations.append(($0, $1)) }
        dispatcher.dispatch(.press(.openAppSwitcher))

        let result = dispatcher.handleMenuEvent(.pressed(.a, timestamp: 0))

        XCTAssertEqual(result, .activated(bundleID: claude))
        XCTAssertEqual(activator.requested, [claude])
        XCTAssertNil(dispatcher.openMenu, "choosing an app closes the strip")
        XCTAssertTrue(emitter.strokes.isEmpty, "switching apps is not a keystroke")
        XCTAssertEqual(activations.count, 1)
        XCTAssertEqual(activations.first?.0, .openAppSwitcher)
    }

    func testChoosingTheAppAlreadyInFrontClosesWithoutActivating() {
        let activator = SpyActivator()
        let (dispatcher, _, _) = makeDispatcher(activator: activator)
        dispatcher.dispatch(.press(.openAppSwitcher))

        _ = dispatcher.handleMenuEvent(.pressed(.left, timestamp: 0))   // back to index 0: Codex
        let result = dispatcher.handleMenuEvent(.pressed(.a, timestamp: 0.1))

        XCTAssertEqual(result, .activated(bundleID: codex))
        XCTAssertTrue(activator.requested.isEmpty, "no AppleScript round trip for the app already in front")
        XCTAssertNil(dispatcher.openMenu)
    }

    func testBDismissesWithoutActivatingAnything() {
        let activator = SpyActivator()
        let (dispatcher, emitter, _) = makeDispatcher(activator: activator)
        dispatcher.dispatch(.press(.openAppSwitcher))

        XCTAssertEqual(dispatcher.handleMenuEvent(.pressed(.b, timestamp: 0)), .dismissed)
        XCTAssertNil(dispatcher.openMenu)
        XCTAssertTrue(activator.requested.isEmpty)
        XCTAssertTrue(emitter.strokes.isEmpty, "B inside the strip must not become Escape")
    }

    func testAIsRefusedWhenFocusMovedWhileTheStripWasUp() {
        let activator = SpyActivator()
        let (dispatcher, _, frontmost) = makeDispatcher(activator: activator)
        dispatcher.dispatch(.press(.openAppSwitcher))

        frontmost.bundleID = safari
        let result = dispatcher.handleMenuEvent(.pressed(.a, timestamp: 0))

        guard case .refused = result else { return XCTFail("expected a refusal, got \(result)") }
        XCTAssertTrue(activator.requested.isEmpty)
        XCTAssertNil(dispatcher.openMenu)
    }

    func testWithoutAnActivatorTheChoiceIsReportedNotSilentlyDropped() {
        let (dispatcher, emitter, _) = makeDispatcher(activator: nil)
        var unsupported: [(AgentAction, String)] = []
        dispatcher.onUnsupported = { unsupported.append(($0, $1)) }
        dispatcher.dispatch(.press(.openAppSwitcher))

        _ = dispatcher.handleMenuEvent(.pressed(.a, timestamp: 0))

        XCTAssertEqual(unsupported.count, 1, "exactly one notification: \(unsupported)")
        XCTAssertEqual(unsupported.first?.0, .openAppSwitcher)
        XCTAssertTrue(unsupported.first?.1.contains("not wired up") == true, "\(unsupported)")
        XCTAssertTrue(emitter.strokes.isEmpty, "a failure must type nothing")
    }

    /// Focus moved while the strip was up: the choice is refused, reported once, and types nothing.
    /// A switcher row has no action of its own, so it is reported as the switcher's rather than as
    /// `nil`, which stays reserved for raw gesture overrides.
    func testAStripChoiceRefusedAfterFocusMovedIsReportedOnce() {
        let (dispatcher, emitter, frontmost) = makeDispatcher()
        var denied: [(AgentAction?, String)] = []
        var unsupported = 0
        dispatcher.onDenied = { denied.append(($0, $1)) }
        dispatcher.onUnsupported = { _, _ in unsupported += 1 }

        dispatcher.dispatch(.press(.openAppSwitcher))
        frontmost.bundleID = "com.apple.Safari"     // focus moved while the strip was up

        _ = dispatcher.handleMenuEvent(.pressed(.a, timestamp: 0))

        XCTAssertNil(dispatcher.openMenu, "a refused choice still takes the strip down")
        XCTAssertTrue(emitter.strokes.isEmpty, "a refusal must type nothing")
        XCTAssertEqual(denied.count, 1, "\(denied)")
        XCTAssertEqual(denied.first?.0, .openAppSwitcher)
        XCTAssertTrue(denied.first?.1.contains("menu item refused") == true, "\(denied)")
        XCTAssertTrue(denied.first?.1.contains("Claude") == true, "the row's own label is named: \(denied)")
        XCTAssertEqual(unsupported, 0, "and not reported a second time as unsupported")
    }

    // MARK: - End to end: hold B

    private struct Rig {
        let engine: ControllerEngine
        let dispatcher: ActionDispatcher
        let source: FakeSource
        let emitter: SpyEmitter
        let activator: SpyActivator
        let scheduler: ManualScheduler
    }

    private func makeRig() -> Rig {
        let activator = SpyActivator()
        let (dispatcher, emitter, frontmost) = makeDispatcher(activator: activator)
        var config = AppConfig()
        config.profileMode = .auto
        dispatcher.menuBuilder = { bundleID in
            AgentMenuBuilder.menu(for: config, frontmostBundleID: bundleID, frontmostName: "Codex")
        }
        let source = FakeSource()
        let scheduler = ManualScheduler()
        let engine = ControllerEngine(
            dispatcher: dispatcher,
            gestureOverrides: config.gestureOverrides(for: config.activeProfile),
            scheduler: scheduler,
            coordinator: ControllerInputCoordinator(gameController: FakeSource(), hid: source)
        )
        engine.frontmost = frontmost
        engine.start()
        return Rig(engine: engine, dispatcher: dispatcher, source: source, emitter: emitter,
                   activator: activator, scheduler: scheduler)
    }

    private func press(_ rig: Rig, _ button: PhysicalButton, at t: TimeInterval) {
        rig.scheduler.advance(to: t)
        rig.source.onEvent?(.pressed(button, timestamp: t))
    }
    private func release(_ rig: Rig, _ button: PhysicalButton, at t: TimeInterval) {
        rig.scheduler.advance(to: t)
        rig.source.onEvent?(.released(button, timestamp: t))
    }

    /// The whole gesture: hold B past the threshold, let go, → once, A. Claude was the highlight to
    /// begin with, so one → lands on Safari.
    func testHoldingBOpensTheStripAndRightThenASwitchesApps() {
        let rig = makeRig()
        defer { rig.engine.stop() }

        press(rig, .b, at: 0)
        XCTAssertFalse(rig.engine.isMenuOpen, "nothing opens while B is still down")
        release(rig, .b, at: 1.0)   // past holdMs (450 ms)
        XCTAssertTrue(rig.engine.isMenuOpen, "letting go of B after the hold opens the strip")
        XCTAssertEqual(rig.dispatcher.openMenu?.layout, .strip)
        XCTAssertTrue(rig.emitter.strokes.isEmpty, "a held B must not send Escape")

        press(rig, .right, at: 1.2)
        release(rig, .right, at: 1.3)
        XCTAssertEqual(rig.dispatcher.openMenu?.selectedItem?.appBundleID, safari)

        press(rig, .a, at: 1.5)
        release(rig, .a, at: 1.6)
        XCTAssertFalse(rig.engine.isMenuOpen)
        XCTAssertEqual(rig.activator.requested, [safari])
        XCTAssertTrue(rig.emitter.strokes.isEmpty, "neither the strip's → nor its A may reach the app")

        // And the controller is an ordinary controller again.
        press(rig, .down, at: 2.0)
        release(rig, .down, at: 2.1)
        XCTAssertEqual(rig.emitter.strokes.count, 2, "↓ is a plain keyDown/keyUp once the strip is gone")
    }

    func testATapOfBIsStillEscapeNotTheStrip() {
        let rig = makeRig()
        defer { rig.engine.stop() }

        press(rig, .b, at: 0)
        release(rig, .b, at: 0.3)   // under holdMs

        XCTAssertFalse(rig.engine.isMenuOpen)
        XCTAssertEqual(rig.emitter.strokes, [KeyStroke(.escape)])
    }

    func testAChordOnAHeldBDoesNotOpenTheStripOnRelease() {
        let rig = makeRig()
        defer { rig.engine.stop() }

        press(rig, .b, at: 0)
        press(rig, .up, at: 0.8)      // B+↑ after the hold threshold: still a chord
        release(rig, .up, at: 0.9)
        release(rig, .b, at: 1.2)

        XCTAssertFalse(rig.engine.isMenuOpen, "a chord owns this B press; releasing B opens nothing")
        XCTAssertTrue(rig.emitter.strokes.contains(KeyStroke(.digit1, modifiers: [.command, .option])))
    }
}

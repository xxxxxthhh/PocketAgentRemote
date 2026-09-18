import Foundation

/// Somewhere semantic actions go. Implemented by the tool adapters (Phase 3) — this is the seam
/// that keeps the controller core completely unaware of Codex, Claude, or the desktop apps.
public protocol ActionDispatching: AnyObject {
    func dispatch(_ trigger: ActionTrigger)
    /// Forget every key-down record without emitting anything.
    ///
    /// Called when a controller disappears: the emitter force-releases the keys themselves, so the
    /// dispatcher's bookkeeping has to be dropped too, or a later stray release would key-up a
    /// stroke that was already released.
    func releaseHeldStrokes()

    /// The menu on screen, if any. The single source of truth for "is a menu open".
    var openMenu: AgentMenu? { get }
    /// Menu to draw (non-nil) or take down (nil).
    var onMenuChanged: ((AgentMenu?) -> Void)? { get set }
    /// Opens the menu for an app; false when there is nothing to show for it.
    @discardableResult
    func openMenu(frontmostBundleID: String?) -> Bool
    /// Opens the app switcher; false when there are not enough apps to switch between.
    @discardableResult
    func openAppSwitcher(frontmostBundleID: String?) -> Bool
    /// Takes the menu down without running anything.
    func closeMenu()

    /// Hand one raw controller event to the on-screen menu.
    ///
    /// While the menu is open it owns the whole controller: nothing goes to the recognizer, so the
    /// ↑↓/A/B used to drive the list cannot also reach the chat window behind it. The result says
    /// what the menu did with it, so the app can redraw or take the overlay down.
    func handleMenuEvent(_ event: InputEvent) -> MenuEventResult
}

/// Wires the whole controller core together:
///
/// ```text
/// ControllerInputCoordinator ──▶ GestureRecognizer ──▶ EventResolver ──▶ ActionDispatching
///        (both variants)            (B tap/hold/chord)     (→ AgentAction)      (adapters)
/// ```
public final class ControllerEngine {
    public var onDiagnostic: ((String) -> Void)? {
        didSet { coordinator.onDiagnostic = onDiagnostic }
    }
    /// Called when a supported controller becomes usable, with its device name.
    public var onControllerAttached: ((String) -> Void)?
    public var onControllerDetached: ((String) -> Void)?
    /// Raw press/release straight off the input source. For the debug monitor (spec §17).
    public var onRawEvent: ((InputEvent) -> Void)?
    /// Recognised gestures, before they are resolved into semantic actions.
    public var onGesture: (([ResolvedEvent]) -> Void)?

    public let recognizer: GestureRecognizer

    /// Per-gesture keystroke overrides from config. Settable so a config reload or a manual profile
    /// switch takes effect without relaunching.
    public var gestureOverrides: [String: GestureOverride] {
        get { resolver.gestureOverrides }
        set {
            resolver = EventResolver(bindings: resolver.bindings, gestureOverrides: newValue)
            recognizer.aHoldEnabled = aHoldEnabled
        }
    }

    /// Supplies the gesture overrides in force *right now*, consulted before each event.
    ///
    /// Needed for automatic profile switching: the same gesture resolves to `⌥⌘1` in Codex and `⌘⇧]`
    /// in Claude, and which one applies depends on the frontmost app at the moment of the press —
    /// not on whatever was configured when the engine was built.
    public var gestureOverridesProvider: (() -> [String: GestureOverride])?

    private let coordinator: ControllerInputCoordinator
    private var resolver: EventResolver
    private let dispatcher: ActionDispatching
    private var running = false
    /// The override table in force when the current chord started, kept until that chord releases.
    private var frozenOverrides: [String: GestureOverride]?

    /// Supplies the frontmost bundle ID, so the menu can be built for the right app.
    public var frontmost: FrontmostAppProviding?
    /// Display name for the menu header when the config has no friendly name for the bundle ID.
    public var frontmostNameProvider: (() -> String?)?

    /// True only while a detach is being processed. See the `onEvent` handler: cleanup releases are
    /// discarded here rather than by a general "nothing in flight" rule, which misfired on real input.
    private var isDetaching = false

    /// Whether a held A is a gesture (push-to-talk) rather than a one-shot submit.
    ///
    /// Driven by the resolved override table, so it follows a config reload and a profile switch:
    /// with no `a.hold` binding, A stays a plain button and the `submit` fires the moment it goes
    /// down, exactly as before.
    private var aHoldEnabled: Bool { resolver.gestureOverrides["a.hold"] != nil }

    /// Whether the on-screen menu is up. Read from the dispatcher, which owns that state.
    public var isMenuOpen: Bool { dispatcher.openMenu != nil }
    /// Menu to draw (non-nil) or take down (nil). The app hangs its overlay here.
    public var onMenuChanged: ((AgentMenu?) -> Void)?

    public init(
        dispatcher: ActionDispatching,
        bindings: GestureBindings = .default,
        gestureOverrides: [String: GestureOverride] = [:],
        configuration: GestureConfiguration = .default,
        scheduler: GestureScheduler = DispatchGestureScheduler(),
        coordinator: ControllerInputCoordinator = ControllerInputCoordinator()
    ) {
        self.dispatcher = dispatcher
        self.resolver = EventResolver(bindings: bindings, gestureOverrides: gestureOverrides)
        self.recognizer = GestureRecognizer(configuration: configuration, scheduler: scheduler)
        self.coordinator = coordinator
    }

    public func start() {
        guard !running else { return }
        running = true

        recognizer.aHoldEnabled = aHoldEnabled
        recognizer.aHoldMs = recognizer.configuration.aHoldMs

        recognizer.emit = { [weak self] events in
            guard let self else { return }
            self.onGesture?(events)
            for trigger in self.triggers(for: events) {
                self.dispatcher.dispatch(trigger)
            }
        }

        // The recognizer must not carry state across a menu. Two things make it stale: the menu is
        // opened *by* a gesture (so that gesture is half-tracked), and while the menu is up the
        // recognizer sees nothing, so a release during the menu is never delivered. Watching the
        // menu state here covers every transition — opened by the controller, opened from the menu
        // bar, closed by B, closed by running a row, closed because focus moved — which is what an
        // earlier version got wrong by resetting on only some of those paths.
        dispatcher.onMenuChanged = { [weak self] menu in
            guard let self else { return }
            if menu != nil { self.recognizer.resetAndEmit() }
            self.onMenuChanged?(menu)
        }

        coordinator.onEvent = { [weak self] event in
            guard let self else { return }
            self.onRawEvent?(event)

            // While a menu is up it owns the controller. This happens before the recognizer so the
            // navigation keys cannot be turned into arrow keys and sent to the chat window — and so
            // no chord or tap gesture can fire behind the overlay.
            if self.isMenuOpen {
                let wasOpen = true
                let result = self.dispatcher.handleMenuEvent(event)
                // Entering and leaving the menu are the moments the recognizer's view of the world
                // goes stale: while the menu is up it receives nothing at all, so a release that
                // happens during the menu never arrives. Resetting here is what stops the *next*
                // press from being interpreted as part of a gesture that ended on screen.
                if wasOpen && !self.isMenuOpen {
                    self.recognizer.resetAndEmit()
                }
                if case .ignored = result {
                    // The menu went away between the check and the hand-off. The event still belongs
                    // to it — falling through to the recognizer here is what turned ↑ into a real
                    // arrow key in the chat window.
                    self.recognizer.resetAndEmit()
                    self.onDiagnostic?("MENU  already closed; event swallowed")
                }
                return
            }

            // Cleanup a source invented for a disappearing device must not be recognised as a
            // gesture — a B that was down would otherwise fire a tap or (worse) the app switch.
            //
            // Scoped to the detach itself, and deliberately *not* "any release with nothing in
            // flight": real releases can arrive for a button whose state was just reset (the menu
            // does exactly that), and swallowing one of those leaves the recognizer believing the
            // button is still held. That is how an earlier version broke push-to-talk completely —
            // A's release was dropped, `aIsDown` stayed true, and every later B press was ignored as
            // "B while A is down".
            if self.isDetaching, !event.isPress {
                self.onDiagnostic?("DROPPED release during detach — device cleanup, not input")
                return
            }
            self.syncGestureOverridesIfNeeded()
            self.recognizer.handle(event)
        }
        // A controller can vanish mid-gesture; without this the target app keeps whatever key was
        // down, and a half-finished B press stays armed (spec §17, §18).
        coordinator.onDetach = { [weak self] name in
            guard let self else { return }
            // Everything until this returns is teardown, not input: the HID source synthesises
            // releases for whatever it thought was held, and those must not become gestures.
            self.isDetaching = true
            defer { self.isDetaching = false }
            self.closeMenu()
            self.dispatcher.releaseHeldStrokes()
            self.recognizer.resetAndEmit()
            self.onControllerDetached?(name)
        }
        coordinator.onAttach = { [weak self] name in
            self?.onControllerAttached?(name)
        }

        coordinator.start()
    }

    public func stop() {
        guard running else { return }
        running = false
        coordinator.stop()
        recognizer.resetAndEmit()
    }

    // MARK: - Menu

    /// Opens the menu for the app in front, if it is one we have a profile for.
    ///
    /// The recognizer is reset first: opening the menu happens *because* of a gesture (B+←), and any
    /// half-finished state from it must not survive into the menu, or a later release would be
    /// interpreted as the tail of a gesture that is no longer being tracked.
    @discardableResult
    public func openMenu() -> Bool {
        guard !isMenuOpen else { return true }
        recognizer.resetAndEmit()
        return dispatcher.openMenu(frontmostBundleID: frontmost?.frontmostBundleID())
    }

    /// Opens the app switcher from outside the controller (menu bar). Same reset as `openMenu`.
    @discardableResult
    public func openAppSwitcher() -> Bool {
        guard !isMenuOpen else { return true }
        recognizer.resetAndEmit()
        return dispatcher.openAppSwitcher(frontmostBundleID: frontmost?.frontmostBundleID())
    }

    /// Takes the menu down without running anything (screen-side close, controller gone).
    public func closeMenu() {
        guard isMenuOpen else { return }
        dispatcher.closeMenu()
        recognizer.resetAndEmit()
    }

    /// Resolves recognizer events, keeping a start and its end on the **same** override table.
    ///
    /// The table can change between the two — the frontmost app moved, the profile was switched, the
    /// config was reloaded — and a held binding (B+A push-to-talk) that only exists in the old table
    /// must still be released. So the table is frozen when a chord starts and reused for its
    /// release, which is then dropped. New tables arriving while a gesture is still in flight are
    /// ignored rather than clearing the freeze: the release is the very next event to look at it.
    private func triggers(for events: [ResolvedEvent]) -> [ActionTrigger] {
        events.flatMap { event -> [ActionTrigger] in
            if case .gesture(.chordReleased) = event {
                let triggers = resolver.releaseTriggers(for: event, overrides: frozenOverrides)
                frozenOverrides = nil
                return triggers
            }
            let table = frozenOverrides ?? resolver.gestureOverrides
            if case .gesture(.chord) = event {
                frozenOverrides = table
            }
            return resolver.pressTriggers(for: event, overrides: table)
        }
    }

    /// Swaps the resolver only when the override table actually changed — the frontmost app is
    /// consulted per event, and rebuilding a resolver on every event would be wasteful.
    private func syncGestureOverridesIfNeeded() {
        guard let provider = gestureOverridesProvider else { return }
        let overrides = provider()
        guard overrides != resolver.gestureOverrides else { return }
        resolver = EventResolver(bindings: resolver.bindings, gestureOverrides: overrides)
        recognizer.aHoldEnabled = aHoldEnabled
    }
}

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
        set { resolver = EventResolver(bindings: resolver.bindings, gestureOverrides: newValue) }
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

        recognizer.emit = { [weak self] events in
            guard let self else { return }
            self.onGesture?(events)
            for trigger in self.triggers(for: events) {
                self.dispatcher.dispatch(trigger)
            }
        }

        coordinator.onEvent = { [weak self] event in
            guard let self else { return }
            self.onRawEvent?(event)
            // A release with nothing in flight is not the end of a user gesture: it is cleanup a
            // source invented for a device that has gone away. Recognising it would let a controller
            // vanishing fire a B tap or hold — and a hold switches applications. This is the
            // order-independent form of the guard (it does not care whether the synthetic release
            // arrives before or after the detach), and it is why the HID source's cleanup cannot
            // leak even if it runs late.
            if !event.isPress && self.recognizer.hasNothingInFlight {
                self.onDiagnostic?("DROPPED release with nothing held — device cleanup, not input")
                return
            }
            self.syncGestureOverridesIfNeeded()
            self.recognizer.handle(event)
        }
        // A controller can vanish mid-gesture; without this the target app keeps whatever key was
        // down, and a half-finished B press stays armed (spec §17, §18).
        coordinator.onDetach = { [weak self] name in
            guard let self else { return }
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
    }
}

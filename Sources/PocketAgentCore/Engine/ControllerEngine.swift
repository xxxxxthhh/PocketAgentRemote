import Foundation

/// Somewhere semantic actions go. Implemented by the tool adapters (Phase 3) — this is the seam
/// that keeps the controller core completely unaware of Codex, Claude, or the desktop apps.
public protocol ActionDispatching: AnyObject {
    func dispatch(_ trigger: ActionTrigger)
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

    private let coordinator: ControllerInputCoordinator
    private let resolver: EventResolver
    private let dispatcher: ActionDispatching
    private var running = false

    public init(
        dispatcher: ActionDispatching,
        bindings: GestureBindings = .default,
        configuration: GestureConfiguration = .default,
        scheduler: GestureScheduler = DispatchGestureScheduler(),
        coordinator: ControllerInputCoordinator = ControllerInputCoordinator()
    ) {
        self.dispatcher = dispatcher
        self.resolver = EventResolver(bindings: bindings)
        self.recognizer = GestureRecognizer(configuration: configuration, scheduler: scheduler)
        self.coordinator = coordinator
    }

    public func start() {
        guard !running else { return }
        running = true

        recognizer.emit = { [weak self] events in
            guard let self else { return }
            self.onGesture?(events)
            for trigger in self.resolver.triggers(for: events) {
                self.dispatcher.dispatch(trigger)
            }
        }

        coordinator.onEvent = { [weak self] event in
            guard let self else { return }
            self.onRawEvent?(event)
            self.recognizer.handle(event)
        }
        // A controller can vanish mid-gesture; without this the target app keeps whatever key was
        // down, and a half-finished B press stays armed (spec §17, §18).
        coordinator.onDetach = { [weak self] name in
            guard let self else { return }
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
}
